// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { LimitOrderHook, OrderIdLibrary } from "src/extensions/LimitOrderHook.sol";
import { Hooks } from "@oz-v4-core/libraries/Hooks.sol";
import { PoolKey } from "@oz-v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@oz-v4-core/types/PoolId.sol";
import { BalanceDelta } from "@oz-v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@oz-v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "@oz-v4-core/types/Currency.sol";
import { SwapParams } from "@oz-v4-core/types/PoolOperation.sol";
import { StateLibrary } from "@oz-v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "@oz-v4-core/interfaces/IPoolManager.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { SD59x18, exp, sd } from "@prb/math/src/SD59x18.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";
import { AggregatorV3Interface } from "src/interfaces/AggregatorV3Interface.sol";
import { SwapContext } from "src/stores/SwapContext.sol";

/**
 * @title Uniswap V4 Migrator Hook with Dynamic Fees and Limit Order Support
 * @dev Dynamic fee is a more efficient pricing mechanism for rewardsTreasury contributions; mitigates 1:not-1 correlation between volume and PBR
 * @dev Extends OpenZeppelin's LimitOrderHook (https://github.com/OpenZeppelin/uniswap-hooks/blob/14be1504717139e10be4ec9c9ec95f5ffe8fba33/src/general/LimitOrderHook.sol)
 *      - Local import uses trusted forwarder pattern to replace msg.sender in OZ LimitOrderHook with new sender param; all other functionality remains intact
 * @author Whetstone Research; Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract UniswapV4MigratorHook is LimitOrderHook {
    using PoolIdLibrary for PoolKey;
    using SafeCastLib for uint256;
    using StateLibrary for IPoolManager;

    IWhitelistRegistry public immutable whitelistRegistry;

    address public immutable migrator;
    address public immutable swapQuoter;
    address public immutable swapRouter;
    address public immutable limitRouter;
    address public immutable rewardsTreasury;
    address public immutable feeRouter;

    // ------------------------------------------
    //  Dynamic Fee Constants
    // ------------------------------------------

    /// @notice Chainlink ETH-USD price feed on Base
    address public immutable CHAINLINK_ETH_USD;
    uint8 public immutable feedDecimals;

    /// @notice Fallback ETH-USD price for testnet
    uint256 public immutable fallbackEthPriceUsd;

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

    error ZeroAddress();
    error NotAllowed();
    error MarketSunset();
    error OnlyBuys();
    error OnlySells();
    error NoSender();
    error DepositsDisabled();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyMigrator(address sender) {
        if (sender != migrator) revert NotAllowed();
        _;
    }

    modifier onlyLimitRouter() {
        if (msg.sender != limitRouter) revert NotAllowed();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor(
        UniswapV4Migrator migrator_,
        IWhitelistRegistry whitelistRegistry_,
        address swapQuoter_,
        address swapRouter_,
        address limitRouterProxy_,
        address rewardsTreasury_,
        address feeRouter_
    ) { 
        if (
            address(migrator_) == address(0) || 
            address(whitelistRegistry_) == address(0) || 
            swapQuoter_ == address(0) || 
            swapRouter_ == address(0) || 
            limitRouterProxy_ == address(0) || 
            rewardsTreasury_ == address(0) || 
            feeRouter_ == address(0)
        ) revert ZeroAddress();

        migrator = address(migrator_);
        whitelistRegistry = whitelistRegistry_;
        swapQuoter = swapQuoter_;
        swapRouter = swapRouter_;
        limitRouter = limitRouterProxy_;
        rewardsTreasury = rewardsTreasury_;
        feeRouter = feeRouter_;

        CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
        fallbackEthPriceUsd = 3000000000; // 6 decimals

        uint8 _dec = 8;
        if (block.chainid == 8453) {
            try AggregatorV3Interface(CHAINLINK_ETH_USD).decimals() returns (uint8 d) {
                _dec = d;
            } catch {}
        }
        feedDecimals = _dec;
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
        return this.beforeInitialize.selector;
    }

    /// @notice Hook that runs before swap
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Dynamic fee on exact-input buys (ETH -> playerToken)
        if (swapParams.zeroForOne) {
            if (!whitelistRegistry.isMarketActive(Currency.unwrap(key.currency1))) revert MarketSunset();

            if (swapParams.amountSpecified < 0) {
                return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
            }

            uint256 feeEth = _takeEthFee(key, uint256(swapParams.amountSpecified));
            if (feeEth > 0) {
                return (this.beforeSwap.selector, toBeforeSwapDelta(feeEth.toInt128(), 0), 0);
            }
        }

        return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    /// @notice Hook that runs after swap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Run limit-order fills
        super._afterSwap(sender, key, swapParams, delta, hookData);

        // Emit swap event
        (uint160 sqrtPriceX96,,,) = poolManager().getSlot0(key.toId());
        emit Swap(Currency.unwrap(key.currency1), sqrtPriceX96);

        // Dynamic fee on exact-output buys (ETH -> playerToken)
        if (swapParams.zeroForOne && swapParams.amountSpecified < 0) {
            uint256 feeEth = _takeEthFee(key, _absDelta0(delta));
            if (feeEth > 0) return (this.afterSwap.selector, feeEth.toInt128());
        }

        // Dynamic fee on sells (playerToken -> ETH)
        if (!swapParams.zeroForOne) {
            if (_shouldSkipFee(sender, key, hookData)) return (this.afterSwap.selector, 0);

            uint256 feeEth = _takeEthFee(key, _absDelta0(delta));
            if (feeEth > 0) return (this.afterSwap.selector, feeEth.toInt128());
        }
        
        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------------
    //  Limit Orders
    // ------------------------------------------

    /// @notice Reads the appended 20 bytes from HPLimitRouter to replace msg.sender with owner address
    function _msgSenderEx() internal view returns (address sender) {
        if (msg.sender == limitRouter) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    /// @notice Uses trusted forwarder pattern to place !zeroForOne limit orders
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint128 liquidity
    ) public override onlyLimitRouter {
        if (zeroForOne) revert OnlySells();

        address sender = _msgSenderEx();
        if (sender == address(0) || sender == limitRouter) revert NoSender();

        _placeOrder(key, tick, zeroForOne, liquidity, sender);
    }

    /// @notice Uses trusted forwarder pattern to place zeroForOne limit orders (ETH as currency0) with pre-computed headroom
    function placeOrderEth(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint128 liquidity
    ) external payable onlyLimitRouter {
        if (!zeroForOne) revert OnlyBuys();

        // Resolve end-user
        address sender = _msgSenderEx();
        if (sender == address(0) || sender == limitRouter) revert NoSender();

        // Budget is the ETH forwarded by the router in this call (already incorporates headroom)
        uint256 budget = msg.value;

        // Measure hook balance before placement
        uint256 balBefore = address(this).balance;

        // Computes principal from liquidity and deducts from hook balance
        _placeOrder(key, tick, zeroForOne, liquidity, sender);

        // Measure consumption
        uint256 balAfter = address(this).balance;
        uint256 spent = balBefore > balAfter ? balBefore - balAfter : 0;
        uint256 refund = budget > spent ? budget - spent : 0;

        // Refund any surplus back to the user via router
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{ value: refund }("");
            require(ok, "REFUND_FAIL");
        }
    }

    /// @notice Uses trusted forwarder pattern to cancel limit orders with user as owner
    function cancelOrder(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        address to
    ) public override onlyLimitRouter {
        address sender = _msgSenderEx();
        if (sender == address(0) || sender == limitRouter) revert NoSender();

        to = sender;
        _cancelOrder(key, tickLower, zeroForOne, to, sender);
    }

    /// @notice Uses trusted forwarder pattern to withdraw limit orders with post-execution dynamic fees
    function withdraw(
        OrderIdLibrary.OrderId orderId,
        address to
    ) public override onlyLimitRouter returns (uint256 amount0, uint256 amount1) {
        address sender = _msgSenderEx();
        if (sender == address(0) || sender == limitRouter) revert NoSender();

        to = limitRouter;
        return _withdraw(orderId, to, sender);
    }

    // ------------------------------------------
    //  Fee Calculation
    // ------------------------------------------

    /**
     * @notice Dynamic fee with exponential decay
     * @dev feeRate = min_fee + (feeRate_start - fee_min) * e^(-a * (v - v_start) / scale)
     * @param volumeEth Volume in ETH (wei)
     * @param ethPriceUsd ETH price in USD (6 decimals)
     * @return feeBps Fee in basis points
     */
    function _calculateDynamicFee(uint256 volumeEth, uint256 ethPriceUsd) internal pure returns (uint256 feeBps) {
        // Standardize volume (v) in usd
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

    /**
     * @notice Get tier parameters based on USD volume; volume is converted from ETH for stable fee tier values (v_start)
     * @dev Returns static variables from cache so that volume (v) is the only dynamic input
     * @param volumeUsd Volume in USD
     * @return alpha Decay factor for fee tier
     * @return vStartUsd Starting volume threshold for fee tier
     * @return feeStart Precomputed fee (bps) at v_start for fee tier
     */
    function _getTierParameters(uint256 volumeUsd) internal pure returns (uint256 alpha, uint256 vStartUsd, uint256 feeStart) {
        if (volumeUsd <= TIER_2_THRESHOLD_USD) return (ALPHA_TIER_1, TIER_1_THRESHOLD_USD, FEE_START_TIER_1);
        if (volumeUsd <= TIER_3_THRESHOLD_USD) return (ALPHA_TIER_2, TIER_2_THRESHOLD_USD, FEE_START_TIER_2);
        if (volumeUsd <= TIER_4_THRESHOLD_USD) return (ALPHA_TIER_3, TIER_3_THRESHOLD_USD, FEE_START_TIER_3);
        return (ALPHA_TIER_4, TIER_4_THRESHOLD_USD, FEE_START_TIER_4);
    }

    /**
	 * @notice Calculate e^(-x/1000) with 18-decimal precision
     * @dev Uses PRBMath SD59x18 to evaluate exp on the signed fixed-point input -x/1000
	 * @param x Unscaled exponent input
     * @return value The 1e18-scaled result of e^(-x/1000)
     */
    function _calculateExponentialDecay(uint256 x) internal pure returns (uint256 value) {
        if (x == 0) return 1 ether; // e^0 = 1
        if (x >= 10000) return 0;   // e^(-10) ≈ 0 (clamp for extreme values)

        // Convert to signed fixed-point and compute e^(-x/1000)
        SD59x18 negativeX = sd(-int256(x)) / sd(1000);
        SD59x18 result = exp(negativeX);

        return uint256(result.unwrap()); // 1e18-scaled
    }

    // ------------------------------------------
    //  Fee Settlement
    // ------------------------------------------

    /// @notice Split fees and settle in ETH
    function _takeEthFee(PoolKey calldata key, uint256 baseEth)
        internal
        returns (uint256 feeEth)
    {
        if (baseEth == 0) return 0;

        // Apply dynamic fee on base ETH
        uint256 feeBps = _calculateDynamicFee(baseEth, _ethPriceUsd());
        feeEth = (baseEth * feeBps) / BPS;

        // Split fees 89:11 for PBR
        uint256 rewardsAmount = (feeEth * PBR_BPS) / BPS;
        uint256 feeAmount = feeEth - rewardsAmount;

        // Transfer via PoolManager
        poolManager().take(key.currency0, rewardsTreasury, rewardsAmount);
        poolManager().take(key.currency0, feeRouter, feeAmount);
    }

    /// @notice Check pre-conditions for fee settlement
    function _shouldSkipFee(address sender, PoolKey calldata key, bytes calldata hookData) internal view returns (bool) {
        if (!whitelistRegistry.isMarketActive(Currency.unwrap(key.currency1))) return true;

        // Decode swap context
        SwapContext memory ctx = _decodeHookData(hookData);

        // Skips sell-side fee on limit withdrawals & first-hop of playerToken<>playerToken swaps
        if ((sender == swapRouter || sender == swapQuoter) && ctx.skipFee) return true;

        return false;
    }

    // ------------------------------------------
    //  Internal
    // ------------------------------------------

    /// @notice Decode hookData into SwapContext
    function _decodeHookData(bytes calldata hookData) private pure returns (SwapContext memory context) {
        if (hookData.length == 0) return SwapContext(false);
        return abi.decode(hookData, (SwapContext));
    }

    /// @notice Return ETH moved during the swap
    function _absDelta0(BalanceDelta delta) internal pure returns (uint256) {
        return delta.amount0() < 0
            ? uint256(uint128(-delta.amount0()))
            : uint256(uint128(delta.amount0()));
    }

    /// @notice Fetch ETH price (uses fallback on testnet)
    function _ethPriceUsd() internal view returns (uint256 ethPriceUsd) {
        if (block.chainid != 8453) return fallbackEthPriceUsd;

        try AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData()
            returns (uint80 roundId, int256 answer, uint256 /* startedAt */, uint256 updatedAt, uint80 answeredInRound)
        {
            if (answer > 0 && updatedAt != 0 && answeredInRound >= roundId) {
                uint8 dec = feedDecimals;
                if (dec >= 6) {
                    uint256 factor = 10 ** (uint256(dec) - 6);
                    return uint256(answer) / factor;
                } else {
                    uint256 factor = 10 ** (6 - uint256(dec));
                    return uint256(answer) * factor;
                }
            }
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
        return _ethPriceUsd();
    }

    /// @notice Calculate dynamic fee for a given volume
    function simulateDynamicFee(uint256 volumeEth) external view returns (uint256 feeBps, uint256 ethPriceUsd) {
        ethPriceUsd = _ethPriceUsd();
        feeBps = _calculateDynamicFee(volumeEth, ethPriceUsd);
    }
}