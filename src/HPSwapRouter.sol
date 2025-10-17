// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
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
    using SafeERC20 for IERC20;
    
    // Core dependencies
    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    IWhitelistRegistry public immutable registry;
    address public immutable marketOrchestrator;

    // ------------------------------------------
    //  Pool Detection Config
    // ------------------------------------------

    // Permit2
    address public immutable PERMIT2;

    // Pairs
    address public immutable ETH;
    address public immutable USDC;
    address public immutable WETH;

    // Migrated playerToken pool params
    uint24 public constant migratorFee = 1000;
    int24 public constant migratorTickSpacing = 10;

    // Updateable ETH/USDC pool params (derived from poolId)
    bytes32 public ethUsdcPoolId;
    address public ethUsdcBase;
    uint24 public ethUsdcFee;
    int24 public ethUsdcTickSpacing;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event EthUsdcPoolUpdated(bytes32 oldPoolId, bytes32 newPoolId);
    event SweepToken(address indexed token, address indexed to, uint256 amount);
    event SweepETH(address indexed to, uint256 amount);

    error ZeroAddress();
    error NotWhitelisted();
    error InvalidAmount();
    error InsufficientInput(uint256 expected, uint256 provided);
    error Slippage();
    error TxExpired();
    error BadRecipient();
    error BadEthUsdcBinding(bytes32 poolId, address currency0, address currency1, address hook);
    error EthUsdcPoolUnavailable();
    error Unauthorized();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier checkDeadline(uint256 deadline) {
        if (deadline != 0 && block.timestamp > deadline) revert TxExpired();
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
        address _positionManager,
        bytes32 _ethUsdcPoolId
    ) {
        if (
            address(_poolManager) == address(0) || 
            address(_registry) == address(0) || 
            _marketOrchestrator == address(0) || 
            _positionManager == address(0)
        ) revert ZeroAddress();

        poolManager = _poolManager;
        registry = _registry;
        marketOrchestrator = _marketOrchestrator;
        positionManager = _positionManager;
        
        ETH = address(0);
        WETH = 0x4200000000000000000000000000000000000006;
        PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        if (block.chainid == 8453) {
            USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base mainnet
        } else if (block.chainid == 84532) {
            USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Base Sepolia
        } else {
            revert EthUsdcPoolUnavailable();
        }

        if (_ethUsdcPoolId != bytes32(0)) {
            (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
                IPositionManager(positionManager).poolKeys(_ethUsdcPoolId);

            address c0a = Currency.unwrap(c0);
            address c1a = Currency.unwrap(c1);
            if (!(c1a == USDC && address(h) == address(0) && (c0a == ETH || c0a == WETH))) {
                revert BadEthUsdcBinding(_ethUsdcPoolId, c0a, c1a, address(h));
            }

            ethUsdcBase = c0a;
            ethUsdcFee = fee;
            ethUsdcTickSpacing = spacing;
            ethUsdcPoolId = _ethUsdcPoolId;
        } else {
            ethUsdcBase = address(0);
            ethUsdcFee = 0;
            ethUsdcTickSpacing = 0;
            ethUsdcPoolId = bytes32(0);
        }
    }

    receive() external payable {}

    // ------------------------------------------
    //  Upkeep
    // ------------------------------------------

    /// @notice Enables updateable eth/usdc pool parameters
    function rebindEthUsdc(bytes32 newPoolId) external onlyMarketOrchestrator {
        if (newPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();

        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(newPoolId);

        address c0a = Currency.unwrap(c0);
        address c1a = Currency.unwrap(c1);
        if (!(c1a == USDC && address(h) == address(0) && (c0a == ETH || c0a == WETH))) {
            revert BadEthUsdcBinding(newPoolId, c0a, c1a, address(h));
        }

        bytes32 oldId = ethUsdcPoolId;
        uint24 oldFee = ethUsdcFee;
        int24 oldSpacing = ethUsdcTickSpacing;

        ethUsdcBase = c0a;
        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = newPoolId;

        emit EthUsdcPoolUpdated(oldId, newPoolId);
    }

    /// @notice Emergency-only fallback; router aims to be stateless via auto-refunds
    function sweepToken(address token, address to, uint256 amount) external onlyMarketOrchestrator {
        if (to == address(0)) revert BadRecipient();
        IERC20(token).safeTransfer(to, amount);
        emit SweepToken(token, to, amount);
    }

    /// @notice Emergency-only fallback; router aims to be stateless via auto-refunds
    function sweepETH(address to, uint256 amount) external onlyMarketOrchestrator {
        if (to == address(0)) revert BadRecipient();

        (bool s, ) = to.call{ value: amount }("");
        if (!s) revert();
        emit SweepETH(to, amount);
    }

    // ------------------------------------------
    //  Entry Point (exact input)
    // ------------------------------------------

    /**
     * @notice Swap entry point for exact in single
     * @dev (ETH <> playerToken), (USDC <> playerToken), (playerToken <> playerToken)
     * @param inputToken Address of the whitelisted token to use as currency0
     * @param outputToken Address of the whitelisted token to use as currency1
     * @param amountIn Total amount to swap in wei
     * @param minOut Slippage-adjusted minimum output in wei (minOut=0 disables slippage protection)
     * @param deadline Unix timestamp for execution deadline, e.g. block.timestamp + 600 (deadline=0 disables time bound)
     * @return SwapResult Successful tx returns amountOut, totalGas, totalFeesEth
     */
    function swap(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) external payable checkDeadline(deadline) nonReentrant returns (SwapResult memory res) {
        if (amountIn == 0) revert InvalidAmount();
        address recipient = msg.sender;

        // Accept ETH overpay; settle exact; refund delta at end
        uint256 expectedMin = (inputToken == ETH) ? amountIn : 0;
        if (msg.value < expectedMin) revert InsufficientInput(expectedMin, msg.value);

        // Ephemeral baselines (UR-like statelessness)
        uint256 ethBase = address(this).balance - msg.value;
        uint256 erc20Base = (inputToken == ETH) ? 0 : IERC20(inputToken).balanceOf(address(this));
        uint256 gasStart = gasleft();

        // ---- Pipeline: settle -> swap hops -> take -> (fees tracked) ----

        bool inIsPT = _isPlayerToken(inputToken);
        bool outIsPT = _isPlayerToken(outputToken);
        bool inIsETH = (inputToken == ETH);
        bool outIsETH = (outputToken == ETH);
        bool inIsUSDC = (inputToken == USDC);
        bool outIsUSDC = (outputToken == USDC);

        bool inIsWETH = (inputToken == WETH);
        bool outIsWETH = (outputToken == WETH);
        bool inIsETHish = inIsETH || inIsWETH;
        bool outIsETHish = outIsETH || outIsWETH;

        if (!inIsETH) {
            _pullFromUser(inputToken, amountIn);
        }

        if (inIsPT && outIsPT) {
            // PT(in) -> ETH
            (PoolKey memory keyIn, bool migratedIn) = _playerPoolKey(inputToken);
            _settleExactIn(Currency.wrap(inputToken), amountIn);

            bytes memory hop1 = abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: false }));
            _swapExactIn(keyIn, /*zeroForOne*/ false, amountIn, hop1);

            uint256 ethInterim = _managerOwed(Currency.wrap(ETH));
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

        } else if (inIsPT && outIsETHish) {
            (PoolKey memory keyIn, bool migratedIn) = _playerPoolKey(inputToken);

            _settleExactIn(Currency.wrap(inputToken), amountIn);
            _swapExactIn(keyIn, /*zeroForOne*/ false, amountIn, bytes(""));

            res.amountOut = _managerOwed(Currency.wrap(ETH));
            if (res.amountOut != 0) {
                if (outIsWETH) {
                    poolManager.take(Currency.wrap(ETH), address(this), res.amountOut);
                    IWETH(WETH).deposit{ value: res.amountOut }();
                    IERC20(WETH).safeTransfer(recipient, res.amountOut);
                } else {
                    poolManager.take(Currency.wrap(ETH), recipient, res.amountOut);
                }

                // fee: ETH output of the PT(in) pool
                if (migratedIn) {
                    uint256 bps = _migratorFeeBps(address(keyIn.hooks), res.amountOut);
                    res.totalFeesEth += _feeOnEthOutput(res.amountOut, bps);
                } else {
                    res.totalFeesEth += _feeOnEthOutput(res.amountOut, 300);
                }
            }

        } else if (outIsPT && inIsETHish) {
            (PoolKey memory keyOut, bool migratedOut) = _playerPoolKey(outputToken);

            if (inIsWETH) {
                IWETH(WETH).withdraw(amountIn);
            }

            _settleExactIn(Currency.wrap(ETH), amountIn);
            _swapExactIn(keyOut, /*zeroForOne*/ true, amountIn, bytes(""));

            res.amountOut = _managerOwed(Currency.wrap(outputToken));
            if (res.amountOut != 0) poolManager.take(Currency.wrap(outputToken), recipient, res.amountOut);

            // fee: ETH input of the PT(out) pool
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

            uint256 ethInterim = _managerOwed(Currency.wrap(ETH));
            if (migratedIn) {
                uint256 bps1 = _migratorFeeBps(address(keyIn.hooks), ethInterim);
                res.totalFeesEth += _feeOnEthOutput(ethInterim, bps1);
            } else {
                res.totalFeesEth += _feeOnEthOutput(ethInterim, 300);
            }

            if (ethInterim > 0) {
                if (ethUsdcBase == WETH) {
                    // Convert ETH credit -> WETH credit for the mid-hop
                    poolManager.take(Currency.wrap(ETH), address(this), ethInterim);
                    IWETH(WETH).deposit{ value: ethInterim }();
                    poolManager.sync(Currency.wrap(WETH));
                    IERC20(WETH).safeTransfer(address(poolManager), ethInterim);
                    poolManager.settle();
                }
                _swapExactIn(keyMid, /*zeroForOne*/ true, ethInterim, bytes(""));
            }

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

            uint256 ethInterim;
            if (ethUsdcBase == WETH) {
                uint256 wethInterim = _managerOwed(Currency.wrap(WETH));
                if (wethInterim > 0) {
                    // Convert WETH credit -> ETH credit for the final hop
                    poolManager.take(Currency.wrap(WETH), address(this), wethInterim);
                    IWETH(WETH).withdraw(wethInterim);
                    poolManager.settle{ value: wethInterim }();
                }
                ethInterim = wethInterim;
            } else {
                ethInterim = _managerOwed(Currency.wrap(ETH));
            }

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
        if (inputToken != ETH) _refundErc20ToSender(inputToken, erc20Base);

        res.totalGas = gasStart - gasleft();
    }

    // ------------------------------------------
    //  Input/Output
    // ------------------------------------------

    /// @notice Calls PoolManager for swap execution
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

    /// @notice Prepay input into PoolManager
    function _settleExactIn(Currency cIn, uint256 amount) internal {
        address t = Currency.unwrap(cIn);
        if (t == ETH) {
            poolManager.settle{ value: amount }();
        } else {
            poolManager.sync(cIn);
            IERC20(t).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    // ------------------------------------------
    //  Internal helpers
    // ------------------------------------------

    /// @notice Internal helper to check playerToken activity status
    function _isPlayerToken(address token) internal view returns (bool) {
        return registry.isMarketActive(token);
    }

    /// @notice Returns the router's positive credit in PoolManager
    function _managerOwed(Currency c) internal view returns (uint256) {
        int256 delta = poolManager.currencyDelta(address(this), c);
        return delta > 0 ? uint256(delta) : 0;
    }

    /// @notice Prefer Permit2 if allowance exists; fall back to ERC20.transferFrom
    function _pullFromUser(address token, uint256 amount) internal {
        (uint160 p2Amt, uint48 p2Exp, ) = IPermit2(PERMIT2).allowance(msg.sender, token, address(this));
        bool ok = p2Amt >= uint160(amount) && (p2Exp == 0 || p2Exp >= block.timestamp);
        if (ok) {
            IPermit2(PERMIT2).transferFrom(msg.sender, address(this), uint160(amount), token);
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /// @notice Auto-refund ETH with WETH fallback (UR-like)
    function _refundEthToSender(uint256 ethBase) internal {
        uint256 refund = address(this).balance - ethBase;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{ value: refund }("");
            if (!ok) {
                IWETH(WETH).deposit{ value: refund }();
                IERC20(WETH).safeTransfer(msg.sender, refund);
            }
        }
    }

    /// @notice Auto-refund any ERC20 input delta to sender
    function _refundErc20ToSender(address token, uint256 base) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > base) {
            uint256 delta = bal - base;
            IERC20(token).safeTransfer(msg.sender, delta);
        }
    }

    // ------------------------------------------
    //  Fee Helpers
    // ------------------------------------------

    /// @notice Convert Uniswap v4 fee param (hundredths of a bip) to bps
    function _v4FeeBps(uint24 feeParam) internal pure returns (uint256) {
        return uint256(feeParam) / 100;
    }

    /// @notice Fetches dynamic fee bps from migrator hook
    function _migratorFeeBps(address migratorHook, uint256 volumeEth) internal view returns (uint256) {
        if (migratorHook == address(0)) return 0;
        (uint256 feeBps, ) = IMigratorHook(migratorHook).simulateDynamicFee(volumeEth);
        return feeBps;
    }

    /// @notice Calculates fee when charged on ETH input (exact)
    function _feeOnEthInput(uint256 ethIn, uint256 feeBps) internal pure returns (uint256) {
        return (ethIn * feeBps) / 10_000;
    }

    /// @notice Calculates fee when charged on ETH output (net → gross adjustment)
    function _feeOnEthOutput(uint256 ethOutNet, uint256 feeBps) internal pure returns (uint256) {
        uint256 denom = 10_000 - feeBps;
        return denom == 0 ? 0 : (ethOutNet * feeBps) / denom;
    }

    /// @notice Calculates Uniswap v4 fee on USDC input
    function _feeOnUsdcInput(uint256 usdcIn, uint256 feeBps) internal pure returns (uint256) {
        return (usdcIn * feeBps) / 10_000;
    }

    /// @notice Fetches ETH price for approximate value conversion (USDC -> ETH)
    function _ethPriceUsdFromToken(address pt) internal view returns (uint256) {
        (, address migratorHook) = registry.getHooks(pt);
        if (migratorHook == address(0)) return 0;
        return IMigratorHook(migratorHook).quoteEthPriceUsd(); // 6 decimals
    }

    // ------------------------------------------
    //  PoolKey Construction
    // ------------------------------------------

    /// @notice Detect bonding status and automatically construct poolKey for playerToken
    function _playerPoolKey(address pt) internal view returns (PoolKey memory key, bool hasMigrated) {
        if (!registry.isMarketActive(pt)) revert NotWhitelisted();

        hasMigrated = registry.hasMigrated(pt);
        (address dopplerHook, address migratorHook) = registry.getHooks(pt);

        if (!hasMigrated) {
            key = IDopplerHook(dopplerHook).poolKey();
        } else {
            key = PoolKey({
                currency0: Currency.wrap(ETH),
                currency1: Currency.wrap(pt),
                hooks: IHooks(migratorHook),
                fee: migratorFee,
                tickSpacing: migratorTickSpacing
            });
        }
    }

    /// @notice Automatically construct poolKey for ETH/USDC (derived from Uniswap v4 poolId)
    function _ethUsdcKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(ethUsdcBase),
            currency1: Currency.wrap(USDC),
            hooks: IHooks(address(0)),
            fee: ethUsdcFee,
            tickSpacing: ethUsdcTickSpacing
        });
    }
}