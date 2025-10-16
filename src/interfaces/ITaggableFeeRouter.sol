// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ITaggableFeeRouter {
    function tagETHDeposit(address market, uint256 amount, bytes32 tag) external;
    function tagTokenDeposit(address token, address market, uint256 amount, bytes32 tag) external;
}