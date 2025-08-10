// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";

// Token + Vault mapping
struct TokenSet {
    address token;
    address vault;
    bool isActive;
}

/**
 * @title HighPotential Whitelist Registry
 * @notice List of verified Player Token, Player Vault combinations
 * @dev Single source of truth for HP TokenSets (Player Token, Player Vault, IsActive)
 */
contract WhitelistRegistry is Ownable2Step {
    
    /// @notice Admin accounts that can update system parameters
    mapping(address => bool) public isAdmin;

    /// @notice List of all TokenSets (Player Token + Player Vault combinations)
    mapping(address => TokenSet) public tokenSets;

    event TokenSetUpserted(address indexed token, address indexed vault, bool isActive);
    event TokenSetDeactivated(address indexed token, address indexed vault);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    
    constructor(address _owner) Ownable(_owner) {}

    // ==========================================
    // MODIFIERS
    // ==========================================
    
    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), "Not admin or owner");
        _;
    }

    // ==========================================
    // UPDATE FUNCTIONS
    // ==========================================

    function addTokenSet(address token, address vault) external onlyAdmin {
        require(token != address(0) && vault != address(0), "Zero address");
        tokenSets[token] = TokenSet({ token: token, vault: vault, isActive: true });
        emit TokenSetUpserted(token, vault, true);
    }

    function updateVault(address token, address newVault) external onlyAdmin {
        require(newVault != address(0), "Zero address");
        TokenSet storage ts = tokenSets[token];
        require(ts.token != address(0), "Unknown token");
        ts.vault = newVault;
        emit TokenSetUpserted(token, newVault, ts.isActive);
    }

    function deactivateTokenSet(address token) external onlyAdmin {
        TokenSet storage ts = tokenSets[token];
        require(ts.token != address(0), "Unknown token");
        require(ts.isActive, "Already inactive");
        ts.isActive = false;
        emit TokenSetDeactivated(token, ts.vault);
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

    function getVaultAndStatus(address token) external view returns (address vault, bool isActive) {
        TokenSet storage ts = tokenSets[token];
        return (ts.vault, ts.isActive);
    }
    
    function hasAdminAccess(address account) external view returns (bool) {
        return isAdmin[account] || account == owner();
    }
}