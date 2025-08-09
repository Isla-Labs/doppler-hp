// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Currency } from "@v4-core/types/Currency.sol";

/**
 * @title Treasury Manager
 * @notice Treasury management for HP hooks
 * @dev Single source of truth for fee distribution across all hooks
 */
contract TreasuryManager is Ownable2Step {
    
    /// @notice Treasury receiving 11% of dynamic fee output
    address public platformTreasury;
    
    /// @notice Treasury receiving 89% of dynamic fee output
    address public rewardsTreasury;
    
    /// @notice Registered hooks that can distribute fees
    mapping(address => bool) public authorizedHooks;
    
    /// @notice Rewards treasury allocation percentage (89% = 8900 basis points)
    uint256 public constant REWARDS_TREASURY_BPS = 8900;
    
    /// @notice Platform treasury allocation percentage (11% = 1100 basis points)
    uint256 public constant PLATFORM_TREASURY_BPS = 1100;
    
    event TreasuryUpdated(address indexed newPlatformTreasury, address indexed newRewardsTreasury);
    event HookAuthorized(address indexed hook);
    event FeesDistributed(
        address indexed hook,
        address indexed trader,
        Currency currency,
        uint256 totalAmount,
        uint256 rewardsAmount,
        uint256 platformAmount
    );
    
    error ZeroAddress();
    error AlreadyAuthorized();
    error NotAuthorized();
    
    modifier onlyAuthorizedHook() {
        if (!authorizedHooks[msg.sender]) revert NotAuthorized();
        _;
    }
    
    constructor(
        address _initialOwner,
        address _platformTreasury,
        address _rewardsTreasury
    ) Ownable(_initialOwner) {
        if (_platformTreasury == address(0) || _rewardsTreasury == address(0)) revert ZeroAddress();
        
        platformTreasury = _platformTreasury;
        rewardsTreasury = _rewardsTreasury;
        
        emit TreasuryUpdated(_platformTreasury, _rewardsTreasury);
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
    
    /// @notice Add authorized hook (only owner)
    function addAuthorizedHook(address hook) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        if (authorizedHooks[hook]) revert AlreadyAuthorized();
        
        authorizedHooks[hook] = true;
        emit HookAuthorized(hook);
    }
    
    /// @notice Distribute fees between treasuries (only authorized hooks)
    /// @param poolManager The Uniswap V4 pool manager
    /// @param trader Address of the trader (for events)
    /// @param currency The currency to distribute
    /// @param totalAmount Total fee amount to distribute
    function distributeFees(
        IPoolManager poolManager,
        address trader,
        Currency currency,
        uint256 totalAmount
    ) external onlyAuthorizedHook {
        // Calculate splits
        uint256 rewardsAmount = (totalAmount * REWARDS_TREASURY_BPS) / 10000;
        uint256 platformAmount = totalAmount - rewardsAmount;
        
        // Distribute fees via pool manager
        poolManager.take(currency, rewardsTreasury, rewardsAmount);
        poolManager.take(currency, platformTreasury, platformAmount);
        
        emit FeesDistributed(
            msg.sender, // The calling hook
            trader,
            currency,
            totalAmount,
            rewardsAmount,
            platformAmount
        );
    }
    
    /// @notice Get current treasury addresses
    function getTreasuries() external view returns (address platform, address rewards) {
        return (platformTreasury, rewardsTreasury);
    }
}