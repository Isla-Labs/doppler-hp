// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title HighPotential Whitelist Registry
 * @notice List of canonical HP markets with full lifecycle schematics
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract WhitelistRegistry {
    /// @notice Address of the Airlock contract
    address public airlock;

    /// @notice Address of the AirlockMultisig contract
    address public airlockMultisig;

    /// @notice Address of the MarketSunsetter contract
    address public marketSunsetter;

    /// @notice Initialization tag
    bool public initialized;

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
    error ZeroAddress();
    error NeedZero();
    error AlreadyInitialized();

    // ------------------------------------------
    //  Constructor
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
    }

    function initialize(address airlock_, address airlockMultisig_, address marketSunsetter_) external {
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
    }

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyAirlock() {
        require(msg.sender == airlock, "Not authorized");
        _;
    }
    
    modifier onlyAirlockMultisig() {
        require(msg.sender == airlockMultisig, "Not authorized");
        _;
    }

    modifier onlyMarketSunsetter() {
        require(msg.sender == marketSunsetter, "Not authorized");
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    function addMarket(
        address token,
        address vault,
        address dopplerHook,
        address migratorHook
    ) external onlyAirlockMultisig {
        require(tokenSets[token].token == address(0), "Market exists");
        require(token != address(0) && vault != address(0), "Zero address");
        require(dopplerHook != address(0) && migratorHook != address(0), "Zero address");

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
    //  Upkeep
    // ------------------------------------------

    function updateMigrationStatus(address token) external onlyAirlock {
        TokenSet storage ts = tokenSets[token];

        require(ts.token != address(0), "Unknown token");
        require(!ts.hasMigrated, "Already migrated");

        ts.hasMigrated = true;

        emit MarketMigrated(ts.token, ts.migratorHook, true);
    }

    function discontinueMarket(address token) external onlyMarketSunsetter {
        TokenSet storage ts = tokenSets[token];

        require(ts.token != address(0), "Unknown token");
        require(ts.isActive, "Already inactive");

        ts.isActive = false;
        ts.deactivatedAt = block.timestamp;

        emit MarketDiscontinued(token, ts.vault, ts.deactivatedAt);
    }

    // ------------------------------------------
    //  External View
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