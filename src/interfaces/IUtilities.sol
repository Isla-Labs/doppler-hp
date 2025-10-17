// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

// Context for multi-hop swap coordination (disables double fee collection)
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}

// Minimal ERC20
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}

// Minimal Permit2
interface IPermit2 {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

// Minimal V4 Quoter
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}