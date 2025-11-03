// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title Market Sunsetter
 * @notice Placeholder implementation for TransparentUpgradeableProxy; receives LP NFTs
 * @author Isla Labs
 * @custom:security-contact security@islalabs.co
 */
contract MarketSunsetterV0 is Initializable, IERC721Receiver {
    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer { }

    // Accept LP NFTs
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable { }
}