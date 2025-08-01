// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IWhitelistRegistry {
    function isTransferAllowed(address account) external view returns (bool);
    function hasAdminAccess(address account) external view returns (bool);
}