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
    
    event PlatformAccountAdded(address indexed account);
    
    constructor(address _owner) Ownable(_owner) {}

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
    
    function isTransferAllowed(address account) external view returns (bool) {
        return isPlatformAccount[account];
    }
}