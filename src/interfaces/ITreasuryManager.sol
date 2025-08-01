// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";

interface ITreasuryManager {
    function distributeFees(
        IPoolManager poolManager,
        address trader,
        Currency currency,
        uint256 amount
    ) external;
}