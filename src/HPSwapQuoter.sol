// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IDopplerHook, IMigratorHook } from "src/interfaces/IHookSelector.sol";
import { IV4Quoter, IPositionManager } from "src/interfaces/IUtilities.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";
import { SwapContext } from "src/stores/SwapContext.sol";

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
contract HPSwapQuoter is Initializable {
    
    IPoolManager public poolManager;
    address public positionManager;
    IWhitelistRegistry public registry;
    IV4Quoter public quoter;
    address public orchestratorProxy;

    // ------------------------------------------
    //  Pool Detection Config
    // ------------------------------------------

    /// @notice Pairs
    address public ETH;
    address public WETH;
    address public USDC;

    /// @notice Migrated playerToken pool params
    uint24 public constant migratorFee = 1000;
    int24 public constant migratorTickSpacing = 10;

    /// @notice Updateable ETH/USDC pool params
    bytes32 public ethUsdcPoolId;
    address public ethUsdcBase;
    uint24 public ethUsdcFee;
    int24 public ethUsdcTickSpacing;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event EthUsdcPoolUpdated(bytes32 oldPoolId, bytes32 newPoolId);

    error NotWhitelisted();
    error ZeroAddress();
    error BadEthUsdcBinding(bytes32 poolId, address currency0, address currency1, address hook);
    error Unauthorized();
    error EthUsdcPoolUnavailable();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != orchestratorProxy) revert Unauthorized();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IPoolManager _poolManager,
        IWhitelistRegistry _registry,
        IV4Quoter _quoter,
        address _orchestratorProxy,
        address _positionManager,
        bytes32 _ethUsdcPoolId
    ) external initializer {
        if (
            address(_poolManager) == address(0) || 
            address(_registry) == address(0) || 
            address(_quoter) == address(0) || 
            _orchestratorProxy == address(0) || 
            _positionManager == address(0)
        ) revert ZeroAddress();

        _init(_poolManager, _registry, _quoter, _orchestratorProxy, _positionManager, _ethUsdcPoolId);
    }

    function _init(
        IPoolManager _poolManager,
        IWhitelistRegistry _registry,
        IV4Quoter _quoter,
        address _orchestratorProxy,
        address _positionManager,
        bytes32 _ethUsdcPoolId
    ) private {
        poolManager = _poolManager;
        registry = _registry;
        quoter = _quoter;
        orchestratorProxy = _orchestratorProxy;
        positionManager = _positionManager;

        ETH = address(0);
        WETH = 0x4200000000000000000000000000000000000006;

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

    // ------------------------------------------
    //  Upkeep
    // ------------------------------------------

    /// @notice Enables updateable eth/usdc pool parameters
    function rebindEthUsdc(bytes32 newPoolId) external onlyOrchestrator {
        if (newPoolId == bytes32(0)) revert EthUsdcPoolUnavailable();
        if (newPoolId == ethUsdcPoolId) return;

        // Retrieve poolKey from poolId
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) =
            IPositionManager(positionManager).poolKeys(newPoolId);

        address c0a = Currency.unwrap(c0);
        address c1a = Currency.unwrap(c1);
        if (!(c1a == USDC && address(h) == address(0) && (c0a == ETH || c0a == WETH))) {
            revert BadEthUsdcBinding(newPoolId, c0a, c1a, address(h));
        }

        bytes32 oldId = ethUsdcPoolId;

        ethUsdcBase = c0a;
        ethUsdcFee = fee;
        ethUsdcTickSpacing = spacing;
        ethUsdcPoolId = newPoolId;

        emit EthUsdcPoolUpdated(oldId, newPoolId);
    }

    // ------------------------------------------
    //  Entry Point
    // ------------------------------------------

    /**
     * @notice Quote entry point for inputAmount -> outputAmount simulation
     * @dev (ETH <> playerToken), (USDC <> playerToken), (playerToken <> playerToken)
     * @param inputToken Address of the whitelisted token to swap from
     * @param outputToken Address of the whitelisted token to swap to
     * @param amountIn Total amount to swap in wei
     * @return QuoteResult Successful quote returns amountOut, totalGas, totalFeesEth
     */
    function quote(
        address inputToken,
        address outputToken,
        uint256 amountIn
    ) external returns (QuoteResult memory qr) {
        if (amountIn == 0) return qr;

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

        if (inputToken == outputToken) {
            qr.amountOut = amountIn;
            return qr;
        }

        // PT -> PT (two hops via ETH)
        if (inIsPT && outIsPT) {
            // First hop: PT(in) -> ETH (mark swapctx, skipFee=true)
            (PoolKey memory key1, bool migratedIn, address dopplerIn, address migratorIn) = _playerKeyAndHooks(inputToken);
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*skipFee=*/ true);

            // Fee: if migratedIn -> first-hop fee is skipped (hpQuoter gated); else Doppler 3% on ETH output
            if (!migratedIn) {
                qr.totalFeesEth += _feeOnEthOutput(ethOut, 300); // 3% = 300 bps
            }

            // Second hop: ETH -> PT(out) (single hop)
            (PoolKey memory key2, bool migratedOut, address dopplerOut, address migratorOut) = _playerKeyAndHooks(outputToken);
            (uint256 ptOut, uint256 gas2) =
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*skipFee=*/ false);
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
        if (inIsPT && outIsETHish) {
            (PoolKey memory key, bool migratedIn, address dopplerIn, address migratorIn) = _playerKeyAndHooks(inputToken);
            (uint256 ethOut, uint256 gas1) =
                _quoteSingle(key, /*zeroForOne*/ false, amountIn, /*skipFee=*/ false);
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
        if (outIsPT && inIsETHish) {
            (PoolKey memory key, bool migratedOut, address dopplerOut, address migratorOut) = _playerKeyAndHooks(outputToken);
            (uint256 ptOut, uint256 gas1) =
                _quoteSingle(key, /*zeroForOne*/ true, amountIn, /*skipFee=*/ false);
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
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*skipFee=*/ false);
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
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*skipFee=*/ false);
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
                _quoteSingle(key1, /*zeroForOne*/ false, amountIn, /*skipFee=*/ false);
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
                _quoteSingle(key2, /*zeroForOne*/ true, ethOut, /*skipFee=*/ false);
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

    /// @notice Internal helper to check playerToken activity status
    function _isPlayerToken(address token) internal view returns (bool) {
        return registry.isMarketActive(token);
    }

    /// @notice Calls V4Quoter for swap quote
    function _quoteSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 exactIn,
        bool skipFee
    ) internal returns (uint256 amountOut, uint256 gasEstimate) {
        bytes memory hookData = skipFee ? abi.encode(SwapContext({ skipFee: true })) : bytes("");
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