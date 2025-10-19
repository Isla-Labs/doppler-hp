// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Context for multi-hop swap coordination 
/// @dev Disables double fee collection on playerToken <> playerToken swaps
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}