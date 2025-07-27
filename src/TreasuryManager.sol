// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";

/**
 * @title HighPotential Treasury Manager
 * @notice Centralized treasury management for all HP hook contracts
 * @dev Single source of truth for fee distribution across all hooks
 */
contract TreasuryManager is Ownable2Step {
    
    // ==========================================
    // STATE VARIABLES
    // ==========================================
    
    /// @notice Treasury receiving 11% of dynamic fee output
    address public platformTreasury;
    
    /// @notice Treasury receiving 89% of dynamic fee output
    address public rewardsTreasury;
    
    // ==========================================
    // CONSTANTS
    // ==========================================
    
    /// @notice Rewards treasury allocation percentage (89% = 8900 basis points)
    uint256 public constant REWARDS_TREASURY_BPS = 8900;
    
    /// @notice Platform treasury allocation percentage (11% = 1100 basis points)
    uint256 public constant PLATFORM_TREASURY_BPS = 1100;
    
    // ==========================================
    // EVENTS
    // ==========================================
    
    event TreasuryUpdated(address indexed newPlatformTreasury, address indexed newRewardsTreasury);
    event FeesDistributed(
        address indexed hook,
        address indexed trader,
        bool indexed isBuy,
        Currency currency,
        uint256 totalAmount,
        uint256 rewardsAmount,
        uint256 platformAmount
    );
    
    // ==========================================
    // ERRORS
    // ==========================================
    
    error ZeroAddress();
    
    // ==========================================
    // CONSTRUCTOR
    // ==========================================
    
    constructor(
        address _initialOwner,
        address _platformTreasury,
        address _rewardsTreasury
    ) Ownable(_initialOwner) {
        require(_platformTreasury != address(0) && _rewardsTreasury != address(0), ZeroAddress());
        
        platformTreasury = _platformTreasury;
        rewardsTreasury = _rewardsTreasury;
        
        emit TreasuryUpdated(_platformTreasury, _rewardsTreasury);
    }
    
    // ==========================================
    // ADMIN FUNCTIONS
    // ==========================================
    
    /// @notice Update treasury addresses (only owner)
    function updateTreasuries(
        address _newPlatformTreasury,
        address _newRewardsTreasury
    ) external onlyOwner {
        require(_newPlatformTreasury != address(0) && _newRewardsTreasury != address(0), ZeroAddress());
        
        platformTreasury = _newPlatformTreasury;
        rewardsTreasury = _newRewardsTreasury;
        
        emit TreasuryUpdated(_newPlatformTreasury, _newRewardsTreasury);
    }
    
    // ==========================================
    // CORE FUNCTIONS
    // ==========================================
    
    /// @notice Distribute fees between treasuries
    /// @param poolManager The Uniswap V4 pool manager
    /// @param currency The currency to distribute
    /// @param totalAmount Total fee amount to distribute
    /// @param trader Address of the trader (for events)
    /// @param isBuy Whether this was a buy transaction (for events)
    function distributeFees(
        IPoolManager poolManager,
        Currency currency,
        uint256 totalAmount,
        address trader,
        bool isBuy
    ) external {
        // Calculate splits
        uint256 rewardsAmount = (totalAmount * REWARDS_TREASURY_BPS) / 10000;
        uint256 platformAmount = totalAmount - rewardsAmount;
        
        // Distribute fees via pool manager
        poolManager.take(currency, rewardsTreasury, rewardsAmount);
        poolManager.take(currency, platformTreasury, platformAmount);
        
        emit FeesDistributed(
            msg.sender, // The calling hook contract
            trader,
            isBuy,
            currency,
            totalAmount,
            rewardsAmount,
            platformAmount
        );
    }
    
    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================
    
    /// @notice Get current treasury addresses
    function getTreasuries() external view returns (address platform, address rewards) {
        return (platformTreasury, rewardsTreasury);
    }
}