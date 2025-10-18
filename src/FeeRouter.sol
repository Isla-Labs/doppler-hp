// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";
import { IHPSwapRouter } from "src/interfaces/IHPSwapRouter.sol";

contract FeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    address public immutable rewardsTreasury;
    IWhitelistRegistry public immutable whitelistRegistry;
    address public immutable orchestratorProxy;
    address public immutable airlock;
    address public immutable swapRouter;

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
    event ForwardingFailed(address indexed to, address asset, uint256 amount);
    event Distributed(uint256 amount, uint256 nRecipients);
    event Recovered(address indexed to, uint256 amount, address token);
    event ApproveFailed(address indexed token, address indexed spender, uint256 amount);
    event SwapFailed(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);

    error ZeroAddress();
    error Unauthorized();
    error InsufficientBalance(uint256 request, uint256 balance);
    error NoRecipients();
    error TransferFailed();
    error BadParams();
    error Bps();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyBondingCurve(address market) {
        if (!whitelistRegistry.isAuthorizedBondingCurve(market, msg.sender)) revert Unauthorized();
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

    constructor(
        address[] memory recipients_,
        uint16[] memory recipientsBps_,
        address rewardsTreasury_,
        address orchestratorProxy_,
        address whitelistRegistry_,
        address airlock_,
        address swapRouter_
    ) { 
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

        _setRecipients(recipients_, recipientsBps_);
     }

    receive() external payable {}

    // ------------------------------------------
    //  Bonding Fee Routing
    // ------------------------------------------

    /// @notice Payable path used by Doppler to forward bonding fees to rewardsTreasury
    /// @dev Automatically relays 89% of currency0 fees for Performance Based Returns
    function forwardBondingFee(address market) external payable onlyBondingCurve(market) nonReentrant {
        uint256 amount = msg.value;

        uint256 forward = (amount * PBR_BPS) / BPS;
        if (forward > 0) {
            (bool ok, ) = payable(rewardsTreasury).call{ value: forward }("");
            if (!ok) emit ForwardingFailed(rewardsTreasury, address(0), forward);
        }
    }

    /// @notice Convert ERC20 balance (accrued during bonding) to ETH via HPSwapRouter
    /// @dev Retroactively relays 89% of currency1 fees for Performance Based Returns
    function convertBondingFee(
        address token,        // ERC20 held by FeeRouter
        uint256 deadline
    ) external onlyAirlock nonReentrant {
        // Hard-fail on bad input
        if (token == address(0)) revert ZeroAddress();

        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) return;

        // Approve router if needed (non-blocking)
        if (IERC20(token).allowance(address(this), swapRouter) < amountIn) {
            // approve(0)
            (bool ok0, bytes memory ret0) =
                token.call(abi.encodeWithSelector(IERC20.approve.selector, swapRouter, 0));
            if (!ok0 || (ret0.length != 0 && !abi.decode(ret0, (bool)))) {
                emit ApproveFailed(token, swapRouter, 0);
                return;
            }

            // approve(amountIn)
            (bool ok1, bytes memory ret1) =
                token.call(abi.encodeWithSelector(IERC20.approve.selector, swapRouter, amountIn));
            if (!ok1 || (ret1.length != 0 && !abi.decode(ret1, (bool)))) {
                emit ApproveFailed(token, swapRouter, amountIn);
                return;
            }
        }

        // swap(token -> ETH) to this contract; minOut=0
        IHPSwapRouter.SwapResult memory sr;
        try IHPSwapRouter(swapRouter).swap(
            token,
            address(0),
            amountIn,
            0,
            deadline
        ) returns (IHPSwapRouter.SwapResult memory _sr) {
            sr = _sr;
        } catch {
            emit SwapFailed(token, address(0), amountIn);
            return;
        }

        uint256 ethOut = sr.amountOut;

        if (ethOut > 0) {
            // forward 89% to rewards (already non-blocking on send failure)
            uint256 forward = (ethOut * PBR_BPS) / BPS;
            if (forward > 0) {
                (bool sent, ) = payable(rewardsTreasury).call{ value: forward }("");
                if (!sent) emit ForwardingFailed(rewardsTreasury, address(0), forward);
            }
        }
    }

    // ------------------------------------------
    //  Standard Fee Distribution
    // ------------------------------------------

    /**
     * @notice Enables recipients to sweep feeRouter for remaining 11% split
     * @dev Bonding fees are ephemeral so remaining ETH balance should be absolute;
     *      playerToken balances are automatically swept during migration
     * @param amount Total ETH to distribute in wei
     */
    function distribute(uint256 amount) external onlyOrchestrator nonReentrant {
        uint256 bal = address(this).balance;
        uint256 toDistribute = amount == 0 ? bal : amount;
        if (toDistribute > bal) revert InsufficientBalance(amount, bal);

        uint256 n = recipients.length;
        if (n == 0) revert NoRecipients();

        uint256 sent;
        for (uint256 i; i < n; ++i) {
            address to = recipients[i];
            uint256 bps = recipientsBps[i];

            uint256 share = (toDistribute * bps) / BPS;
            sent += share;
            if (i == n - 1) share = toDistribute - (sent - share);
            (bool ok, ) = to.call{ value: share }("");

            if (!ok) revert TransferFailed();
        }
        
        emit Distributed(toDistribute, n);
    }

    // ------------------------------------------
    //  Upkeep
    // ------------------------------------------

    /// @notice External entrypoint gated by GnosisOrchestrator to update distribute() recipients
    function updateRecipients(address[] calldata newRecipients, uint16[] calldata newBps) external onlyOrchestrator { 
        _setRecipients(newRecipients, newBps); 
    }

    /// @notice Internal relay for setting recipients, called by updateRecipients and constructor
    function _setRecipients(address[] memory newRecipients, uint16[] memory newBps) internal {
        if (newRecipients.length != newBps.length || newRecipients.length == 0) revert BadParams();

        uint256 sum;
        for (uint256 i; i < newRecipients.length; ++i) {
            if (newRecipients[i] == address(0)) revert ZeroAddress();
            sum += newBps[i];
        }
        if (sum != BPS) revert Bps();

        recipients = newRecipients;
        recipientsBps = newBps;

        emit RecipientsUpdated(newRecipients, newBps);
    }

    // ------------------------------------------
    //  Recovery
    // ------------------------------------------

    /// @notice Emergency-only. Can recover failed ETH relays without blocking Doppler
    function rescue(address to, uint256 amount) external onlyOrchestrator nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();

        emit Recovered(to, amount, address(0));
    }

    /// @notice Emergency-only. Can recover failed playerToken redistribution without blocking Airlock
    function rescueToken(address token, address to, uint256 amount) external onlyOrchestrator nonReentrant {
        if (to == address(0) || token == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit Recovered(to, amount, token);
    }

    // ------------------------------------------
    //  View
    // ------------------------------------------

    /// @notice Count recipients
    function recipientsLength() external view returns (uint256) { return recipients.length; }
}