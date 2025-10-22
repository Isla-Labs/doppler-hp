// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract InitGuard {
    fallback() external payable { revert("UNINITIALIZED"); }
    receive() external payable { revert("UNINITIALIZED"); }
}