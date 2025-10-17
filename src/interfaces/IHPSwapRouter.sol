// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IHPSwapRouter {
    struct SwapResult {
        uint256 amountOut;
        uint256 totalGas;
        uint256 totalFeesEth;
    }
    function swap(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external payable returns (SwapResult memory);
}