// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { DynamicFee } from "src/libs/DynamicFee.sol";
import { TreasuryManager } from "src/TreasuryManager.sol";
import { WhitelistRegistry } from "src/WhitelistRegistry.sol";

/// @notice Thrown when the caller is not the Uniswap V4 Migrator
error OnlyMigrator();

/// @notice Thrown when providing zero address where not allowed
error ZeroAddress();

/// @notice Thrown when sender is not whitelisted
error NotWhitelisted();

/// @notice Context for multi-hop swap coordination
/// @dev Disables double-fee collection during Player Token -> Player Token swaps
/// @param isMultiHop
/// @param isUsdc
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}

/**
 * @title Uniswap V4 Migrator Hook with Dynamic Fees
 * @author Whetstone Research, Isla Labs
 * @custom:security-contact admin@islalabs.co
 */
contract UniswapV4MigratorHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the Uniswap V4 Migrator contract
    address public immutable migrator;

    /// @notice Treasury manager for centralized fee distribution
    TreasuryManager public treasuryManager;

    /// @notice Whitelist registry for platform account verification
    WhitelistRegistry public whitelistRegistry;

    /// @notice Modifier to ensure the caller is the Uniswap V4 Migrator
    modifier onlyMigrator(address sender) {
        if (sender != migrator) revert OnlyMigrator();
        _;
    }

    /// @notice Modifier to ensure the sender is whitelisted
    modifier onlyWhitelisted(address sender) {
        if (!whitelistRegistry.isTransferAllowed(sender)) revert NotWhitelisted();
        _;
    }

    /// @notice Constructor for the Uniswap V4 Migrator Hook
    /// @param manager Address of the Uniswap V4 Pool Manager
    /// @param migrator_ Address of the Uniswap V4 Migrator contract
    /// @param _treasuryManager Address of the Treasury Manager contract
    /// @param _whitelistRegistry Address of the Whitelist Registry contract
    constructor(
        IPoolManager manager, 
        UniswapV4Migrator migrator_,
        TreasuryManager _treasuryManager,
        WhitelistRegistry _whitelistRegistry
    ) BaseHook(manager) {
        migrator = address(migrator_);
        
        if (address(_treasuryManager) == address(0)) revert ZeroAddress();
        treasuryManager = _treasuryManager;

        if (address(_whitelistRegistry) == address(0)) revert ZeroAddress();
        whitelistRegistry = _whitelistRegistry;
    }

    /// @notice Hook that runs before pool initialization
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal view override onlyMigrator(sender) returns (bytes4) {
        // Apply the migrator check
        if (sender != migrator) revert OnlyMigrator();
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Hook that runs before swap (when buying a Player Token)
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override onlyWhitelisted(sender) returns (bytes4, BeforeSwapDelta, uint24) {

        // Check if sender is a whitelisted platform account
        if (!whitelistRegistry.isTransferAllowed(sender)) {
            revert NotWhitelisted();
        }
        
        // Check if buying Player Token (ETH → Token)
        bool isBuy = swapParams.zeroForOne;
        
        if (isBuy) {
            // Apply dynamic fees on ETH input
            uint256 ethPriceUsd = DynamicFee.fetchEthPriceWithFallback();
            uint256 inputAmount = uint256(swapParams.amountSpecified < 0 ? -swapParams.amountSpecified : swapParams.amountSpecified);
            uint256 dynamicFeeBps = DynamicFee.calculateDynamicFee(inputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (inputAmount * dynamicFeeBps) / 10000;
                
                // Distribute fees via Treasury Manager
                treasuryManager.distributeFees(
                    poolManager,
                    key.currency0,
                    totalFeeAmount,
                    sender,
                    true // isBuy
                );
                
                // Return delta to account for fees taken
                BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(totalFeeAmount)), 0);
                
                return (BaseHook.beforeSwap.selector, delta, 0);
            }
        }
        
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /// @notice Hook that runs after swap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        
        // Check if selling Player Token (Token → ETH)
        bool isSell = !swapParams.zeroForOne;
        
        if (isSell) {
            // Decode multi-hop context
            MultiHopContext memory context = _decodeHookData(hookData);
            
            // Skip fee collection for PlayerToken → PlayerToken multi-hops
            if (context.isMultiHop && !context.isUsdc) {
                return (BaseHook.afterSwap.selector, 0); // No fee on first hop
            }
            
            // Handle single-hop sells
            // Apply dynamic fees on ETH output
            uint256 ethPriceUsd = DynamicFee.fetchEthPriceWithFallback();
            uint256 outputAmount = delta.amount0() < 0 
                ? uint256(uint128(-delta.amount0())) 
                : uint256(uint128(delta.amount0()));
            uint256 dynamicFeeBps = DynamicFee.calculateDynamicFee(outputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (outputAmount * dynamicFeeBps) / 10000;
                
                // Distribute fees via Treasury Manager
                treasuryManager.distributeFees(
                    poolManager,
                    key.currency0,
                    totalFeeAmount,
                    sender,
                    false // isSell
                );
                
                // Return delta to account for fees taken
                return (BaseHook.afterSwap.selector, int128(int256(totalFeeAmount)));
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Decode hookData into MultiHopContext
    /// @param hookData Encoded multi-hop context data
    /// @return context Decoded multi-hop context
    function _decodeHookData(bytes calldata hookData) private pure returns (MultiHopContext memory context) {
        if (hookData.length == 0) {
            return MultiHopContext(false, false); // Single hop default
        }
        return abi.decode(hookData, (MultiHopContext));
    }

    /// @notice Returns the hook permissions configuration
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}