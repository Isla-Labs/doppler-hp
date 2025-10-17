// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IFeeRouter {
    function forwardBondingFee(address market) external payable;
}