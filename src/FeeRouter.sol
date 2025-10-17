// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";

contract FeeRouter is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant BPS = 10_000;

    uint256 public constant PBR_BPS = 8900;

    address public rewardsTreasury;
    IWhitelistRegistry public registry;

    address[] public recipients;
    uint16[] public recipientsBps; // sums to 10_000

    event RecipientsUpdated(address[] recipients, uint16[] bps);
    event FeesReceived(address indexed from, uint256 amount);
    event Distributed(uint256 amount, uint256 nRecipients);
    event Rescue(address indexed to, uint256 amount);

    // new
    event TaggedDeposit(address indexed token, address indexed market, address indexed source, uint256 amount, bytes32 tag);

    modifier onlyAuthorized(address market) {
        require(registry.isAuthorizedHookFor(market, msg.sender), "NOT_AUTH");
        _;
    }

    constructor() { _disableInitializers(); }

    function initialize(
        address owner_,
        address rewardsTreasury_,
        address registry_
    ) external initializer {
        require(owner_ != address(0), "ZERO_OWNER");
        require(rewardsTreasury_ != address(0), "ZERO_REWARDS");
        require(registry_ != address(0), "ZERO_REGISTRY");
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        _transferOwnership(owner_);
        rewardsTreasury = rewardsTreasury_;
        registry = IWhitelistRegistry(registry_);
    }

    receive() external payable {
        emit FeesReceived(msg.sender, msg.value);
    }

    // Payable path used by Doppler to forward bonding ETH and auto-route 89% to rewards
    function forwardBondingFee(address market) external payable onlyAuthorized(market) nonReentrant {
        uint256 amount = msg.value;
        emit TaggedDeposit(address(0), market, msg.sender, amount, bytes32("DOPPLER_FEE"));

        uint256 forward = (amount * PBR_BPS) / BPS;
        if (forward > 0) {
            (bool ok, ) = payable(rewardsTreasury).call{ value: forward }("");
            require(ok, "FWD_FAIL");
        }
    }

    function updateRecipients(address[] calldata newRecipients, uint16[] calldata newBps) external onlyOwner { 
        _setRecipients(newRecipients, newBps); 
    }

    function distribute(uint256 amount) external nonReentrant {
        uint256 bal = address(this).balance;
        uint256 toDistribute = amount == 0 ? bal : amount;
        require(toDistribute <= bal, "INSUFFICIENT_BAL");

        uint256 n = recipients.length;
        require(n > 0, "NO_RECIPIENTS");

        uint256 sent;
        for (uint256 i; i < n; ++i) {
            uint256 share = (toDistribute * recipientsBps[i]) / BPS;
            sent += share;
            if (i == n - 1) share = toDistribute - (sent - share);
            (bool ok, ) = recipients[i].call{ value: share }("");
            require(ok, "TRANSFER_FAIL");
        }
        emit Distributed(toDistribute, n);
    }

    function rescue(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "ZERO_TO");
        (bool ok, ) = to.call{ value: amount }("");
        require(ok, "RESCUE_FAIL");
        emit Rescue(to, amount);
    }

    function recipientsLength() external view returns (uint256) { return recipients.length; }

    function _setRecipients(address[] calldata newRecipients, uint16[] calldata newBps) internal {
        require(newRecipients.length == newBps.length, "LEN_MISMATCH");
        require(newRecipients.length > 0, "EMPTY");
        uint256 sum;
        for (uint256 i; i < newRecipients.length; ++i) {
            require(newRecipients[i] != address(0), "ZERO_RECIPIENT");
            sum += newBps[i];
        }
        require(sum == BPS, "BPS_SUM");
        recipients = newRecipients;
        recipientsBps = newBps;
        emit RecipientsUpdated(newRecipients, newBps);
    }
}