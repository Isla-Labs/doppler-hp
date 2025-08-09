// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { StakedTokenFactory } from "src/StakedTokenFactory.sol";
import { ChainIds } from "script/ChainIds.sol";

struct ScriptData {
    uint256 chainId;
    address initialOwner;
}

abstract contract DeployStakedTokenFactoryScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        vm.startBroadcast();
        require(_scriptData.chainId == block.chainid, "Incorrect chainId");
        StakedTokenFactory factory = new StakedTokenFactory(_scriptData.initialOwner);
        vm.stopBroadcast();
    }
}

/// @dev forge script DeployStakedTokenFactoryBaseSepoliaScript --private-key $PRIVATE_KEY --verify --rpc-url $BASE_SEPOLIA_RPC_URL --slow --broadcast
contract DeployStakedTokenFactoryBaseSepoliaScript is DeployStakedTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.BASE_SEPOLIA,
            initialOwner: msg.sender
        });
    }
}

/// @dev forge script DeployStakedTokenFactoryBaseMainnetScript --private-key $PRIVATE_KEY --verify --rpc-url $BASE_MAINNET_RPC_URL --slow --broadcast
contract DeployStakedTokenFactoryBaseMainnetScript is DeployStakedTokenFactoryScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.BASE_MAINNET,
            initialOwner: msg.sender
        });
    }
}