// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { AggregatorV3Interface } from "src/interfaces/AggregatorV3Interface.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { SD59x18, exp, sd } from "@prb/math/src/SD59x18.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { ITreasuryManager } from "src/interfaces/ITreasuryManager.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

/// @notice Context for multi-hop swap coordination
/// @dev Disables double-fee collection during Player Token -> Player Token swaps
/// @param isMultiHop
/// @param isUsdc
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}

/// @notice Thrown when the caller is not the Uniswap V4 Migrator
error OnlyMigrator();

/// @notice Thrown when providing zero address where not allowed
error ZeroAddress();

/// @notice Thrown when sender is not whitelisted
error NotWhitelisted();

/**
 * @title Uniswap V4 Migrator Hook with Dynamic Fees
 * @author Whetstone Research, Isla Labs
 * @custom:security-contact admin@islalabs.co
 */
contract UniswapV4MigratorHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // ==========================================
    // CONTRACT STATE
    // ==========================================

    /// @notice Address of the Uniswap V4 Migrator contract
    address public immutable migrator;

    /// @notice Treasury manager for centralized fee distribution
    ITreasuryManager public treasuryManager;

    /// @notice Whitelist registry for platform account verification
    IWhitelistRegistry public whitelistRegistry;

    // ==========================================
    // DYNAMIC FEE CONSTANTS
    // ==========================================

    /// @notice Chainlink ETH-USD price feed on Base
    address public CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    
    /// @notice Oracle validation constants
    uint256 internal constant MAX_STALENESS = 3600; // 1 hour
    uint256 public fallbackEthPriceUsd = 2500000000; // (6 decimals)

    /// @notice Dynamic fee constants
    uint256 internal constant FEE_START_TIER_1 = 500;
    uint256 internal constant FEE_START_TIER_2 = 481;
    uint256 internal constant FEE_START_TIER_3 = 322;
    uint256 internal constant FEE_START_TIER_4 = 123;
    uint256 internal constant FEE_MIN_BPS = 100;
    uint256 internal constant ALPHA_TIER_1 = 100;
    uint256 internal constant ALPHA_TIER_2 = 120;
    uint256 internal constant ALPHA_TIER_3 = 50;
    uint256 internal constant ALPHA_TIER_4 = 100;
    uint256 internal constant TIER_1_THRESHOLD_USD = 500;
    uint256 internal constant TIER_2_THRESHOLD_USD = 5000;
    uint256 internal constant TIER_3_THRESHOLD_USD = 50000;
    uint256 internal constant SCALE_PARAMETER = 1000;

    error NotAllowed();
    error InvalidPrice();

    // ==========================================
    // MODIFIERS
    // ==========================================

    /// @notice Modifier to ensure the caller is the Uniswap V4 Migrator
    modifier onlyMigrator(address sender) {
        if (sender != migrator) revert OnlyMigrator();
        _;
    }

    /// @notice Modifier to ensure the caller is admin for update function
    modifier onlyAdmin(address sender) {
        if (!whitelistRegistry.hasAdminAccess(sender)) revert NotAllowed();
        _;
    }

    // ==========================================
    // EVENTS
    // ==========================================

    event FallbackPriceUpdated(uint256 newPrice, address indexed updatedBy);
    event OracleAddressUpdated(address indexed newOracle, address indexed updatedBy);

    // ==========================================
    // CONSTRUCTOR
    // ==========================================

    /// @notice Constructor for the Uniswap V4 Migrator Hook
    /// @param manager Address of the Uniswap V4 Pool Manager
    /// @param migrator_ Address of the Uniswap V4 Migrator contract
    /// @param _treasuryManager Address of the Treasury Manager contract
    /// @param _whitelistRegistry Address of the Whitelist Registry contract
    constructor(
        IPoolManager manager, 
        UniswapV4Migrator migrator_,
        ITreasuryManager _treasuryManager,
        IWhitelistRegistry _whitelistRegistry
    ) BaseHook(manager) {
        migrator = address(migrator_);
        
        if (address(_treasuryManager) == address(0)) revert ZeroAddress();
        treasuryManager = _treasuryManager;

        if (address(_whitelistRegistry) == address(0)) revert ZeroAddress();
        whitelistRegistry = _whitelistRegistry;
    }

    // ==========================================
    // HOOK FUNCTIONS
    // ==========================================

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
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        
        // Check direction (ETH → Player Token)
        bool isBuy = swapParams.zeroForOne;
        
        if (isBuy) {
            // Apply dynamic fees on ETH input
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 inputAmount = uint256(swapParams.amountSpecified < 0 
                ? -swapParams.amountSpecified 
                : swapParams.amountSpecified
            );
            uint256 dynamicFeeBps = _calculateDynamicFee(inputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (inputAmount * dynamicFeeBps) / 10000;
                
                // Distribute fees via Treasury Manager
                treasuryManager.distributeFees(
                    poolManager,
                    sender,
                    key.currency0,
                    totalFeeAmount
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
        
        // Check direction (Player Token → ETH)
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
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 outputAmount = delta.amount0() < 0 
                ? uint256(uint128(-delta.amount0())) 
                : uint256(uint128(delta.amount0()));
            uint256 dynamicFeeBps = _calculateDynamicFee(outputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (outputAmount * dynamicFeeBps) / 10000;
                
                // Distribute fees via Treasury Manager
                treasuryManager.distributeFees(
                    poolManager,
                    sender,
                    key.currency0,
                    totalFeeAmount
                );
                
                // Return delta to account for fees taken
                return (BaseHook.afterSwap.selector, int128(int256(totalFeeAmount)));
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    // ==========================================
    // DYNAMIC FEE CALCULATION
    // ==========================================

    /// @notice Fetch ETH price for swaps (uses fallback if needed)
    /// @dev For swaps (failed price fetch doesn't interfere with execution)
    /// @return ethPriceUsd ETH price in USD (6 decimal precision)
    function _fetchEthPriceWithFallback() internal view returns (uint256 ethPriceUsd) {
        // Chain ID constants
        uint256 BASE_MAINNET = 8453;
        
        // Skip Chainlink on testnets - use fallback price directly
        if (block.chainid != BASE_MAINNET) {
            return fallbackEthPriceUsd;
        }
        
        // Only use Chainlink on Base mainnet
        try AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price is stale or invalid
            if (block.timestamp - updatedAt <= MAX_STALENESS && answer > 0) {
                uint256 oraclePrice = uint256(answer) / 100; // Convert 8→6 decimals
                return oraclePrice;
            }
        } catch {}
        
        // Fallback for mainnet oracle failures
        return fallbackEthPriceUsd;
    }

    /// @notice Calculate dynamic fee with exponential decay
    /// @param volumeEth Volume in ETH (wei)
    /// @param ethPriceUsd ETH price in USD (6 decimals)
    /// @return feeBps Fee in basis points
    function _calculateDynamicFee(uint256 volumeEth, uint256 ethPriceUsd) internal pure returns (uint256 feeBps) {
        uint256 volumeUsd = (volumeEth * ethPriceUsd) / (1 ether * 1e6);
        
        (uint256 alpha, uint256 vStartUsd, uint256 feeStart) = _getTierParameters(volumeUsd);
        
        uint256 volumeDiff = volumeUsd > vStartUsd ? volumeUsd - vStartUsd : 0;
        uint256 exponent = (alpha * volumeDiff) / SCALE_PARAMETER;
        
        uint256 expValue = _calculateExponentialDecay(exponent);
        
        uint256 feeRange = feeStart - FEE_MIN_BPS;
        uint256 dynamicComponent = (feeRange * expValue) / 1 ether;
        
        uint256 result = FEE_MIN_BPS + dynamicComponent;
        
        return result < FEE_MIN_BPS ? FEE_MIN_BPS : result;
    }

    /// @notice Get tier parameters based on USD volume
    function _getTierParameters(uint256 volumeUsd) internal pure returns (uint256 alpha, uint256 vStartUsd, uint256 feeStart) {
        if (volumeUsd <= TIER_1_THRESHOLD_USD) {
            return (ALPHA_TIER_1, 0, FEE_START_TIER_1);
        } else if (volumeUsd <= TIER_2_THRESHOLD_USD) {
            return (ALPHA_TIER_2, TIER_1_THRESHOLD_USD, FEE_START_TIER_2);
        } else if (volumeUsd <= TIER_3_THRESHOLD_USD) {
            return (ALPHA_TIER_3, TIER_2_THRESHOLD_USD, FEE_START_TIER_3);
        } else {
            return (ALPHA_TIER_4, TIER_3_THRESHOLD_USD, FEE_START_TIER_4);
        }
    }

    /// @notice Calculate e^(-x)
    /// @dev Calculates e^(-x/1000) with 18-decimal precision
    /// @param x Input value (will be divided by 1000 in calculation)
    /// @return result e^(-x/1000) scaled by 1e18
    function _calculateExponentialDecay(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 1 ether; // e^0 = 1
        if (x >= 10000) return 0;   // e^-10 ≈ 0, return 0 for extreme values
        
        SD59x18 negativeX = sd(-int256(x)) / sd(1000);
        SD59x18 result = exp(negativeX);
        
        return uint256(result.unwrap());
    }

    // ==========================================
    // UTILITY FUNCTIONS
    // ==========================================

    /// @notice Decode hookData into MultiHopContext
    /// @param hookData Encoded multi-hop context data
    /// @return context Decoded multi-hop context
    function _decodeHookData(bytes calldata hookData) private pure returns (MultiHopContext memory context) {
        if (hookData.length == 0) {
            return MultiHopContext(false, false); // Single hop default
        }
        return abi.decode(hookData, (MultiHopContext));
    }

    /// @notice Update oracle
    /// @param newOracleAddress Oracle address (address(0) = no change)
    /// @param newFallbackPrice Fallback price in USD (0 = no change)
    function updateOracle(
        address newOracleAddress, 
        uint256 newFallbackPrice
    ) external onlyAdmin(msg.sender) {
        
        // Update oracle address if provided
        if (newOracleAddress != address(0)) {
            address oldOracle = CHAINLINK_ETH_USD;
            CHAINLINK_ETH_USD = newOracleAddress;
            emit OracleAddressUpdated(newOracleAddress, msg.sender);
        }
        
        // Update fallback price if provided
        if (newFallbackPrice != 0) {
            uint256 oldPrice = fallbackEthPriceUsd;
            fallbackEthPriceUsd = newFallbackPrice;
            emit FallbackPriceUpdated(newFallbackPrice, msg.sender);
        }
    }

    // ==========================================
    // HOOK PERMISSIONS
    // ==========================================

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

    // ==========================================
    // EXTERNAL VIEW
    // ==========================================

    /// @notice Calculate dynamic fee for a given volume
    /// @param volumeEth Volume in ETH (wei)
    /// @return feeBps Dynamic fee rate in basis points
    /// @return ethPriceUsd ETH conversion price for stable fee tiers
    function simulateDynamicFee(uint256 volumeEth)
        external 
        view 
        returns (uint256 feeBps, uint256 ethPriceUsd)
    {
        ethPriceUsd = _fetchEthPriceWithFallback(); // Display execution price (6 decimals)
        feeBps = _calculateDynamicFee(volumeEth, ethPriceUsd);
    }
}