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
    uint256 public constant MIN_DISTRIBUTE_BPS = 1000;

    // ------------------------------------------
    //  Events/Errors
    // ------------------------------------------

    event RecipientsUpdated(address[] recipients, uint16[] bps);
    event FeesReceived(address indexed from, uint256 amount);
    event FeesDistributed(uint256 amount, uint256 nRecipients);
    event ApproveFailed(address indexed token, address indexed spender, uint256 amount);
    event SwapFailed(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);
    event ForwardingFailed(address indexed to, address asset, uint256 amount);

    error ZeroAddress();
    error Unauthorized();
    error InsufficientBalance(uint256 request, uint256 balance);
    error NoRecipients();
    error TransferFailed(address to, uint256 amt);
    error BadParams();
    error Bps();
    error InactiveMarket(address token);
    error NotMigrated(address token);
    error NoBalance(address token);
    error ApproveError(address token, address spender, uint256 amount);
    error SwapError(address tokenIn, address tokenOut, uint256 amountIn);
    error ForwardingError(address to, address asset, uint256 amount);

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

    receive() external payable { emit FeesReceived(msg.sender, msg.value); }

    // ------------------------------------------
    //  Standard Fee Distribution
    // ------------------------------------------

    /**
     * @notice Enables recipients to sweep feeRouter for remaining 11% split
     * @dev Bonding fees are ephemeral for currency0 so remaining ETH balance should be absolute;
     *      playerToken balances are automatically swept during migration
     * @param amount Total ETH to distribute in wei (amount=0 for full balance)
     */
    function distribute(uint256 amount) external onlyOrchestrator nonReentrant {
        uint256 bal = address(this).balance;
        uint256 toDistribute = amount == 0 ? bal : amount;

        uint256 minAmt = (bal * MIN_DISTRIBUTE_BPS) / BPS;
        if (toDistribute != 0 && toDistribute < minAmt) {
            toDistribute = minAmt;
        }

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

            if (!ok) revert TransferFailed(to, share);
        }

        emit FeesDistributed(toDistribute, n);
    }

    // ------------------------------------------
    //  Bonding Fee Routing
    // ------------------------------------------

    /// @notice Payable path used by Doppler to forward bonding fees to rewardsTreasury
    /// @dev Automatically relays 89% of currency0 fees for Performance Based Returns
    function forwardBondingFee(address market) external payable onlyBondingCurve(market) nonReentrant {
        uint256 amount = msg.value;

        // Non-blocking for Doppler
        uint256 forward = (amount * PBR_BPS) / BPS;
        if (forward > 0) {
            (bool ok, ) = payable(rewardsTreasury).call{ value: forward }("");
            if (!ok) emit ForwardingFailed(rewardsTreasury, address(0), forward);
        }
    }

    /// @notice Convert ERC20 balance (accrued during bonding) to ETH via HPSwapRouter
    /// @dev Retroactively relays 89% of currency1 fees during migration for Performance Based Returns (non-blocking)
    function convertBondingFee(
        address token         // ERC20 held by FeeRouter
    ) external onlyAirlock nonReentrant {
        // Hard-fail on bad input
        if (token == address(0)) revert ZeroAddress();

        // Non-blocking for Airlock
        _convertBondingFee(token, false);
    }

    /// @dev Shared implementation for conversion
    /// @dev strict=true reverts on failures, strict=false emits and returns
    function _convertBondingFee(address token, bool strict) internal {
        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) return;

        // approve router
        if (IERC20(token).allowance(address(this), swapRouter) < amountIn) {
            // approve(0)
            (bool ok0, bytes memory ret0) =
                token.call(abi.encodeWithSelector(IERC20.approve.selector, swapRouter, 0));
            if (!ok0 || (ret0.length != 0 && !abi.decode(ret0, (bool)))) {
                if (strict) revert ApproveError(token, swapRouter, 0);
                emit ApproveFailed(token, swapRouter, 0);
                return;
            }

            // approve(amountIn)
            (bool ok1, bytes memory ret1) =
                token.call(abi.encodeWithSelector(IERC20.approve.selector, swapRouter, amountIn));
            if (!ok1 || (ret1.length != 0 && !abi.decode(ret1, (bool)))) {
                if (strict) revert ApproveError(token, swapRouter, amountIn);
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
            block.timestamp + 120
        ) returns (IHPSwapRouter.SwapResult memory _sr) {
            sr = _sr;
        } catch {
            if (strict) revert SwapError(token, address(0), amountIn);
            emit SwapFailed(token, address(0), amountIn);
            return;
        }

        // split and relay to rewardsTreasury
        uint256 ethOut = sr.amountOut;
        if (ethOut > 0) {
            // forward 89% to rewards
            uint256 forward = (ethOut * PBR_BPS) / BPS;
            if (forward > 0) {
                (bool sent, ) = payable(rewardsTreasury).call{ value: forward }("");
                if (!sent) {
                    if (strict) revert ForwardingError(rewardsTreasury, address(0), forward);
                    emit ForwardingFailed(rewardsTreasury, address(0), forward);
                }
            }
        }
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

    /// @notice Can re-run auto-conversion in the event of Airlock.migrate() non-blocking failure
    /// @dev Ensures token is an active and migrated playerToken and balance > 0
    function rerunConvert(address token) external onlyOrchestrator nonReentrant {
        if (!whitelistRegistry.isMarketActive(token)) revert InactiveMarket(token);

        if (!whitelistRegistry.hasMigrated(token)) revert NotMigrated(token);
        if (IERC20(token).balanceOf(address(this)) == 0) revert NoBalance(token);

        _convertBondingFee(token, true);
    }

    // ------------------------------------------
    //  View
    // ------------------------------------------

    /// @notice Get ETH balance
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get recipients
    function recipientsConfig() external view returns (address[] memory addrs, uint16[] memory bps) {
        addrs = recipients;
        bps = recipientsBps;
    }
}