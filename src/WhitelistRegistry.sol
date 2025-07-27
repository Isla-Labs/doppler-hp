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
    
    // ==========================================
    // STATE VARIABLES
    // ==========================================

    /// @notice Verified Player Tokens
    mapping(address => bool) public isVerifiedToken;
    
    /// @notice HP smart accounts
    mapping(address => bool) public isPlatformAccount;
    
    /// @notice Infrastructure contract status
    struct InfrastructureStatus {
        bool isWhitelisted;
        bool isDeprecated;
    }
    mapping(address => InfrastructureStatus) public infrastructureContracts;
    
    // ==========================================
    // EVENTS
    // ==========================================
    
    event VerifiedTokenAdded(address indexed token);
    event PlatformAccountAdded(address indexed account);
    event InfrastructureContractAdded(address indexed contractAddress, string contractType);
    event InfrastructureContractDeprecationChanged(address indexed contractAddress, string contractType, bool isDeprecated);
    
    // ==========================================
    // CONSTRUCTOR
    // ==========================================
    
    constructor(address _owner) Ownable(_owner) {}
    
    // ==========================================
    // ADMIN FUNCTIONS
    // ==========================================

    /////////
    // Add singles

    function addVerifiedToken(address token) external onlyOwner {
        require(token != address(0), "Zero address");
        require(!isVerifiedToken[token], "Already verified");
        
        isVerifiedToken[token] = true;
        emit VerifiedTokenAdded(token);
    }
    
    function addPlatformAccount(address account) external onlyOwner {
        require(account != address(0), "Zero address");
        require(!isPlatformAccount[account], "Already whitelisted");
        
        isPlatformAccount[account] = true;
        emit PlatformAccountAdded(account);
    }
    
    function addInfrastructureContract(address contractAddress, string calldata contractType) external onlyOwner {
        require(contractAddress != address(0), "Zero address");
        require(!infrastructureContracts[contractAddress].isWhitelisted, "Already whitelisted");
        
        infrastructureContracts[contractAddress] = InfrastructureStatus({
            isWhitelisted: true,
            isDeprecated: false
        });
        emit InfrastructureContractAdded(contractAddress, contractType);
    }

    function updateInfrastructureStatus(
        address contractAddress, 
        string calldata contractType, 
        bool isDeprecated
    ) external onlyOwner {
        require(contractAddress != address(0), "Zero address");
        require(infrastructureContracts[contractAddress].isWhitelisted, "Not whitelisted");
        require(infrastructureContracts[contractAddress].isDeprecated != isDeprecated, "Status unchanged");
        
        infrastructureContracts[contractAddress].isDeprecated = isDeprecated;
        emit InfrastructureContractDeprecationChanged(contractAddress, contractType, isDeprecated);
    }

    /////////
    // Add batches

    function batchAddVerifiedTokens(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Zero address");
            
            if (!isVerifiedToken[token]) {
                isVerifiedToken[token] = true;
                emit VerifiedTokenAdded(token);
            }
        }
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

    function batchAddInfrastructureContracts(
        address[] calldata contractAddresses, 
        string[] calldata contractTypes
    ) external onlyOwner {
        require(contractAddresses.length == contractTypes.length, "Array length mismatch");
        
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            address contractAddress = contractAddresses[i];
            require(contractAddress != address(0), "Zero address");
            
            if (!infrastructureContracts[contractAddress].isWhitelisted) {
                infrastructureContracts[contractAddress] = InfrastructureStatus({
                    isWhitelisted: true,
                    isDeprecated: false
                });
                emit InfrastructureContractAdded(contractAddress, contractTypes[i]);
            }
        }
    }

    function batchUpdateInfrastructureStatus(
        address[] calldata contractAddresses, 
        string[] calldata contractTypes,
        bool[] calldata deprecationStatuses
    ) external onlyOwner {
        require(contractAddresses.length == contractTypes.length, "Array length mismatch");
        require(contractAddresses.length == deprecationStatuses.length, "Array length mismatch");
        
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            address contractAddress = contractAddresses[i];
            bool newStatus = deprecationStatuses[i];
            require(contractAddress != address(0), "Zero address");
            
            InfrastructureStatus storage status = infrastructureContracts[contractAddress];
            if (status.isWhitelisted && status.isDeprecated != newStatus) {
                status.isDeprecated = newStatus;
                emit InfrastructureContractDeprecationChanged(contractAddress, contractTypes[i], newStatus);
            }
        }
    }
    
    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    function isTransferAllowed(address from, address to) external view returns (bool) {
        // Allow minting and burning
        if (from == address(0) || to == address(0)) return true;
        
        bool fromWhitelisted = isPlatformAccount[from] || _isActiveInfrastructure(from);
        bool toWhitelisted = isPlatformAccount[to] || _isActiveInfrastructure(to);
        
        return fromWhitelisted && toWhitelisted;
    }
    
    function isInfrastructureContract(address contractAddress) external view returns (bool) {
        // Checks if contract is/was whitelisted (ignores deprecation status)
        return infrastructureContracts[contractAddress].isWhitelisted;
    }

    function _isActiveInfrastructure(address contractAddress) internal view returns (bool) {
        // Checks if contract is whitelisted and active
        InfrastructureStatus memory status = infrastructureContracts[contractAddress];
        return status.isWhitelisted && !status.isDeprecated;
    }
}