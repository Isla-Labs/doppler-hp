// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/// @custom:security-contact admin@islalabs.co
contract TokenFactory is ITokenFactory, ImmutableAirlock {
    /// @notice Address of the whitelist registry
    address public immutable whitelistRegistry;

    constructor(
        address airlock_,
        address whitelistRegistry_
    ) ImmutableAirlock(airlock_) {
        require(whitelistRegistry_ != address(0), "TokenFactory: zero address");
        whitelistRegistry = whitelistRegistry_;
    }

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
    ) external onlyAirlock returns (address) {
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(data, (string, string, uint256, uint256, address[], uint256[], string));

        return address(
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
                tokenURI,
                whitelistRegistry
            )
        );
    }
}