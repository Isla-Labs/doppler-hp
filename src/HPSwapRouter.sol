// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Core
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";

// Minimal Registry view
interface IWhitelistRegistry {
    function tokenSets(address token) external view returns (
        address tokenAddr,
        address vault,
        address dopplerHook,
        address migratorHook,
        bool hasMigrated,
        bool isActive,
        uint256 deactivatedAt,
        bool sunsetComplete
    );
    function getVaultAndStatus(address token) external view returns (address vault, bool isActive);
    function hasAdminAccess(address account) external view returns (bool);
}

// Minimal ERC20
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}

// Permit2 (minimal)
interface IPermit2 {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

// Doppler hook interface to fetch PoolKey
interface IDopplerHook {
    function poolKey() external view returns (PoolKey memory);
}

// Multi-hop context (must match hook’s layout)
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}

// Errors
error NotWhitelisted();
error InvalidAmount();
error Slippage();
error Expired;

// Enhanced HP router
contract HPSwapRouter2 {
    IPoolManager public immutable poolManager;
    IWhitelistRegistry public immutable registry;

    // ETH native sentinel
    address public constant ETH_ADDR = address(0);

    // Canonical Permit2
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Network tokens
    address public immutable USDC;

    // Migrated PT pool params
    uint24 public constant migratorFee = 1000;
    int24 public constant migratorTickSpacing = 10;

    // ETH/USDC pool params (updateable)
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

    modifier checkDeadline(uint256 deadline) {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _registry,
        address _usdc,
        uint24 _ethUsdcFee,
        int24 _ethUsdcTickSpacing
    ) {
        if (address(_poolManager) == address(0)) revert();
        if (address(_registry) == address(0)) revert();
        if (_usdc == address(0)) revert();
        poolManager = _poolManager;
        registry = _registry;
        USDC = _usdc;
        ethUsdcFee = _ethUsdcFee;
        ethUsdcTickSpacing = _ethUsdcTickSpacing;
    }

    // ============ Admin ============

    function setEthUsdcParams(uint24 fee, int24 tickSpacing) external {
        require(registry.hasAdminAccess(msg.sender), "Not admin");
        ethUsdcFee = fee;
        ethUsdcTickSpacing = tickSpacing;
    }

    // ============ Single entry swap ============

    // Detects: PT<->PT (via ETH), ETH<->PT, USDC<->PT (via ETH)
    // Pass minOut=0 or deadline=0 to disable either check.
    function swap(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) {
        if (amountIn == 0) revert InvalidAmount();

        bool inIsPT = _isPlayerToken(inputToken);
        bool outIsPT = _isPlayerToken(outputToken);
        bool inIsETH = (inputToken == ETH_ADDR);
        bool outIsETH = (outputToken == ETH_ADDR);
        bool inIsUSDC = (inputToken == USDC);
        bool outIsUSDC = (outputToken == USDC);

        if (!inIsETH) {
            _pullFromUser(inputToken, amountIn);
        }

        uint256 outAmount;
        if (inIsPT && outIsPT) {
            outAmount = _routePtToPt(inputToken, outputToken, amountIn, recipient);
            emit PtToPt(msg.sender, inputToken, outputToken, amountIn, outAmount, recipient);
        } else if (inIsPT && outIsETH) {
            outAmount = _routePtToEth(inputToken, amountIn, recipient);
        } else if (outIsPT && inIsETH) {
            outAmount = _routeEthToPt(outputToken, amountIn, recipient);
        } else if (inIsPT && outIsUSDC) {
            outAmount = _routePtToUsdc(inputToken, amountIn, recipient);
        } else if (outIsPT && inIsUSDC) {
            outAmount = _routeUsdcToPt(outputToken, amountIn, recipient);
        } else {
            revert NotWhitelisted();
        }

        if (minOut != 0 && outAmount < minOut) revert Slippage();
    }

    // ============ Routing helpers ============

    // PT -> PT (two hops via ETH); first hop marks multi-hop and not USDC for fee skip
    function _routePtToPt(address ptIn, address ptOut, uint256 amountIn, address recipient) internal returns (uint256 outAmt) {
        (PoolKey memory key1, ) = _playerPoolKey(ptIn);
        (PoolKey memory key2, ) = _playerPoolKey(ptOut);

        _settleExactIn(Currency.wrap(ptIn), amountIn);

        bytes memory hop1 = abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: false }));
        _swapExactIn(key1, /*zeroForOne*/ false, amountIn, hop1);

        uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
        if (ethInterim > 0) {
            _swapExactIn(key2, /*zeroForOne*/ true, ethInterim, bytes(""));
        }

        outAmt = _managerOwed(Currency.wrap(ptOut));
        if (outAmt != 0) {
            poolManager.take(Currency.wrap(ptOut), recipient, outAmt);
        }
    }

    // PT -> ETH (single hop)
    function _routePtToEth(address ptIn, uint256 amountIn, address recipient) internal returns (uint256 outAmt) {
        (PoolKey memory key, ) = _playerPoolKey(ptIn);
        _settleExactIn(Currency.wrap(ptIn), amountIn);
        _swapExactIn(key, /*zeroForOne*/ false, amountIn, bytes(""));
        outAmt = _managerOwed(Currency.wrap(ETH_ADDR));
        if (outAmt != 0) {
            poolManager.take(Currency.wrap(ETH_ADDR), recipient, outAmt);
        }
    }

    // ETH -> PT (single hop)
    function _routeEthToPt(address ptOut, uint256 amountIn, address recipient) internal returns (uint256 outAmt) {
        (PoolKey memory key, ) = _playerPoolKey(ptOut);
        _settleExactIn(Currency.wrap(ETH_ADDR), amountIn);
        _swapExactIn(key, /*zeroForOne*/ true, amountIn, bytes(""));
        outAmt = _managerOwed(Currency.wrap(ptOut));
        if (outAmt != 0) {
            poolManager.take(Currency.wrap(ptOut), recipient, outAmt);
        }
    }

    // PT -> USDC (two hops via ETH); first hop marks isUsdc=true (no skip)
    function _routePtToUsdc(address ptIn, uint256 amountIn, address recipient) internal returns (uint256 outAmt) {
        (PoolKey memory key1, ) = _playerPoolKey(ptIn);
        PoolKey memory key2 = _ethUsdcKey();

        _settleExactIn(Currency.wrap(ptIn), amountIn);

        bytes memory hop1 = abi.encode(MultiHopContext({ isMultiHop: true, isUsdc: true }));
        _swapExactIn(key1, /*zeroForOne*/ false, amountIn, hop1);

        uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
        if (ethInterim > 0) {
            _swapExactIn(key2, /*zeroForOne*/ true, ethInterim, bytes(""));
        }

        outAmt = _managerOwed(Currency.wrap(USDC));
        if (outAmt != 0) {
            poolManager.take(Currency.wrap(USDC), recipient, outAmt);
        }
    }

    // USDC -> PT (two hops via ETH)
    function _routeUsdcToPt(address ptOut, uint256 amountIn, address recipient) internal returns (uint256 outAmt) {
        PoolKey memory key1 = _ethUsdcKey();
        (PoolKey memory key2, ) = _playerPoolKey(ptOut);

        _settleExactIn(Currency.wrap(USDC), amountIn);

        _swapExactIn(key1, /*zeroForOne*/ false, amountIn, bytes(""));

        uint256 ethInterim = _managerOwed(Currency.wrap(ETH_ADDR));
        if (ethInterim > 0) {
            _swapExactIn(key2, /*zeroForOne*/ true, ethInterim, bytes(""));
        }

        outAmt = _managerOwed(Currency.wrap(ptOut));
        if (outAmt != 0) {
            poolManager.take(Currency.wrap(ptOut), recipient, outAmt);
        }
    }

    // ============ Internal V4 I/O ============

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

    // Prepay input into PoolManager (credits this router)
    function _settleExactIn(Currency cIn, uint256 amount) internal {
        address t = Currency.unwrap(cIn);
        if (t == ETH_ADDR) {
            require(msg.value >= amount, "insufficient ETH");
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

    // Opportunistically pull from user via Permit2 (if allowance exists) else ERC20.transferFrom
    function _pullFromUser(address token, uint256 amount) internal {
        (uint160 p2Amt, uint48 p2Exp, ) = IPermit2(PERMIT2).allowance(msg.sender, token, address(this));
        bool ok = p2Amt >= uint160(amount) && (p2Exp == 0 || p2Exp >= block.timestamp);
        if (ok) {
            IPermit2(PERMIT2).transferFrom(msg.sender, address(this), uint160(amount), token);
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom");
        }
    }

    // ============ PoolKey builders ============

    function _playerPoolKey(address pt) internal view returns (PoolKey memory key, bool hasMigrated) {
        (
            , /*tokenAddr*/,
            , /*vault*/,
            address dopplerHook,
            address migratorHook,
            bool migrated,
            bool isActive,
            , /*deactivatedAt*/
            /*sunsetComplete*/
        ) = registry.tokenSets(pt);
        if (!isActive) revert NotWhitelisted();
        hasMigrated = migrated;

        if (!hasMigrated) {
            // Use Doppler hook’s poolKey (authoritative fee/tickSpacing)
            key = IDopplerHook(dopplerHook).poolKey();
        } else {
            // Use migrator hook with configured fee/tickSpacing
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

    // ============ Views / helpers ============

    function _isPlayerToken(address token) internal view returns (bool) {
        (, bool isActive) = registry.getVaultAndStatus(token);
        return isActive;
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