// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployV4Script, V4ScriptData } from "script/deployV4/DeployV4.s.sol";

contract DeployV4BaseSepolia is DeployV4Script {
    function setUp() public override {
        _scriptData = V4ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4,
            platformTreasury: 0xAa9eB4C3d3DD5F3F10DF00dE7A8D63266B497810,
            rewardsTreasury: 0xd432a083Ecf69D57A889F4B46DF1b644Bc2a1671,
            whitelistRegistry: 0x0000000000000000000000000000000000000000
        });
    }
}