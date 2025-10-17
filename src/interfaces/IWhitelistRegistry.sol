// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IWhitelistRegistry {
    function isMarketActive(address token) external view returns (bool);
    function isAuthorizedHookFor(address token, address hook) external view returns (bool);
    function getHooks(address token) external view returns (address dopplerHook, address migratorHook);
    function hasMigrated(address token) external view returns (bool);
    function tokenSets(address token) external view returns (
        address tokenAddr,
        address vault,
        address dopplerHook,
        address migratorHook,
        bool hasMigrated,
        bool isActive,
        uint256 deactivatedAt,
        bool sunsetComplete
    );
}

interface IWhitelistRegistryAdmin {
    function addMarket(
        address token,
        address vault,
        address dopplerHook,
        address migratorHook
    ) external;

    function updateMigrationStatus(address token) external;

    function discontinueMarket(address token) external;
}