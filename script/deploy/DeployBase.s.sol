// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployScript, ScriptData } from "script/deploy/Deploy.s.sol";
import { ChainIds } from "script/ChainIds.sol";

contract DeployBase is DeployScript {
	function setUp() public override {
		_scriptData = ScriptData({
			chainId: ChainIds.BASE_MAINNET,
			poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
			protocolOwner: msg.sender,
			quoterV2: 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a,
			uniswapV2Factory: 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6,
			uniswapV2Router02: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
			uniswapV3Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD,
			universalRouter: 0x6fF5693b99212Da76ad316178A184AB56D299b43,
			stateView: 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71,
			positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
			platformTreasury: 0xAa9eB4C3d3DD5F3F10DF00dE7A8D63266B497810,
			rewardsTreasury: 0xd432a083Ecf69D57A889F4B46DF1b644Bc2a1671
		});
	}
}