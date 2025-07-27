// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { BalanceDeltaLibrary, add } from "@v4-core/types/BalanceDelta.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

/// @notice Position data used by Doppler
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint8 salt;
}

/// @title Doppler Helper Library
library DopplerHelper {
    using SafeCastLib for uint128;
    using BalanceDeltaLibrary for BalanceDelta;

    function computeTargetPriceX96(uint256 num, uint256 denom) external pure returns (uint160) {
        uint256 targetPriceX96 = FullMath.mulDiv(num, FixedPoint96.Q96, denom);
        if (targetPriceX96 > type(uint160).max) {
            return 0;
        }
        return uint160(targetPriceX96);
    }

    function computeLiquidity(
        bool forToken0,
        uint160 lowerPrice,
        uint160 upperPrice,
        uint256 amount
    ) external pure returns (uint128) {
        amount = amount != 0 ? amount - 1 : amount;
        return forToken0
            ? LiquidityAmounts.getLiquidityForAmount0(lowerPrice, upperPrice, amount)
            : LiquidityAmounts.getLiquidityForAmount1(lowerPrice, upperPrice, amount);
    }

    function update(
        IPoolManager poolManager,
        bool isToken0,
        Position[] memory newPositions,
        uint160 currentPrice,
        uint160 swapPrice,
        PoolKey memory key
    ) external {
        if (swapPrice != currentPrice) {
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: swapPrice < currentPrice,
                    amountSpecified: 1,
                    sqrtPriceLimitX96: swapPrice
                }),
                ""
            );
        }

        for (uint256 i; i < newPositions.length; ++i) {
            if (newPositions[i].liquidity != 0) {
                poolManager.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: isToken0 ? newPositions[i].tickLower : newPositions[i].tickUpper,
                        tickUpper: isToken0 ? newPositions[i].tickUpper : newPositions[i].tickLower,
                        liquidityDelta: newPositions[i].liquidity.toInt128(),
                        salt: bytes32(uint256(newPositions[i].salt))
                    }),
                    ""
                );
            }
        }

        int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
        int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);

        if (currency0Delta > 0) {
            poolManager.take(key.currency0, address(this), uint256(currency0Delta));
        }

        if (currency1Delta > 0) {
            poolManager.take(key.currency1, address(this), uint256(currency1Delta));
        }

        if (currency0Delta < 0) {
            poolManager.sync(key.currency0);
            if (Currency.unwrap(key.currency0) != address(0)) {
                key.currency0.transfer(address(poolManager), uint256(-currency0Delta));
            }
            poolManager.settle{ value: Currency.unwrap(key.currency0) == address(0) ? uint256(-currency0Delta) : 0 }();
        }

        if (currency1Delta < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(-currency1Delta));
            poolManager.settle();
        }
    }
}

