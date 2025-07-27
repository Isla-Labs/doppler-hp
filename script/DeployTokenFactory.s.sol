// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { WhitelistRegistry } from "src/WhitelistRegistry.sol";

struct ScriptData {
    uint256 chainId;
    address airlock;
    address whitelistRegistry;
}

abstract contract DeployTokenFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(block.chainid == _scriptData.chainId, "Invalid chainId");
        
        console.log("Deploying TokenFactory with WhitelistRegistry: %s", _scriptData.whitelistRegistry);
        
        TokenFactory tokenFactory = new TokenFactory(
            _scriptData.airlock,
            _scriptData.whitelistRegistry
        );
        
        console.log("TokenFactory deployed at: %s", address(tokenFactory));
        
        vm.stopBroadcast();
    }
}

// @dev forge script DeployTokenFactoryBaseScript --rpc-url $BASE_MAINNET_RPC_URL --broadcast --verify --slow --private-key $PRIVATE_KEY
contract DeployTokenFactoryBaseScript is DeployTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ 
            chainId: 8453, 
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            whitelistRegistry: 0x0000000000000000000000000000000000000000  // <-- UPDATE WITH ACTUAL ADDRESS
        });
    }
}

// @dev forge script DeployTokenFactoryBaseSepoliaScript --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify --slow --private-key $PRIVATE_KEY
contract DeployTokenFactoryBaseSepoliaScript is DeployTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({ 
            chainId: 84_532, 
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            whitelistRegistry: 0x0000000000000000000000000000000000000000  // <-- UPDATE WITH ACTUAL ADDRESS
        });
    }
}