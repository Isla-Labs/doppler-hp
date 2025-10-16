// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ITreasuryManager {
    function getTreasuries() external view returns (address platform, address rewards);
    function getSplitBps() external view returns (uint256 rewardsBps, uint256 platformBps);
}