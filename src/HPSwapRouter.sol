// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Core
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IDopplerHook, IMigratorHook } from "src/interfaces/IHookSelector.sol";
import { IERC20, IWETH, IPermit2, MultiHopContext, IPositionManager } from "src/interfaces/IUtilities.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

struct SwapResult {
    uint256 amountOut;      // final output for the full route, including fee deductions
    uint256 totalGas;       // sum of gas paid for all hops
    uint256 totalFeesEth;   // all fees, ETH-denominated (wei)
}

// Errors
error NotWhitelisted();
error InvalidAmount();
error Slippage();
error Expired;

/**
 * @title HP Swap Router
 * @dev Simple swap API with UR-style hardening and internal pipeline:
 *      - Pool detection + hop sequencing (avoids double fee for playerToken <> playerToken swaps)
 *      - ETH overpay accepted, settle exact, auto-refund (WETH fallback)
 *      - ERC20 input ephemeral refund
 *      - OZ ReentrancyGuard
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract HPSwapRouter is ReentrancyGuard {
    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    IWhitelistRegistry public immutable registry;
    address public immutable marketOrchestrator;

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

    event PtToPt(
        address indexed sender,
        address indexed ptIn,
        address indexed ptOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    event EthUsdcRebound(bytes32 oldPoolId, bytes32 newPoolId, uint24 oldFee, uint24 newFee, int24 oldTick, int24 newTick);
    event SweepToken(address indexed token, address indexed to, uint256 amount);
    event SweepETH(address indexed to, uint256 amount);

    modifier checkDeadline(uint256 deadline) {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        _;
    }

    modifier onlyMarketOrchestrator() {
        require(msg.sender == marketOrchestrator, "Not authorized");
        _;
    }

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

        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(ethUsdcPoolId_);

        require(Currency.unwrap(c0) == ETH_ADDR && Currency.unwrap(c1) == USDC && address(h) == address(0), "BAD_ETH_USDC");
        
        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = ethUsdcPoolId_;
    }

    // ============ Admin ============

    function rebindEthUsdc(bytes32 newPoolId) external onlyMarketOrchestrator {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(newPoolId);

        require(Currency.unwrap(c0) == ETH_ADDR && Currency.unwrap(c1) == USDC && address(h) == address(0), "BAD_ETH_USDC");

        bytes32 oldId = ethUsdcPoolId;
        uint24 oldFee = ethUsdcFee;
        int24 oldSpacing = ethUsdcTickSpacing;

        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = newPoolId;

        emit EthUsdcRebound(oldId, newPoolId, oldFee, fee, oldSpacing, spacing);
    }

    // Emergency-only fallback; router aims to be stateless via auto-refunds
    function sweepToken(address token, address to, uint256 amount) external onlyMarketOrchestrator {
        require(to != address(0), "bad to");
        require(IERC20(token).transfer(to, amount), "sweep token");
        emit SweepToken(token, to, amount);
    }

    function sweepETH(address to, uint256 amount) external onlyMarketOrchestrator {
        require(to != address(0), "bad to");
        (bool s, ) = to.call{ value: amount }("");
        require(s, "sweep eth");
        emit SweepETH(to, amount);
    }

    // ============ Simple API (internals handle pipeline + hardening) ============

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
        require(recipient != address(0), "bad recipient");
        if (amountIn == 0) revert InvalidAmount();

        // Accept ETH overpay; settle exact; refund delta at end
        uint256 expectedMin = (inputToken == ETH_ADDR) ? amountIn : 0;
        require(msg.value >= expectedMin, "insufficient msg.value");

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

            emit PtToPt(msg.sender, inputToken, outputToken, amountIn, res.amountOut, recipient);
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

    // ============ Internal I/O and helpers ============

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
            require(IERC20(t).transfer(address(poolManager), amount), "erc20->pm");
            poolManager.settle();
        }
    }

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
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom");
        }
    }

    // Auto-refund ETH with WETH fallback (UR-like)
    function _refundEthToSender(uint256 ethBase) internal {
        uint256 refund = address(this).balance - ethBase;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{ value: refund }("");
            if (!ok) {
                IWETH(WETH).deposit{ value: refund }();
                require(IWETH(WETH).transfer(msg.sender, refund), "weth refund");
            }
        }
    }

    // Auto-refund any ERC20 input delta to sender
    function _refundErc20ToSender(address token, uint256 base) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > base) {
            uint256 delta = bal - base;
            require(IERC20(token).transfer(msg.sender, delta), "erc20 refund");
        }
    }

    // ============ PoolKey builders / fees / views ============

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