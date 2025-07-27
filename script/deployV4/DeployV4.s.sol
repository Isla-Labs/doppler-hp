// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { Airlock } from "src/Airlock.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { WhitelistRegistry } from "src/WhitelistRegistry.sol";
import { TreasuryManager } from "src/TreasuryManager.sol";

struct V4ScriptData {
    address airlock;
    address poolManager;
    address stateView;
    address platformTreasury;
    address rewardsTreasury;
    address whitelistRegistry;
}

/**
 * @title HighPotential V4 Deployment Script
 * @notice Deploys the HP V4 ecosystem with Doppler analytics
 */
abstract contract DeployV4Script is Script {
    V4ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying HighPotential V4 on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Reference existing WhitelistRegistry instead of deploying new one
        require(_scriptData.whitelistRegistry != address(0), "WhitelistRegistry address required");
        WhitelistRegistry whitelistRegistry = WhitelistRegistry(_scriptData.whitelistRegistry);
        
        TreasuryManager treasuryManager = new TreasuryManager(
            msg.sender,
            _scriptData.platformTreasury,
            _scriptData.rewardsTreasury
        );

        // Deploy Doppler infrastructure
        DopplerDeployer dopplerDeployer = new DopplerDeployer(
            IPoolManager(_scriptData.poolManager),
            treasuryManager
        );
        
        UniswapV4Initializer uniswapV4Initializer = new UniswapV4Initializer(
            _scriptData.airlock, 
            IPoolManager(_scriptData.poolManager), 
            dopplerDeployer
        );

        // Deploy Doppler Lens
        DopplerLensQuoter dopplerLens = new DopplerLensQuoter(
            IPoolManager(_scriptData.poolManager), 
            IStateView(_scriptData.stateView)
        );

        console.log(unicode"✨ Contracts were successfully deployed!");

        console.log("");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| WhitelistRegistry          | %s |", address(whitelistRegistry));
        console.log("| TreasuryManager            | %s |", address(treasuryManager));
        console.log("| DopplerDeployer            | %s |", address(dopplerDeployer));
        console.log("| UniswapV4Initializer       | %s |", address(uniswapV4Initializer));
        console.log("| DopplerLensQuoter          | %s |", address(dopplerLens));
        console.log("+----------------------------+--------------------------------------------+");
        console.log("");
        console.log("Platform Treasury: %s (11%%)", _scriptData.platformTreasury);
        console.log("Rewards Treasury: %s (89%%)", _scriptData.rewardsTreasury);

        vm.stopBroadcast();
    }
}