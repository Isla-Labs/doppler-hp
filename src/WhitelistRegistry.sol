// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";

/**
 * @title HighPotential Whitelist Registry
 * @notice Centralized whitelist for all HP token contracts
 * @dev Single source of truth for transfer authorization across all tokens
 */
contract WhitelistRegistry is Ownable2Step {
    
    /// @notice HP smart accounts
    mapping(address => bool) public isPlatformAccount;

    /// @notice Admin accounts that can update system parameters
    mapping(address => bool) public isAdmin;
    
    event PlatformAccountAdded(address indexed account);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    
    constructor(address _owner) Ownable(_owner) {}

    // ==========================================
    // UPDATE FUNCTIONS
    // ==========================================
    
    function addPlatformAccount(address account) external onlyOwner {
        require(account != address(0), "Zero address");
        require(!isPlatformAccount[account], "Already whitelisted");
        
        isPlatformAccount[account] = true;
        emit PlatformAccountAdded(account);
    }
    
    function batchAddPlatformAccounts(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            require(account != address(0), "Zero address");
            
            if (!isPlatformAccount[account]) {
                isPlatformAccount[account] = true;
                emit PlatformAccountAdded(account);
            }
        }
    }

    function addAdmin(address admin) external onlyOwner {
        require(admin != address(0), "Zero address");
        require(!isAdmin[admin], "Already admin");
        
        isAdmin[admin] = true;
        emit AdminAdded(admin);
    }
    
    function removeAdmin(address admin) external onlyOwner {
        require(isAdmin[admin], "Not admin");
        
        isAdmin[admin] = false;
        emit AdminRemoved(admin);
    }

    // ==========================================
    // CHECKER FUNCTIONS
    // ==========================================
    
    function isTransferAllowed(address account) external view returns (bool) {
        return isPlatformAccount[account];
    }
    
    function hasAdminAccess(address account) external view returns (bool) {
        return isAdmin[account];
    }
}