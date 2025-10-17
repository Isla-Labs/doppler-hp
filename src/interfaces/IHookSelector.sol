// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

// Doppler hook interface to fetch PoolKey
interface IDopplerHook {
    function poolKey() external view returns (PoolKey memory);
}

// Migrator hook (for price + dynamic fee)
interface IMigratorHook {
    function simulateDynamicFee(uint256 volumeEth)
        external
        view
        returns (uint256 feeBps, uint256 ethPriceUsd);
    function quoteEthPriceUsd() external view returns (uint256);
}