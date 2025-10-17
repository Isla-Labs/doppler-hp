// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IDopplerHook, IMigratorHook } from "src/interfaces/IHookSelector.sol";
import { IERC20, IWETH, IPermit2, MultiHopContext, IPositionManager } from "src/interfaces/IUtilities.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

/// @notice return schema for successful swap
struct SwapResult {
    uint256 amountOut;      // final output for the full route, including fee deductions
    uint256 totalGas;       // sum of gas paid for all hops
    uint256 totalFeesEth;   // all fees, ETH-denominated (wei)
}

/**
 * @title HP Swap Router
 * @dev Simple swap API with automatic pool detection, fee reduction for multihops, and UR-style hardening
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract HPSwapRouter is ReentrancyGuard {
    
    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    IWhitelistRegistry public immutable registry;
    address public immutable marketOrchestrator;

    // ------------------------------------------
    //  Pool Detection Config
    // ------------------------------------------

    // ETH native sentinel
    address public constant ETH_ADDR = address(0);

    // Canonical Permit2
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Tokens
    address public immutable USDC;
    address public immutable WETH;

    // Migrated playerToken pool params
    uint24 public constant migratorFee = 1000;
    int24 public constant migratorTickSpacing = 10;

    // Updateable ETH/USDC pool params (derived from poolId)
    bytes32 public ethUsdcPoolId;
    uint24 public ethUsdcFee;
    int24 public ethUsdcTickSpacing;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event EthUsdcPoolUpdated(bytes32 oldPoolId, bytes32 newPoolId, uint24 oldFee, uint24 newFee, int24 oldTick, int24 newTick);
    event SweepToken(address indexed token, address indexed to, uint256 amount);
    event SweepETH(address indexed to, uint256 amount);

    error NotWhitelisted();
    error InvalidAmount();
    error Slippage();
    error Expired;
    error BadRecipient();
    error InsufficientInput(uint256 expected, uint256 provided);
    error EthTransferFailed(uint256 amount, address to);
    error WethTransferFailed(uint256 amount, address to);
    error Erc20TransferFailed(address token, address to, uint256 amount);
    error BadEthUsdcBinding(bytes32 poolId, address currency0, address currency1, address hook);
    error Unauthorized();
    error EthUsdcPoolUnavailable();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier checkDeadline(uint256 deadline) {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        _;
    }

    modifier onlyMarketOrchestrator() {
        if (msg.sender != marketOrchestrator) revert Unauthorized();
        _;
    }

    // ------------------------------------------
    //  Constructor
    // ------------------------------------------

    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _registry,
        address _marketOrchestrator,
        address _usdc,
        address _weth,
        address positionManager_,
        bytes32 ethUsdcPoolId_
    ) {
        if (address(_poolManager) == address(0)) revert();
        if (address(_registry) == address(0)) revert();
        if (_marketOrchestrator == address(0)) revert();
        if (_usdc == address(0)) revert();
        if (_weth == address(0)) revert();
        if (positionManager_ == address(0)) revert();

        poolManager = _poolManager;
        registry = _registry;
        marketOrchestrator = _marketOrchestrator;

        USDC = _usdc;
        WETH = _weth;
        positionManager = positionManager_;

        if (ethUsdcPoolId_ != bytes32(0)) {
            (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
                IPositionManager(positionManager).poolKeys(ethUsdcPoolId_);

            address c0a = Currency.unwrap(c0);
            address c1a = Currency.unwrap(c1);
            if (!(c0a == ETH_ADDR && c1a == USDC && address(h) == address(0))) {
                revert BadEthUsdcBinding(ethUsdcPoolId_, c0a, c1a, address(h));
            }
            
            ethUsdcFee = fee;
            ethUsdcTickSpacing = spacing;
            ethUsdcPoolId = ethUsdcPoolId_;
        } else {
            ethUsdcFee = 0;
            ethUsdcTickSpacing = 0;
            ethUsdcPoolId = bytes32(0);
        }
    }

    // ------------------------------------------
    //  Upkeep
    // ------------------------------------------

    function rebindEthUsdc(bytes32 newPoolId) external onlyMarketOrchestrator {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(newPoolId);

        address c0a = Currency.unwrap(c0);
        address c1a = Currency.unwrap(c1);
        if (!(c0a == ETH_ADDR && c1a == USDC && address(h) == address(0))) {
            revert BadEthUsdcBinding(newPoolId, c0a, c1a, address(h));
        }

        bytes32 oldId = ethUsdcPoolId;
        uint24 oldFee = ethUsdcFee;
        int24 oldSpacing = ethUsdcTickSpacing;

        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = newPoolId;

        emit EthUsdcPoolUpdated(oldId, newPoolId, oldFee, fee, oldSpacing, spacing);
    }

    /// @notice Emergency-only fallback; router aims to be stateless via auto-refunds
    function sweepToken(address token, address to, uint256 amount) external onlyMarketOrchestrator {
        if (to == address(0)) revert BadRecipient();
        if (!IERC20(token).transfer(to, amount)) revert Erc20TransferFailed(token, to, amount);
        emit SweepToken(token, to, amount);
    }

    /// @notice Emergency-only fallback; router aims to be stateless via auto-refunds
    function sweepETH(address to, uint256 amount) external onlyMarketOrchestrator {
        if (to == address(0)) revert BadRecipient();
        (bool s, ) = to.call{ value: amount }("");
        if (!s) revert EthTransferFailed(amount, to);
        emit SweepETH(to, amount);
    }

    // ------------------------------------------
    //  Entry Point (exact input)
    // ------------------------------------------

    // Detects: PT<->PT (via ETH), ETH<->PT, USDC<->PT (via ETH)
    // Pass minOut=0 or deadline=0 to disable either check.
    function swap(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) nonReentrant returns (SwapResult memory res) {
        if (recipient == address(0)) revert BadRecipient();
        if (amountIn == 0) revert InvalidAmount();

        // Accept ETH overpay; settle exact; refund delta at end
        uint256 expectedMin = (inputToken == ETH_ADDR) ? amountIn : 0;
        if (msg.value < expectedMin) revert InsufficientInput(expectedMin, msg.value);

        // Ephemeral baselines (UR-like statelessness)
        uint256 ethBase = address(this).balance - msg.value;
        uint256 erc20Base = (inputToken == ETH_ADDR) ? 0 : IERC20(inputToken).balanceOf(address(this));
        uint256 gasStart = gasleft();

        // ---- Pipeline: settle -> swap hops -> take -> (fees tracked) ----

        bool inIsPT = _isPlayerToken(inputToken);
        bool outIsPT = _isPlayerToken(outputToken);
        bool inIsETH = (inputToken == ETH_ADDR);
        bool outIsETH = (outputToken == ETH_ADDR);
        bool inIsUSDC = (inputToken == USDC);
        bool outIsUSDC = (outputToken == USDC);

        if (!inIsETH) {
            _pullFromUser(inputToken, amountIn);
        }

        if (inIsPT && outIsPT) {
            // PT(in) -> ETH
            (PoolKey memory keyIn, bool migratedIn) = _playerPoolKey(inputToken);
            _settleExactIn(Currency.wrap(inputToken), amountIn);
            bytes memory hop1 = abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: false }));
            _swapExactIn(keyIn, /*zeroForOne*/ false, amountIn, hop1);

            uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
            if (!migratedIn) {
                res.totalFeesEth += _feeOnEthOutput(ethInterim, 300);
            }

            // ETH -> PT(out)
            (PoolKey memory keyOut, bool migratedOut) = _playerPoolKey(outputToken);
            if (ethInterim > 0) _swapExactIn(keyOut, /*zeroForOne*/ true, ethInterim, bytes(""));

            res.amountOut = _managerOwed(Currency.wrap(outputToken));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(outputToken), recipient, res.amountOut);

            if (ethInterim > 0) {
                if (migratedOut) {
                    uint256 bps = _migratorFeeBps(address(keyOut.hooks), ethInterim);
                    res.totalFeesEth += _feeOnEthInput(ethInterim, bps);
                } else {
                    res.totalFeesEth += _feeOnEthInput(ethInterim, 300);
                }
            }

        } else if (inIsPT && outIsETH) {
            (PoolKey memory keyIn, bool migratedIn) = _playerPoolKey(inputToken);
            _settleExactIn(Currency.wrap(inputToken), amountIn);
            _swapExactIn(keyIn, /*zeroForOne*/ false, amountIn, bytes(""));
            res.amountOut = _managerOwed(Currency.wrap(ETH_ADDR));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(ETH_ADDR), recipient, res.amountOut);

            if (migratedIn) {
                uint256 bps = _migratorFeeBps(address(keyIn.hooks), res.amountOut);
                res.totalFeesEth += _feeOnEthOutput(res.amountOut, bps);
            } else {
                res.totalFeesEth += _feeOnEthOutput(res.amountOut, 300);
            }
        } else if (outIsPT && inIsETH) {
            (PoolKey memory keyOut, bool migratedOut) = _playerPoolKey(outputToken);
            _settleExactIn(Currency.wrap(ETH_ADDR), amountIn);
            _swapExactIn(keyOut, /*zeroForOne*/ true, amountIn, bytes(""));
            res.amountOut = _managerOwed(Currency.wrap(outputToken));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(outputToken), recipient, res.amountOut);

            if (migratedOut) {
                uint256 bps = _migratorFeeBps(address(keyOut.hooks), amountIn);
                res.totalFeesEth += _feeOnEthInput(amountIn, bps);
            } else {
                res.totalFeesEth += _feeOnEthInput(amountIn, 300);
            }
        } else if (inIsPT && outIsUSDC) {
            // PT -> ETH (mark isUsdc=true to disable fee skip on first hop)
            if (ethUsdcPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();
            (PoolKey memory keyIn, bool migratedIn) = _playerPoolKey(inputToken);
            PoolKey memory keyMid = _ethUsdcKey();

            _settleExactIn(Currency.wrap(inputToken), amountIn);
            bytes memory hop1 = abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: true }));
            _swapExactIn(keyIn, /*zeroForOne*/ false, amountIn, hop1);

            uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
            if (migratedIn) {
                uint256 bps1 = _migratorFeeBps(address(keyIn.hooks), ethInterim);
                res.totalFeesEth += _feeOnEthOutput(ethInterim, bps1);
            } else {
                res.totalFeesEth += _feeOnEthOutput(ethInterim, 300);
            }

            if (ethInterim > 0) _swapExactIn(keyMid, /*zeroForOne*/ true, ethInterim, bytes(""));
            res.amountOut = _managerOwed(Currency.wrap(USDC));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(USDC), recipient, res.amountOut);

            if (ethInterim > 0) {
                res.totalFeesEth += _feeOnEthInput(ethInterim, _v4FeeBps(ethUsdcFee));
            }
        } else if (outIsPT && inIsUSDC) {
            // USDC -> ETH -> PT
            if (ethUsdcPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();
            PoolKey memory keyMid = _ethUsdcKey();
            (PoolKey memory keyOut, bool migratedOut) = _playerPoolKey(outputToken);

            _settleExactIn(Currency.wrap(USDC), amountIn);
            _swapExactIn(keyMid, /*zeroForOne*/ false, amountIn, bytes(""));

            uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
            {
                uint256 usdcFee = _feeOnUsdcInput(amountIn, _v4FeeBps(ethUsdcFee));
                uint256 ethPriceUsd = _ethPriceUsdFromToken(outputToken);
                if (ethPriceUsd != 0) {
                    uint256 usdcFeeAsEth = (usdcFee * 1e18) / ethPriceUsd;
                    res.totalFeesEth += usdcFeeAsEth;
                }
            }

            if (ethInterim > 0) _swapExactIn(keyOut, /*zeroForOne*/ true, ethInterim, bytes(""));
            res.amountOut = _managerOwed(Currency.wrap(outputToken));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(outputToken), recipient, res.amountOut);

            if (ethInterim > 0) {
                if (migratedOut) {
                    uint256 bps2 = _migratorFeeBps(address(keyOut.hooks), ethInterim);
                    res.totalFeesEth += _feeOnEthInput(ethInterim, bps2);
                } else {
                    res.totalFeesEth += _feeOnEthInput(ethInterim, 300);
                }
            }
        } else {
            revert NotWhitelisted();
        }

        if (minOut != 0 && res.amountOut < minOut) revert Slippage();

        // Auto-refunds (statelessness)
        _refundEthToSender(ethBase);
        if (inputToken != ETH_ADDR) _refundErc20ToSender(inputToken, erc20Base);

        res.totalGas = gasStart - gasleft();
    }

    // ------------------------------------------
    //  Input/Output
    // ------------------------------------------

    function _swapExactIn(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        bytes memory hookData
    ) internal {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? (type(uint160).min + 1) : (type(uint160).max - 1)
        });
        poolManager.swap(key, p, hookData);
    }

    // Prepay input into PoolManager (credits this router). Always settle the exact amount.
    function _settleExactIn(Currency cIn, uint256 amount) internal {
        address t = Currency.unwrap(cIn);
        if (t == ETH_ADDR) {
            poolManager.settle{ value: amount }();
        } else {
            poolManager.sync(cIn);
            if (!IERC20(t).transfer(address(poolManager), amount)) revert Erc20TransferFailed(t, address(poolManager), amount);
            poolManager.settle();
        }
    }

    // ------------------------------------------
    //  Internal helpers
    // ------------------------------------------

    function _managerOwed(Currency c) internal view returns (uint256) {
        int256 delta = poolManager.currencyDelta(address(this), c);
        return delta > 0 ? uint256(delta) : 0;
    }

    // Prefer Permit2 if allowance exists; fall back to ERC20.transferFrom
    function _pullFromUser(address token, uint256 amount) internal {
        (uint160 p2Amt, uint48 p2Exp, ) = IPermit2(PERMIT2).allowance(msg.sender, token, address(this));
        bool ok = p2Amt >= uint160(amount) && (p2Exp == 0 || p2Exp >= block.timestamp);
        if (ok) {
            IPermit2(PERMIT2).transferFrom(msg.sender, address(this), uint160(amount), token);
        } else {
            if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
                revert Erc20TransferFailed(token, address(this), amount);
            }
        }
    }

    // Auto-refund ETH with WETH fallback (UR-like)
    function _refundEthToSender(uint256 ethBase) internal {
        uint256 refund = address(this).balance - ethBase;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{ value: refund }("");
            if (!ok) {
                IWETH(WETH).deposit{ value: refund }();
                if (!IWETH(WETH).transfer(msg.sender, refund)) revert WethTransferFailed(refund, msg.sender);
            }
        }
    }

    // Auto-refund any ERC20 input delta to sender
    function _refundErc20ToSender(address token, uint256 base) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > base) {
            uint256 delta = bal - base;
            if (!IERC20(token).transfer(msg.sender, delta)) revert Erc20TransferFailed(token, msg.sender, delta);
        }
    }

    // ------------------------------------------
    //  PoolKey Construction
    // ------------------------------------------

    function _playerPoolKey(address pt) internal view returns (PoolKey memory key, bool hasMigrated) {
        if (!registry.isMarketActive(pt)) revert NotWhitelisted();

        hasMigrated = registry.hasMigrated(pt);
        (address dopplerHook, address migratorHook) = registry.getHooks(pt);

        if (!hasMigrated) {
            key = IDopplerHook(dopplerHook).poolKey();
        } else {
            key = PoolKey({
                currency0: Currency.wrap(ETH_ADDR),
                currency1: Currency.wrap(pt),
                hooks: IHooks(migratorHook),
                fee: migratorFee,
                tickSpacing: migratorTickSpacing
            });
        }
    }

    function _ethUsdcKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(ETH_ADDR),
            currency1: Currency.wrap(USDC),
            hooks: IHooks(address(0)),
            fee: ethUsdcFee,
            tickSpacing: ethUsdcTickSpacing
        });
    }

    // ------------------------------------------
    //  Fee Helpers
    // ------------------------------------------

    // Uniswap v4 fee param is hundredths of a bip; convert to bps
    function _v4FeeBps(uint24 feeParam) internal pure returns (uint256) {
        return uint256(feeParam) / 100;
    }

    // Dynamic fee bps from migrator hook (ignores ethPriceUsd here)
    function _migratorFeeBps(address migratorHook, uint256 volumeEth) internal view returns (uint256) {
        if (migratorHook == address(0)) return 0;
        (uint256 feeBps, ) = IMigratorHook(migratorHook).simulateDynamicFee(volumeEth);
        return feeBps;
    }

    // Fee when charged on ETH input (exact)
    function _feeOnEthInput(uint256 ethIn, uint256 feeBps) internal pure returns (uint256) {
        return (ethIn * feeBps) / 10_000;
    }

    // Fee when charged on ETH output (net → gross adjustment)
    function _feeOnEthOutput(uint256 ethOutNet, uint256 feeBps) internal pure returns (uint256) {
        uint256 denom = 10_000 - feeBps;
        return denom == 0 ? 0 : (ethOutNet * feeBps) / denom;
    }

    // Uniswap fee on USDC input (USDC 6d → reported as USDC)
    function _feeOnUsdcInput(uint256 usdcIn, uint256 feeBps) internal pure returns (uint256) {
        return (usdcIn * feeBps) / 10_000;
    }

    function _ethPriceUsdFromToken(address pt) internal view returns (uint256) {
        (, address migratorHook) = registry.getHooks(pt);
        if (migratorHook == address(0)) return 0;
        return IMigratorHook(migratorHook).quoteEthPriceUsd(); // 6 decimals
    }

    // ------------------------------------------
    //  Helpers
    // ------------------------------------------

    function _isPlayerToken(address token) internal view returns (bool) {
        return registry.isMarketActive(token);
    }

    function hasPermit2Allowance(address owner, address token, uint256 needed)
        external
        view
        returns (bool ok, uint160 amount, uint48 expiration)
    {
        (amount, expiration, ) = IPermit2(PERMIT2).allowance(owner, token, address(this));
        ok = amount >= uint160(needed) && (expiration == 0 || expiration >= block.timestamp);
    }

    function hasErc20Allowance(address owner, address token, uint256 needed) external view returns (bool) {
        return IERC20(token).allowance(owner, address(this)) >= needed;
    }

    receive() external payable {}
}