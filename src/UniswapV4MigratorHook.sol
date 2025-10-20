// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LimitOrderHook} from "@oz-hooks/general/LimitOrderHook.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {BalanceDelta} from "@v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {SwapParams} from "@v4-core/types/PoolOperation.sol";
import {SafeCastLib} from "@solady/utils/SafeCastLib.sol";
import {SD59x18, exp, sd} from "@prb/math/src/SD59x18.sol";
import {UniswapV4Migrator} from "src/UniswapV4Migrator.sol";
import {IWhitelistRegistry} from "src/interfaces/IWhitelistRegistry.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {MultiHopContext} from "src/stores/MultiHopContext.sol";

/**
 * @title Uniswap V4 Migrator Hook with Dynamic Fees and Limit Order Support
 * @dev Extends OpenZeppelin's LimitOrderHook (https://github.com/OpenZeppelin/uniswap-hooks/blob/14be1504717139e10be4ec9c9ec95f5ffe8fba33/src/general/LimitOrderHook.sol)
 * @author Whetstone Research, Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract UniswapV4MigratorHook is LimitOrderHook {
    using PoolIdLibrary for PoolKey;
    using SafeCastLib for uint256;

    // Migrator config
    address public immutable migrator;
    IWhitelistRegistry public whitelistRegistry;
    address public immutable swapQuoter;
    address public immutable swapRouter;
    address public immutable rewardsTreasury;
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
    uint256 internal constant TIER_1_THRESHOLD_USD = 0;
    uint256 internal constant TIER_2_THRESHOLD_USD = 500;
    uint256 internal constant TIER_3_THRESHOLD_USD = 5000;
    uint256 internal constant TIER_4_THRESHOLD_USD = 50000;
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
    //  Access Control
    // ------------------------------------------

    modifier onlyMigrator(address sender) {
        if (sender != migrator) revert OnlyMigrator();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    /**
     * @notice Constructor for the Uniswap V4 Migrator Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param _migrator Address of the Uniswap V4 Migrator contract
     * @param _whitelistRegistry Address of the Whitelist Registry contract
     * @param _swapQuoter Address of the HP Swap Quoter contract
     * @param _swapRouter Address of the HP Swap Router contract
     * @param _rewardsTreasury Proxy address of the RewardsTreasury contract
     * @param _feeRouter Proxy address of the FeeRouter contract
     */
    constructor(
        IPoolManager manager,
        UniswapV4Migrator _migrator,
        IWhitelistRegistry _whitelistRegistry,
        address _swapQuoter,
        address _swapRouter,
        address _rewardsTreasury,
        address _feeRouter
    ) BaseHook(manager) { // BaseHook is an ancestor of LimitOrderHook
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
        PoolKey calldata,
        uint160
    ) internal view override onlyMigrator(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Hook that runs before swap
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Dynamic fee on buys (ETH -> playerToken)
        if (swapParams.zeroForOne) {
            // Market status check
            if (!whitelistRegistry.isMarketActive(Currency.unwrap(key.currency1))) revert MarketSunset();

            // Apply dynamic fee on ETH input
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 inputAmount = uint256(swapParams.amountSpecified < 0 ? -swapParams.amountSpecified : swapParams.amountSpecified);
            uint256 dynamicFeeBps = _calculateDynamicFee(inputAmount, ethPriceUsd);

            // Re-route and update delta
            if (dynamicFeeBps > 0) {
                uint256 totalFeeAmount = (inputAmount * dynamicFeeBps) / BPS;

                // Split fees 89:11 for PBR
                uint256 rewardsAmount = (totalFeeAmount * PBR_BPS) / BPS;
                uint256 feeAmount = totalFeeAmount - rewardsAmount;

                // Transfer via PoolManager
                poolManager().take(key.currency0, rewardsTreasury, rewardsAmount);
                poolManager().take(key.currency0, feeRouter, feeAmount);

                // Return delta to account for fees taken
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(totalFeeAmount.toInt128(), 0), 0);
            }
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /// @notice Hook that runs after swap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Emit swap event
        (uint160 sqrtPriceX96,,,) = poolManager().getSlot0(key.toId());
        emit Swap(Currency.unwrap(key.currency1), sqrtPriceX96);

        // Run limit-order fills
        super._afterSwap(sender, key, swapParams, delta, hookData);

        // Dynamic fee on sells (playerToken -> ETH)
        if (!swapParams.zeroForOne) {
            // Decode multi-hop context
            MultiHopContext memory context = _decodeHookData(hookData);

            // Skip fee: (via Router/Quoter: first-hop playerToken <> playerToken) or market inactive
            if (
                ((sender == swapRouter || sender == swapQuoter) && context.isMultiHop && !context.isUsdc) ||
                (!whitelistRegistry.isMarketActive(Currency.unwrap(key.currency1)))
            ) {
                return (BaseHook.afterSwap.selector, 0);
            }

            // Apply dynamic fee on ETH output
            uint256 ethPriceUsd = _fetchEthPriceWithFallback();
            uint256 outputAmount = delta.amount0() < 0
                ? uint256(uint128(-delta.amount0()))
                : uint256(uint128(delta.amount0()));
            uint256 dynamicFeeBps = _calculateDynamicFee(outputAmount, ethPriceUsd);

            if (dynamicFeeBps > 0) {
                uint256 totalFeeAmount = (outputAmount * dynamicFeeBps) / BPS;
                uint256 rewardsAmount = (totalFeeAmount * PBR_BPS) / BPS;
                uint256 feeAmount = totalFeeAmount - rewardsAmount;

                poolManager().take(key.currency0, rewardsTreasury, rewardsAmount);
                poolManager().take(key.currency0, feeRouter, feeAmount);

                return (BaseHook.afterSwap.selector, totalFeeAmount.toInt128());
            }
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------
    //  Dynamic Fee Calculation
    // ------------------------------------------

    /**
     * @notice Calculate dynamic fee with exponential decay
     * @dev feeRate = min_fee + (feeRate_start - fee_min) * e^(-a * (v - v_start) / scale)
     * @param volumeEth Volume in ETH (wei)
     * @param ethPriceUsd ETH price in USD (6 decimals)
     * @return feeBps Fee in basis points
     */
    function _calculateDynamicFee(uint256 volumeEth, uint256 ethPriceUsd) internal pure returns (uint256 feeBps) {
        // Standardize volume (v) in usd (6dp)
        uint256 volumeUsd = (volumeEth * ethPriceUsd) / (1 ether * 1e6);

        // Get decay factor (a), vStartUsd (v_start), feeStart (feeRate_start) based on volume tier
        (uint256 alpha, uint256 vStartUsd, uint256 feeStart) = _getTierParameters(volumeUsd);

        // Calculate +difference between volume (v) and tier's starting volume (v_start)
        uint256 volumeDiff = volumeUsd > vStartUsd ? volumeUsd - vStartUsd : 0;

        // Build the exponent input and compute the exponential term
        uint256 exponent = (alpha * volumeDiff) / SCALE_PARAMETER;
        uint256 expValue = _calculateExponentialDecay(exponent);

        // Map decay into fee range
        uint256 feeRange = feeStart - FEE_MIN_BPS;
        uint256 dynamicComponent = (feeRange * expValue) / 1 ether;

        // Final fee in bps
        uint256 result = FEE_MIN_BPS + dynamicComponent;
        return result < FEE_MIN_BPS ? FEE_MIN_BPS : result;
    }

    /// @notice Get tier parameters based on USD volume
    function _getTierParameters(uint256 volumeUsd) internal pure returns (uint256 alpha, uint256 vStartUsd, uint256 feeStart) {
        if (volumeUsd <= TIER_2_THRESHOLD_USD) return (ALPHA_TIER_1, TIER_1_THRESHOLD_USD, FEE_START_TIER_1);
        if (volumeUsd <= TIER_3_THRESHOLD_USD) return (ALPHA_TIER_2, TIER_2_THRESHOLD_USD, FEE_START_TIER_2);
        if (volumeUsd <= TIER_4_THRESHOLD_USD) return (ALPHA_TIER_3, TIER_3_THRESHOLD_USD, FEE_START_TIER_3);
        return (ALPHA_TIER_4, TIER_4_THRESHOLD_USD, FEE_START_TIER_4);
    }

    /// @notice Calculate e^(-x/1000) with 18-decimal precision;
    ///         x Unscaled exponent input; function computes e^(-x/1000)
    function _calculateExponentialDecay(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 1 ether; // e^0 = 1
        if (x >= 10000) return 0;   // e^(-10) ≈ 0 (clamp for extreme values)

        // Convert to signed fixed-point and compute e^(-x/1000)
        SD59x18 negativeX = sd(-int256(x)) / sd(1000);
        SD59x18 result = exp(negativeX);
        return uint256(result.unwrap()); // 1e18-scaled
    }

    // ------------------------------------------
    //  Internal
    // ------------------------------------------

    /// @notice Decode hookData into MultiHopContext
    function _decodeHookData(bytes calldata hookData) private pure returns (MultiHopContext memory context) {
        if (hookData.length == 0) return MultiHopContext(false, false);
        return abi.decode(hookData, (MultiHopContext));
    }

    /// @notice Fetch ETH price (uses fallback on testnet)
    function _fetchEthPriceWithFallback() internal view returns (uint256 ethPriceUsd) {
        uint256 BASE_MAINNET = 8453;
        if (block.chainid != BASE_MAINNET) return fallbackEthPriceUsd;

        try AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer > 0) return uint256(answer) / 100; // 8dp -> 6dp
        } catch {}

        return fallbackEthPriceUsd;
    }

    // ------------------------------------------
    //  Hook Permissions
    // ------------------------------------------

    /// @notice Union of permissions for UniswapV4MigratorHook & LimitOrderHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
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
    //  External View
    // ------------------------------------------

    /// @notice Gated ETH/USD price for router/quoter fee conversion (6 decimals)
    function quoteEthPriceUsd() external view returns (uint256 ethPriceUsd) {
        if (msg.sender != swapRouter && msg.sender != swapQuoter) revert NotAllowed();
        return _fetchEthPriceWithFallback();
    }

    /// @notice Calculate dynamic fee for a given volume
    function simulateDynamicFee(uint256 volumeEth) external view returns (uint256 feeBps, uint256 ethPriceUsd) {
        ethPriceUsd = _fetchEthPriceWithFallback();
        feeBps = _calculateDynamicFee(volumeEth, ethPriceUsd);
    }
}