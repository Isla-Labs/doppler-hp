// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Core
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IDopplerHook, IMigratorHook } from "src/interfaces/IHookSelector.sol";
import { IV4Quoter, MultiHopContext, IPositionManager } from "src/interfaces/IUtilities.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

/// @notice return schema for successful quote
struct QuoteResult {
    uint256 amountOut;     // final output for the full route, including fee deductions
    uint256 gasEstimate;   // sum of gas estimates from the quoter for the hops
    uint256 totalFeesEth;  // all fees, ETH-denominated (wei)
}

/**
 * @title HP Swap Quoter
 * @dev Automatic pool detection and fee reduction for multihops
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract HPSwapQuoter {
    
    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    IWhitelistRegistry public immutable registry;
    IV4Quoter public immutable quoter;
    address public immutable marketOrchestrator;

    // ------------------------------------------
    //  Pool Detection Config
    // ------------------------------------------

    // Tokens and params
    address public immutable USDC;
    address public constant ETH_ADDR = address(0);

    // Migrated playerToken pool params
    uint24 public constant migratorFee = 1000;
    int24 public constant migratorTickSpacing = 10;

    // Updateable ETH/USDC pool params
    bytes32 public ethUsdcPoolId;
    uint24 public ethUsdcFee;
    int24 public ethUsdcTickSpacing;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    error NotWhitelisted();
    error BadEthUsdcBinding(bytes32 poolId, address currency0, address currency1, address hook);
    error Unauthorized();
    error EthUsdcPoolUnavailable();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

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
        IV4Quoter _quoter,
        address _marketOrchestrator,
        address _usdc,
        address positionManager_,
        bytes32 ethUsdcPoolId_
    ) {
        require(address(_poolManager) != address(0) && address(_registry) != address(0), "bad core");
        require(address(_quoter) != address(0), "bad quoter");
        require(address(_marketOrchestrator) != address(0), "bad orchestrator");
        require(_usdc != address(0) && positionManager_ != address(0), "bad addr");

        poolManager = _poolManager;
        registry = _registry;
        quoter = _quoter;
        marketOrchestrator = _marketOrchestrator;
        positionManager = positionManager_;
        USDC = _usdc;

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
        // Retrieve poolKey from poolId
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(newPoolId);

        address c0a = Currency.unwrap(c0);
        address c1a = Currency.unwrap(c1);
        if (!(c0a == ETH_ADDR && c1a == USDC && address(h) == address(0))) {
            revert BadEthUsdcBinding(newPoolId, c0a, c1a, address(h));
        }

        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = newPoolId;
    }

    // ------------------------------------------
    //  Entry Point
    // ------------------------------------------

    function quote(
        address inputToken,
        address outputToken,
        uint256 amountIn
    ) external returns (QuoteResult memory qr) {
        if (amountIn == 0) return qr;

        bool inIsPT = _isPlayerToken(inputToken);
        bool outIsPT = _isPlayerToken(outputToken);
        bool inIsETH = (inputToken == ETH_ADDR);
        bool outIsETH = (outputToken == ETH_ADDR);
        bool inIsUSDC = (inputToken == USDC);
        bool outIsUSDC = (outputToken == USDC);

        if (inputToken == outputToken) {
            qr.amountOut = amountIn;
            return qr;
        }

        // PT -> PT (two hops via ETH)
        if (inIsPT && outIsPT) {
            // First hop: PT(in) -> ETH (mark multihop, isUsdc=false)
            (PoolKey memory key1, bool migratedIn, address dopplerIn, address migratorIn) = _playerKeyAndHooks(inputToken);
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*isMultiHopFirst=*/ true, /*isUsdc=*/ false);
            // Fee: if migratedIn -> first-hop fee is skipped (hpQuoter gated); else Doppler 3% on ETH output
            if (!migratedIn) {
                qr.totalFeesEth += _feeOnEthOutput(ethOut, 300); // 3% = 300 bps
            }

            // Second hop: ETH -> PT(out) (single hop)
            (PoolKey memory key2, bool migratedOut, address dopplerOut, address migratorOut) = _playerKeyAndHooks(outputToken);
            (uint256 ptOut, uint256 gas2) =
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            qr.amountOut = ptOut;
            qr.gasEstimate = gas1 + gas2;

            // Fee on second hop (ETH input)
            if (migratedOut) {
                uint256 bps = _migratorFeeBps(migratorOut, ethOut);
                qr.totalFeesEth += _feeOnEthInput(ethOut, bps);
            } else {
                qr.totalFeesEth += _feeOnEthInput(ethOut, 300);
            }
            return qr;
        }

        // PT -> ETH (single hop) [ETH output]
        if (inIsPT && outIsETH) {
            (PoolKey memory key, bool migratedIn, address dopplerIn, address migratorIn) = _playerKeyAndHooks(inputToken);
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key, /*zeroForOne*/ false, amountIn, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            qr.amountOut = ethOut;
            qr.gasEstimate = gas1;

            // Fee on ETH output
            if (migratedIn) {
                uint256 bps = _migratorFeeBps(migratorIn, ethOut);
                qr.totalFeesEth += _feeOnEthOutput(ethOut, bps);
            } else {
                qr.totalFeesEth += _feeOnEthOutput(ethOut, 300);
            }
            return qr;
        }

        // ETH -> PT (single hop) [ETH input]
        if (outIsPT && inIsETH) {
            (PoolKey memory key, bool migratedOut, address dopplerOut, address migratorOut) = _playerKeyAndHooks(outputToken);
            (uint256 ptOut, uint256 gas1) =
                _quoteSingle(key, /*zeroForOne*/ true, amountIn, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            qr.amountOut = ptOut;
            qr.gasEstimate = gas1;

            // Fee on ETH input
            if (migratedOut) {
                uint256 bps = _migratorFeeBps(migratorOut, amountIn);
                qr.totalFeesEth += _feeOnEthInput(amountIn, bps);
            } else {
                qr.totalFeesEth += _feeOnEthInput(amountIn, 300);
            }
            return qr;
        }

        // PT -> USDC (two hops via ETH)
        if (inIsPT && outIsUSDC) {
            // First hop: PT(in) -> ETH (mark multihop, isUsdc=true) [ETH output]
            if (ethUsdcPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();
            (PoolKey memory key1, bool migratedIn, address dopplerIn, address migratorIn) = _playerKeyAndHooks(inputToken);
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*isMultiHopFirst=*/ true, /*isUsdc=*/ true);
            // Fee on ETH output (no skip because isUsdc=true)
            if (migratedIn) {
                uint256 bps1 = _migratorFeeBps(migratorIn, ethOut);
                qr.totalFeesEth += _feeOnEthOutput(ethOut, bps1);
            } else {
                qr.totalFeesEth += _feeOnEthOutput(ethOut, 300);
            }

            // Second hop: ETH -> USDC (single hop) [ETH input → Uniswap fee]
            PoolKey memory key2 = _ethUsdcKey();
            (uint256 usdcOut, uint256 gas2) =
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            qr.amountOut = usdcOut;
            qr.gasEstimate = gas1 + gas2;

            // Uniswap v4 fee on ETH input
            qr.totalFeesEth += _feeOnEthInput(ethOut, _v4FeeBps(ethUsdcFee));
            return qr;
        }

        // USDC -> PT (two hops via ETH)
        if (outIsPT && inIsUSDC) {
            // First hop: USDC -> ETH (single hop) [USDC input → Uniswap fee]
            if (ethUsdcPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();
            PoolKey memory key1 = _ethUsdcKey();
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            // Uniswap v4 fee on USDC input → convert to ETH and accumulate
            {
                uint256 usdcFee = _feeOnUsdcInput(amountIn, _v4FeeBps(ethUsdcFee));
                uint256 ethPriceUsd = _ethPriceUsdFromToken(outputToken); // 6 decimals
                if (ethPriceUsd != 0) {
                    uint256 usdcFeeAsEth = (usdcFee * 1e18) / ethPriceUsd; // USDC(6d) -> ETH(wei)
                    qr.totalFeesEth += usdcFeeAsEth;
                }
            }

            // Second hop: ETH -> PT(out) (single hop) [ETH input]
            (PoolKey memory key2, bool migratedOut, address dopplerOut, address migratorOut) = _playerKeyAndHooks(outputToken);
            (uint256 ptOut, uint256 gas2) =
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*isMultiHopFirst=*/ false, /*isUsdc=*/ false);
            qr.amountOut = ptOut;
            qr.gasEstimate = gas1 + gas2;

            // Fee on ETH input
            if (migratedOut) {
                uint256 bps2 = _migratorFeeBps(migratorOut, ethOut);
                qr.totalFeesEth += _feeOnEthInput(ethOut, bps2);
            } else {
                qr.totalFeesEth += _feeOnEthInput(ethOut, 300);
            }
            return qr;
        }

        revert NotWhitelisted();
    }

    // ------------------------------------------
    //  Input/Output
    // ------------------------------------------

    function _quoteSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 exactIn,
        bool isMultiHopFirst,
        bool isUsdc
    ) internal returns (uint256 amountOut, uint256 gasEstimate) {
        bytes memory hookData = isMultiHopFirst
            ? abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: isUsdc }))
            : bytes("");
        (amountOut, gasEstimate) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: exactIn,
                hookData: hookData
            })
        );
    }

    // ------------------------------------------
    //  PoolKey Construction
    // ------------------------------------------

    function _playerKeyAndHooks(address pt)
        internal
        view
        returns (PoolKey memory key, bool hasMigrated, address dopplerHook, address migratorHook)
    {
        if (!registry.isMarketActive(pt)) revert NotWhitelisted();

        hasMigrated = registry.hasMigrated(pt);
        (dopplerHook, migratorHook) = registry.getHooks(pt);

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

    // Uniswap fee on USDC input (reported in USDC, 6 decimals for Base USDC)
    function _feeOnUsdcInput(uint256 usdcIn, uint256 feeBps) internal pure returns (uint256) {
        return (usdcIn * feeBps) / 10_000;
    }

    // ------------------------------------------
    //  Helpers
    // ------------------------------------------

    function _isPlayerToken(address token) internal view returns (bool) {
        return registry.isMarketActive(token);
    }

    function _ethPriceUsdFromToken(address pt) internal view returns (uint256) {
        (, address migratorHook) = registry.getHooks(pt);
        if (migratorHook == address(0)) return 0;
        return IMigratorHook(migratorHook).quoteEthPriceUsd(); // 6 decimals
    }
}