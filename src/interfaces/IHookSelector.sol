// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { OrderIdLibrary } from "src/extensions/LimitOrderHook.sol";

// Doppler hook interface to fetch PoolKey
interface IDopplerHook {
    function poolKey() external view returns (PoolKey memory);
}

// Migrator hook (for price + dynamic fee)
interface IMigratorHook {
    // Limit orders
    function placeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) external;
    function placeOrderEth(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) external payable;
    function cancelOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to) external;
    function withdraw(OrderIdLibrary.OrderId orderId, address to) external returns (uint256 amount0, uint256 amount1);

    // Views
    function quoteEthPriceUsd() external view returns (uint256);
    function simulateDynamicFee(uint256 volumeEth)
        external
        view
        returns (uint256 feeBps, uint256 ethPriceUsd);
}