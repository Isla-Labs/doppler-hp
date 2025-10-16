// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";

/**
 * @title Treasury Manager
 * @notice Treasury management for HP hooks
 */
contract TreasuryManager is Ownable2Step {
    
    /// @notice Treasury receiving platform share of fees
    address public platformTreasury;
    
    /// @notice Treasury receiving rewards share of fees
    address public rewardsTreasury;

    /// @notice Rewards treasury allocation percentage (e.g. 8900 = 89.00%)
    uint256 public rewardsTreasuryBps;

    /// @notice Platform treasury allocation percentage (10000 - rewardsTreasuryBps, e.g. 10000 - 8900 = 11.00%)
    uint256 public platformTreasuryBps;

    event TreasuryUpdated(address indexed newPlatformTreasury, address indexed newRewardsTreasury);
    event SplitBpsUpdated(uint256 rewardsBps, uint256 platformBps);
    
    error ZeroAddress();
    error InvalidBps();

    constructor(
        address _initialOwner,
        address _platformTreasury,
        address _rewardsTreasury
    ) Ownable(_initialOwner) {
        if (_platformTreasury == address(0) || _rewardsTreasury == address(0)) revert ZeroAddress();
        
        platformTreasury = _platformTreasury;
        rewardsTreasury = _rewardsTreasury;
        rewardsTreasuryBps = 8900; // default 89% rewards / 11% platform
        platformTreasuryBps = 10000 - rewardsTreasuryBps;
        
        emit TreasuryUpdated(_platformTreasury, _rewardsTreasury);
        emit SplitBpsUpdated(rewardsTreasuryBps, platformTreasuryBps);
    }
    
    /// @notice Update treasury addresses (only owner)
    function updateTreasuries(
        address _newPlatformTreasury,
        address _newRewardsTreasury
    ) external onlyOwner {
        if (_newPlatformTreasury == address(0) || _newRewardsTreasury == address(0)) revert ZeroAddress();
        
        platformTreasury = _newPlatformTreasury;
        rewardsTreasury = _newRewardsTreasury;
        
        emit TreasuryUpdated(_newPlatformTreasury, _newRewardsTreasury);
    }

    /// @notice Update split bps (only owner). Must be between 1 and 9999.
    function updateSplitBps(uint256 _rewardsBps) external onlyOwner {
        if (_rewardsBps == 0 || _rewardsBps >= 10000) revert InvalidBps();
        rewardsTreasuryBps = _rewardsBps;
        platformTreasuryBps = 10000 - _rewardsBps;
        emit SplitBpsUpdated(_rewardsBps, 10000 - _rewardsBps);
    }
    
    /// @notice Get current treasury addresses
    function getTreasuries() external view returns (address platform, address rewards) {
        return (platformTreasury, rewardsTreasury);
    }

    /// @notice Get current split basis points
    function getSplitBps() external view returns (uint256 rewardsBps, uint256 platformBps) {
        rewardsBps = rewardsTreasuryBps;
        platformBps = platformTreasuryBps;
    }
}