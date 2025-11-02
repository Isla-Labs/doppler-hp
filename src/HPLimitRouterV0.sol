// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title HP Limit Router
 * @notice Placeholder implementation for TransparentUpgradeableProxy
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract HPLimitRouter is Initializable, ReentrancyGuard {
    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer { }
}