// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title HighPotential Whitelist Registry
 * @notice List of canonical HP markets with full lifecycle schematics
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract WhitelistRegistry {

    bool private initialized;
    address private invoker;

    address public airlock;
    address public airlockMultisig;
    address public marketSunsetter;

    // ------------------------------------------
    //  Storage
    // ------------------------------------------

    /// @notice Asset lifecycle schematics
    struct TokenSet {
        address token;
        address vault;
        address dopplerHook;
        address migratorHook;
        bool hasMigrated;
        bool isActive;
        uint256 deactivatedAt; // for +90d remigration
        bool sunsetComplete;
    }
    
    /// @notice Retrieve TokenSet from tokenAddress
    mapping(address => TokenSet) public tokenSets;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event MarketLaunched(address indexed token, address dopplerHook, bool isActive);
    event MarketMigrated(address indexed token, address migratorHook, bool hasMigrated);
    event MarketDiscontinued(address indexed token, address vault, uint256 deactivatedAt);
    event SunsetComplete(address indexed token, uint256 completedAt);

    error NotAllowed();
    error NeedZero();
    error AlreadyInitialized();
    error ZeroAddress();
    error MarketExists();
    error UnknownToken();
    error AlreadyInactive();
    error AlreadyMigrated();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyAirlock() {
        if (msg.sender != airlock) revert NotAllowed();
        _;
    }
    
    modifier onlyAirlockMultisig() {
        if (msg.sender != airlockMultisig) revert NotAllowed();
        _;
    }

    modifier onlyMarketSunsetter() {
        if (msg.sender != marketSunsetter) revert NotAllowed();
        _;
    }

    modifier onlyInvoker() {
        if (msg.sender != invoker) revert NotAllowed();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------
    
    constructor(
        address _airlock,
        address _airlockMultisig, 
        address _marketSunsetter
    ) {
        if (
            address(_airlock) != address(0) || 
            address(_airlockMultisig) != address(0) || 
            address(_marketSunsetter) != address(0)
        ) revert NeedZero();

        invoker = msg.sender;
    }

    function initialize(address airlock_, address airlockMultisig_, address marketSunsetter_) external onlyInvoker {
        if (initialized) revert AlreadyInitialized();

        if (
            airlock_ == address(0) || 
            airlockMultisig_ == address(0) || 
            marketSunsetter_ == address(0)
        ) revert ZeroAddress();
        
        airlock = airlock_;
        airlockMultisig = airlockMultisig_;
        marketSunsetter = marketSunsetter_;

        initialized = true;
        invoker = address(0);
    }

    // ------------------------------------------
    //  Market Deployment
    // ------------------------------------------

    function addMarket(
        address token,
        address vault,
        address dopplerHook,
        address migratorHook
    ) external onlyAirlockMultisig {
        if (
            token == address(0) || 
            vault == address(0) || 
            dopplerHook == address(0) || 
            migratorHook == address(0)
        ) revert ZeroAddress();
        if (tokenSets[token].token != address(0)) revert MarketExists();

        tokenSets[token] = TokenSet({
            token: token,
            vault: vault,
            dopplerHook: dopplerHook,
            migratorHook: migratorHook,
            hasMigrated: false,
            isActive: true,
            deactivatedAt: 0,
            sunsetComplete: false
        });

        emit MarketLaunched(token, dopplerHook, true);
    }

    // ------------------------------------------
    //  Market Lifecycle
    // ------------------------------------------

    function updateMigrationStatus(address token) external onlyAirlock {
        TokenSet storage ts = tokenSets[token];

        if (ts.token == address(0)) revert UnknownToken();
        if (ts.hasMigrated) revert AlreadyMigrated();

        ts.hasMigrated = true;

        emit MarketMigrated(ts.token, ts.migratorHook, true);
    }

    function discontinueMarket(address token) external onlyMarketSunsetter {
        TokenSet storage ts = tokenSets[token];

        if (ts.token == address(0)) revert UnknownToken();
        if (!ts.isActive) revert AlreadyInactive();

        ts.isActive = false;
        ts.deactivatedAt = block.timestamp;

        emit MarketDiscontinued(token, ts.vault, ts.deactivatedAt);
    }

    // ------------------------------------------
    //  View
    // ------------------------------------------

    function isMarketActive(address token) external view returns (bool) {
        return tokenSets[token].isActive;
    }

    function isAuthorizedBondingCurve(address token, address hook) external view returns (bool) {
        TokenSet storage ts = tokenSets[token];
        return hook == ts.dopplerHook;
    }

    function getHooks(address token) external view returns (address dopplerHook, address migratorHook) {
        TokenSet storage ts = tokenSets[token];
        return (ts.dopplerHook, ts.migratorHook);
    }

    function hasMigrated(address token) external view returns (bool) {
        return tokenSets[token].hasMigrated;
    }
}