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
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

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
 * @custom:security-contact security@islalabs.co
 */
contract UniswapV4MigratorHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the Uniswap V4 Migrator contract
    address public immutable migrator;

    /// @notice Whitelist registry for retrieving market status
    IWhitelistRegistry public whitelistRegistry;

    /// @notice Address of the HPSwapQuoter contract
    address public immutable swapQuoter;

    /// @notice Address of the HPSwapRouter contract
    address public immutable swapRouter;

    /// @notice Proxy address of the RewardsTreasury contract for PBR distribution
    address public immutable rewardsTreasury;

    /// @notice Proxy address of the FeeRouter contract
    address public immutable feeRouter;

    // ------------------------------------------
    //  Dynamic Fee Constants
    // ------------------------------------------

    /// @notice Chainlink ETH-USD price feed on Base
    address public immutable CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    
    /// @notice Fallback ETH-USD price for testnet
    uint256 public immutable fallbackEthPriceUsd = 3000000000; // (6 decimals)

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

    /// @notice Fee split BPS: 89% for Performance Based Returns
    uint256 constant BPS = 10_000;
    uint256 constant PBR_BPS = 8900;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event Swap(address indexed token, uint256 sqrtPriceX96);

    error OnlyMigrator();
    error ZeroAddress();
    error NotAllowed();
    error MarketSunset();

    // ------------------------------------------
    //  Access
    // ------------------------------------------

    /// @notice Modifier to ensure the caller is the Uniswap V4 Migrator
    modifier onlyMigrator(address sender) {
        if (sender != migrator) revert OnlyMigrator();
        _;
    }

    // ------------------------------------------
    //  Constructor
    // ------------------------------------------

    /// @notice Constructor for the Uniswap V4 Migrator Hook
    /// @param manager Address of the Uniswap V4 Pool Manager
    /// @param _migrator Address of the Uniswap V4 Migrator contract
    /// @param _whitelistRegistry Address of the Whitelist Registry contract
    /// @param _swapQuoter Address of the HP Swap Quoter contract
    /// @param _swapRouter Address of the HP Swap Router contract
    /// @param _rewardsTreasury Proxy address of the RewardsTreasury contract
    /// @param _feeRouter Proxy address of the FeeRouter contract
    constructor(
        IPoolManager manager, 
        UniswapV4Migrator _migrator,
        IWhitelistRegistry _whitelistRegistry,
        address _swapQuoter,
        address _swapRouter,
        address _rewardsTreasury,
        address _feeRouter
    ) BaseHook(manager) {
        if (
            address(_migrator) == address(0) || 
            address(_whitelistRegistry) == address(0) || 
            _swapQuoter == address(0) || 
            _swapRouter == address(0) || 
            _rewardsTreasury == address(0) || 
            _feeRouter == address(0)
        ) revert ZeroAddress();

        migrator = address(_migrator);
        whitelistRegistry = _whitelistRegistry;
        swapQuoter = _swapQuoter;
        swapRouter = _swapRouter;
        rewardsTreasury = _rewardsTreasury;
        feeRouter = _feeRouter;
    }

    // ------------------------------------------
    //  Hook Functions
    // ------------------------------------------

    /// @notice Hook that runs before pool initialization
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal view override onlyMigrator(sender) returns (bytes4) {
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
            if (!whitelistRegistry.isMarketActive(Currency.unwrap(key.currency1))) revert MarketSunset();

            // Apply dynamic fees on ETH input
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 inputAmount = uint256(swapParams.amountSpecified < 0 
                ? -swapParams.amountSpecified 
                : swapParams.amountSpecified
            );
            uint256 dynamicFeeBps = _calculateDynamicFee(inputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (inputAmount * dynamicFeeBps) / BPS;

                // Ensure compatibility with int128 delta
                require(totalFeeAmount <= type(uint128).max, "fee overflow");

                // Split fees 89:11 for PBR
                uint256 rewardsAmount = (totalFeeAmount * PBR_BPS) / BPS;
                uint256 feeAmount = totalFeeAmount - rewardsAmount;

                // Transfer via PoolManager
                poolManager.take(key.currency0, rewardsTreasury, rewardsAmount);
                poolManager.take(key.currency0, feeRouter, feeAmount);
                
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

        // Retrieve post-swap price
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Emit swap event for indexer
        emit Swap(Currency.unwrap(key.currency1), sqrtPriceX96);

        // Check direction (Player Token → ETH)
        bool isSell = !swapParams.zeroForOne;
        
        if (isSell) {
            // Decode multi-hop context
            MultiHopContext memory context = _decodeHookData(hookData);
            
            // Skip fee collection for PlayerToken → PlayerToken multi-hops (router or quoter)
            if ((sender == swapRouter || sender == swapQuoter) && context.isMultiHop && !context.isUsdc) {
                return (BaseHook.afterSwap.selector, 0); // No fee on first hop
            }
            
            // Apply dynamic fees on ETH output
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 outputAmount = delta.amount0() < 0 
                ? uint256(uint128(-delta.amount0())) 
                : uint256(uint128(delta.amount0()));
            uint256 dynamicFeeBps = _calculateDynamicFee(outputAmount, ethPriceUsd);
            
            if (dynamicFeeBps > 0) {
                // Calculate fee amount in ETH
                uint256 totalFeeAmount = (outputAmount * dynamicFeeBps) / BPS;

                // Ensure compatibility with int128 delta
                require(totalFeeAmount <= type(uint128).max, "fee overflow");

                // Split fees 89:11 for PBR
                uint256 rewardsAmount = (totalFeeAmount * PBR_BPS) / BPS;
                uint256 feeAmount = totalFeeAmount - rewardsAmount;

                // Transfer via PoolManager
                poolManager.take(key.currency0, rewardsTreasury, rewardsAmount);
                poolManager.take(key.currency0, feeRouter, feeAmount);

                // Return delta to account for fees taken
                return (BaseHook.afterSwap.selector, int128(int256(totalFeeAmount)));
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------
    //  Dynamic Fee Calculation
    // ------------------------------------------

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

    // ------------------------------------------
    //  Utility Functions
    // ------------------------------------------

    /// @notice Decode hookData into MultiHopContext
    /// @param hookData Encoded multi-hop context data
    /// @return context Decoded multi-hop context
    function _decodeHookData(bytes calldata hookData) private pure returns (MultiHopContext memory context) {
        if (hookData.length == 0) {
            return MultiHopContext(false, false); // Single hop default
        }
        return abi.decode(hookData, (MultiHopContext));
    }

    /// @notice Fetch ETH price (uses fallback on testnet)
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
            uint80, int256 answer, uint256, uint256, uint80
        ) {
            if (answer > 0) {
                return uint256(answer) / 100; // Convert 8→6 decimals
            }
        } catch {}
        
        // Fallback for mainnet oracle failures
        return fallbackEthPriceUsd;
    }

    // ------------------------------------------
    //  Hook Permissions
    // ------------------------------------------

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

    // ------------------------------------------
    //  External Helpers
    // ------------------------------------------

    /// @notice Gated ETH/USD price for router/quoter fee conversion (6 decimals)
    function quoteEthPriceUsd() external view returns (uint256) {
        if (msg.sender != swapRouter && msg.sender != swapQuoter) revert NotAllowed();
        return _fetchEthPriceWithFallback();
    }

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