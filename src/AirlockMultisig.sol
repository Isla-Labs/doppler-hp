// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Airlock, ModuleState } from "src/Airlock.sol";

/// @notice Multisig for controlling the Airlock.
/// - Maintains existing Airlock-facing functions (execute, setModuleState, transferOwnership)
/// - Adds M-of-N approvals, optional timelock, proposal lifecycle, revoke/confirm, replay protection
/// - Signer set and threshold/delay are updateable via self-governed proposals
contract AirlockMultisig {
	Airlock public immutable airlock;

	// Signers and threshold
	address[] public signers;
	mapping(address => bool) public isSigner;
	mapping(address => uint256) private signerIndex; // 1-based; 0 => not present
	uint256 public threshold; // required confirmations
	uint256 public delay;     // optional timelock in seconds (0 => none)

	// Proposal state
	struct Proposal {
		address target;
		uint256 value;
		bytes data;
		uint256 submitTime;
		uint256 confirmations;
		bool executed;
		bool exists;
	}
	mapping(bytes32 => Proposal) public proposals;
	mapping(bytes32 => mapping(address => bool)) public approved;

	// Events
	event ProposalSubmitted(bytes32 indexed id, address indexed target, uint256 value, bytes data);
	event ProposalConfirmed(bytes32 indexed id, address indexed signer, uint256 confirmations);
	event ProposalRevoked(bytes32 indexed id, address indexed signer, uint256 confirmations);
	event ProposalExecuted(bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes result);

	event SignerAdded(address indexed signer);
	event SignerRemoved(address indexed signer);
	event ThresholdChanged(uint256 threshold);
	event DelayChanged(uint256 delay);

	error NotSigner();
	error AlreadySigner();
	error InvalidSigner();
	error InvalidThreshold();
	error InvalidDelay();
	error ProposalNotFound();
	error ProposalAlreadyExists();
	error ProposalAlreadyExecuted();
	error AlreadyApproved();
	error NotApproved();
	error TooEarly();
	error ExecutionFailed();
	error ValueMismatch();

	modifier onlySigner() {
		if (!isSigner[msg.sender]) revert NotSigner();
		_;
	}

	modifier onlySelf() {
		if (msg.sender != address(this)) revert NotSigner();
		_;
	}

	constructor(Airlock airlock_, address[] memory _signers) {
		airlock = airlock_;
		_initSigners(_signers);
		// Default threshold: majority if N>1, else 1
		uint256 n = _signers.length;
		threshold = n == 1 ? 1 : (n / 2) + 1;
		emit ThresholdChanged(threshold);
		delay = 0;
	}

	receive() external payable {}

	// ================================
	// Airlock-facing (kept API)
	// ================================

	/// @notice Propose/confirm/execute an arbitrary call to Airlock. First call records msg.value; confirmations must send 0.
	function execute(bytes calldata data) external payable onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(address(airlock), msg.value, data);
		_tryExecute(id);
	}

	function setModuleState(address module, ModuleState state) external onlySigner returns (bytes32 id) {
		address[] memory modules = new address[](1);
		modules[0] = module;
		ModuleState[] memory states = new ModuleState[](1);
		states[0] = state;
		id = _proposeOrConfirm(
			address(airlock),
			0,
			abi.encodeWithSelector(Airlock.setModuleState.selector, modules, states)
		);
		_tryExecute(id);
	}

	function setModuleState(address[] calldata modules, ModuleState[] calldata states)
		external
		onlySigner
		returns (bytes32 id)
	{
		id = _proposeOrConfirm(
			address(airlock),
			0,
			abi.encodeWithSelector(Airlock.setModuleState.selector, modules, states)
		);
		_tryExecute(id);
	}

	function transferOwnership(address newOwner) external onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(
			address(airlock),
			0,
			abi.encodeWithSignature("transferOwnership(address)", newOwner)
		);
		_tryExecute(id);
	}

	// ================================
	// Governance of the multisig itself (updateable)
	// ================================

	function addSigner(address newSigner) external onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(address(this), 0, abi.encodeCall(this.selfAddSigner, (newSigner)));
		_tryExecute(id);
	}

	function removeSigner(address signer) external onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(address(this), 0, abi.encodeCall(this.selfRemoveSigner, (signer)));
		_tryExecute(id);
	}

	function changeThreshold(uint256 newThreshold) external onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(address(this), 0, abi.encodeCall(this.selfChangeThreshold, (newThreshold)));
		_tryExecute(id);
	}

	function changeDelay(uint256 newDelay) external onlySigner returns (bytes32 id) {
		id = _proposeOrConfirm(address(this), 0, abi.encodeCall(this.selfChangeDelay, (newDelay)));
		_tryExecute(id);
	}

	// Only executable via proposal (self-governed)
	function selfAddSigner(address newSigner) external onlySelf {
		_addSigner(newSigner);
	}
	function selfRemoveSigner(address signer) external onlySelf {
		_removeSigner(signer);
	}
	function selfChangeThreshold(uint256 newThreshold) external onlySelf {
		if (newThreshold == 0 || newThreshold > signers.length) revert InvalidThreshold();
		threshold = newThreshold;
		emit ThresholdChanged(newThreshold);
	}
	function selfChangeDelay(uint256 newDelay) external onlySelf {
		delay = newDelay;
		emit DelayChanged(newDelay);
	}

	// ================================
	// Proposal lifecycle helpers
	// ================================

	function confirm(bytes32 id) external onlySigner {
		_confirm(id, 0, false);
		_tryExecute(id);
	}

	function revoke(bytes32 id) external onlySigner {
		Proposal storage p = proposals[id];
		if (!p.exists) revert ProposalNotFound();
		if (p.executed) revert ProposalAlreadyExecuted();
		if (!approved[id][msg.sender]) revert NotApproved();
		approved[id][msg.sender] = false;
		p.confirmations -= 1;
		emit ProposalRevoked(id, msg.sender, p.confirmations);
	}

	function executeReady(bytes32 id) external {
		_tryExecute(id);
	}

	// ================================
	// Views
	// ================================

	function getSigners() external view returns (address[] memory) {
		return signers;
	}

	function getProposal(bytes32 id) external view returns (
		address target,
		uint256 value,
		bytes memory data,
		uint256 submitTime,
		uint256 confirmations,
		bool executed,
		bool exists
	) {
		Proposal storage p = proposals[id];
		return (p.target, p.value, p.data, p.submitTime, p.confirmations, p.executed, p.exists);
	}

	// ================================
	// Internal
	// ================================

	function _proposeOrConfirm(address target, uint256 value, bytes memory data) internal returns (bytes32 id) {
		id = keccak256(abi.encode(target, value, data));
		Proposal storage p = proposals[id];

		if (!p.exists) {
			// Creating a new proposal
			p.target = target;
			p.value = value;
			p.data = data;
			p.submitTime = block.timestamp;
			p.exists = true;
			emit ProposalSubmitted(id, target, value, data);
		} else {
			// Existing proposal: ensure consistent params and prevent value re-sends
			if (p.target != target || p.value != value) revert ValueMismatch();
			require(keccak256(p.data) == keccak256(data), "DATA_MISMATCH");
		}

		_confirm(id, value, !p.executed && p.confirmations == 0);
	}

	function _confirm(bytes32 id, uint256 msgValue, bool isFirst) internal {
		Proposal storage p = proposals[id];
		if (!p.exists) revert ProposalNotFound();
		if (p.executed) revert ProposalAlreadyExecuted();

		// Only the first submitter can attach ETH; confirmations must not.
		if (!isFirst) {
			if (msgValue != 0) revert ValueMismatch();
		}

		if (approved[id][msg.sender]) revert AlreadyApproved();
		approved[id][msg.sender] = true;
		p.confirmations += 1;

		emit ProposalConfirmed(id, msg.sender, p.confirmations);
	}

	function _tryExecute(bytes32 id) internal {
		Proposal storage p = proposals[id];
		if (!p.exists) revert ProposalNotFound();
		if (p.executed) revert ProposalAlreadyExecuted();
		if (p.confirmations < threshold) return;
		if (block.timestamp < p.submitTime + delay) revert TooEarly();

		p.executed = true; // effects first
		(bool ok, bytes memory ret) = p.target.call{ value: p.value }(p.data);
		if (!ok) revert ExecutionFailed();
		emit ProposalExecuted(id, p.target, p.value, p.data, ret);
	}

	function _initSigners(address[] memory _signers) internal {
		require(_signers.length > 0, "NO_SIGNERS");
		for (uint256 i; i < _signers.length; ++i) {
			address s = _signers[i];
			if (s == address(0)) revert InvalidSigner();
			if (isSigner[s]) revert AlreadySigner();
			isSigner[s] = true;
			signers.push(s);
			signerIndex[s] = i + 1;
			emit SignerAdded(s);
		}
	}

	function _addSigner(address newSigner) internal {
		if (newSigner == address(0)) revert InvalidSigner();
		if (isSigner[newSigner]) revert AlreadySigner();
		signers.push(newSigner);
		isSigner[newSigner] = true;
		signerIndex[newSigner] = signers.length;
		// Maintain validity if threshold > signers.length prevented by selfChangeThreshold check
		emit SignerAdded(newSigner);
	}

	function _removeSigner(address signer) internal {
		if (!isSigner[signer]) revert InvalidSigner();
		uint256 idx = signerIndex[signer];
		uint256 last = signers.length;
		if (idx != last) {
			address tail = signers[last - 1];
			signers[idx - 1] = tail;
			signerIndex[tail] = idx;
		}
		signers.pop();
		delete isSigner[signer];
		delete signerIndex[signer];
		// Ensure threshold remains valid via selfChangeThreshold before/after as needed
		emit SignerRemoved(signer);
	}
}