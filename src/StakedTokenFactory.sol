// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";

/// @custom:security-contact admin@islalabs.co
contract StakedTokenFactory is ITokenFactory, Ownable {
    constructor(
        address initialOwner
    ) Ownable(initialOwner) { }

    event TokenCreated(
        address indexed token,
        string symbol
    );

    /**
     * @notice Creates a new DERC20 token
     * @param initialSupply Total supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param salt Salt used for the create2 deployment
     * @param data Creation parameters encoded as bytes
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external onlyOwner returns (address) {
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(data, (string, string, uint256, uint256, address[], uint256[], string));

        address token = address(
            new DERC20{ salt: salt }(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        );

        emit TokenCreated(token, symbol);

        return token;
    }
}