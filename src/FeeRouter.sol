// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";
import { IHPSwapRouter } from "src/interfaces/IHPSwapRouter.sol";

contract FeeRouter is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    address public rewardsTreasury;
    IWhitelistRegistry public whitelistRegistry;
    address public orchestratorProxy;
    address public airlock;
    address public swapRouter;

    // ------------------------------------------
    //  Config
    // ------------------------------------------

    address[] public recipients;
    uint16[] public recipientsBps; // sums to 10_000

    uint256 public constant BPS = 10_000;
    uint256 public constant PBR_BPS = 8900;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event RecipientsUpdated(address[] recipients, uint16[] bps);
    event FeesReceived(address indexed from, uint256 amount);
    event Distributed(uint256 amount, uint256 nRecipients);
    event Rescue(address indexed to, uint256 amount, address token);

    error ZeroAddress();
    error Unauthorized();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyAuthorizedBondingCurve(address market) {
        if (!whitelistRegistry.isAuthorizedHookFor(market, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyAirlock() {
        if (msg.sender != airlock) revert Unauthorized();
        _;
    }

    modifier onlyOrchestrator() {
        if (msg.sender != orchestratorProxy) revert Unauthorized();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor() { _disableInitializers(); }

    function initialize(
        address rewardsTreasury_,
        address orchestratorProxy_,
        address whitelistRegistry_,
        address airlock_,
        address swapRouter_
    ) external initializer {
        if (
            rewardsTreasury_ == address(0) || 
            orchestratorProxy_ == address(0) || 
            whitelistRegistry_ == address(0) || 
            airlock_ == address(0) || 
            swapRouter_ == address(0)
        ) revert ZeroAddress();

        rewardsTreasury = rewardsTreasury_;
        orchestratorProxy = orchestratorProxy_;
        whitelistRegistry = IWhitelistRegistry(whitelistRegistry_);
        airlock = airlock_;
        swapRouter = swapRouter_;
    }

    receive() external payable {
        emit FeesReceived(msg.sender, msg.value);
    }

    // ------------------------------------------
    //  Bonding Fee Management
    // ------------------------------------------

    /// @notice Payable path used by Doppler to forward bonding ETH and auto-route 89% to rewards
    function forwardBondingFee(address market) external payable onlyAuthorizedBondingCurve(market) nonReentrant {
        uint256 amount = msg.value;

        uint256 forward = (amount * PBR_BPS) / BPS;
        if (forward > 0) {
            (bool ok, ) = payable(rewardsTreasury).call{ value: forward }("");
            require(ok, "FWD_FAIL");
        }
    }

    /// @notice Convert ERC20 balance (accrued during bonding) to ETH via HPSwapRouter
    /// @dev Retroactively relays 89% of currency1 fees for Performance Based Returns
    function convertBondingFee(
        address token,        // ERC20 held by FeeRouter
        uint256 deadline
    ) external onlyAirlock nonReentrant {
        require(token != address(0), "ZERO_TOKEN");
        require(swapRouter != address(0), "ZERO_ROUTER");

        uint256 amountIn = IERC20(token).balanceOf(address(this));
        require(amountIn > 0, "NO_BALANCE");

        // Approve router if needed
        if (IERC20(token).allowance(address(this), swapRouter) < amountIn) {
            IERC20(token).safeApprove(swapRouter, 0);
            IERC20(token).safeApprove(swapRouter, amountIn);
        }

        // swap(token -> ETH) to this contract; minOut=0 per your simplification
        IHPSwapRouter.SwapResult memory sr = IHPSwapRouter(swapRouter).swap(
            token,
            address(0),
            amountIn,
            0,
            deadline
        );

        uint256 ethOut = sr.amountOut;

        if (ethOut > 0) {
            // forward 89% to rewards
            uint256 forward = (ethOut * PBR_BPS) / BPS;
            if (forward > 0) {
                (bool sent, ) = payable(rewardsTreasury).call{ value: forward }("");
                require(sent, "FWD_FAIL");
            }
        }
    }

    // ------------------------------------------
    //  Fee Distribution
    // ------------------------------------------

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

    // ------------------------------------------
    //  Upkeep
    // ------------------------------------------

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

    function updateRecipients(address[] calldata newRecipients, uint16[] calldata newBps) external onlyOrchestrator { 
        _setRecipients(newRecipients, newBps); 
    }

    // ------------------------------------------
    //  Recovery
    // ------------------------------------------

    function rescue(address to, uint256 amount) external onlyOrchestrator nonReentrant {
        require(to != address(0), "ZERO_TO");

        (bool ok, ) = to.call{ value: amount }("");
        require(ok, "RESCUE_FAIL");

        emit Rescue(to, amount, address(0));
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOrchestrator {
        if (to == address(0) || token == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit Rescue(to, amount, token);
    }

    // ------------------------------------------
    //  View
    // ------------------------------------------

    function recipientsLength() external view returns (uint256) { return recipients.length; }
}