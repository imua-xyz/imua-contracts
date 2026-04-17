// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title BridgeVerifier
/// @author imua-xyz
/// @notice Verifies ECDSA multi-signatures from the imuachain validator set
///         and delivers verified outbound messages to the ClientChainGateway.
/// @dev Uses the Gravity Bridge pattern: validators sign checkpoints with their
///      secp256k1 keys (same as their operator account keys), and this contract
///      verifies that 2/3+ of total power has signed before executing messages.
contract BridgeVerifier is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    /// @notice Domain identifier for this bridge family (shared across deployments in the same validator set).
    uint256 public constant BRIDGE_ID = 1;

    /// @notice Destination chain ID this verifier instance is pinned to. Set at initialization.
    uint256 public expectedDstChainID;

    /// @notice Current validator set nonce (incremented on each valset update).
    uint256 public currentValsetNonce;

    /// @notice Total voting power of the current validator set.
    uint256 public totalPower;

    /// @notice Last successfully processed checkpoint nonce per destination chain.
    mapping(uint256 => uint256) public lastCheckpointNonce;

    /// @notice Validator address => voting power. Zero means not a validator.
    mapping(address => uint256) public validatorPower;

    /// @notice Ordered list of current validator addresses.
    address[] public validators;

    /// @notice The ClientChainGateway that receives delivered messages.
    address public gateway;

    /// @dev Storage gap for future upgrades.
    uint256[39] private __gap;

    event CheckpointExecuted(uint256 indexed dstChainID, uint256 indexed checkpointNonce, uint256 messageCount);
    event ValidatorSetUpdated(uint256 indexed newNonce, uint256 validatorCount, uint256 totalPower);
    event MessageDelivered(uint256 indexed dstChainID, uint256 indexed checkpointNonce, uint256 msgIndex);
    event MessageDeliveryFailed(uint256 indexed dstChainID, uint256 indexed checkpointNonce, uint256 msgIndex);

    error InsufficientSigningPower(uint256 signedPower, uint256 required);
    error InvalidCheckpointNonce(uint256 expected, uint256 got);
    error InvalidValsetNonce(uint256 expected, uint256 got);
    error SignatureMismatch(address expected, address recovered);
    error InvalidSignatureLength();
    error DuplicateSigner(address signer);
    error NotAValidator(address signer);
    error ZeroAddress();
    error MessagesHashMismatch();
    error InvalidDstChainID(uint256 expected, uint256 got);
    error EmptyValidatorSet();
    error LengthMismatch();
    error ZeroPower();
    error UnsortedValidators(address prev, address curr);

    /// @notice Initializes the contract with the initial validator set.
    /// @param owner_ The contract owner.
    /// @param gateway_ The ClientChainGateway address.
    /// @param expectedDstChainID_ The destination chain ID this verifier is pinned to.
    /// @param initialValidators The initial validator addresses, strictly sorted ascending.
    /// @param initialPowers The initial validator powers, aligned with initialValidators.
    function initialize(
        address owner_,
        address gateway_,
        uint256 expectedDstChainID_,
        address[] calldata initialValidators,
        uint256[] calldata initialPowers
    ) external initializer {
        if (gateway_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (expectedDstChainID_ == 0) revert InvalidDstChainID(0, 0);

        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        _transferOwnership(owner_);

        gateway = gateway_;
        expectedDstChainID = expectedDstChainID_;

        uint256 total = _validateAndIngestValset(initialValidators, initialPowers);
        totalPower = total;
        currentValsetNonce = 1;

        emit ValidatorSetUpdated(1, initialValidators.length, total);
    }

    /// @dev Validates a validator set and writes it to storage. Requires strictly ascending
    ///      addresses (giving free uniqueness/nonzero checks) and non-zero powers.
    function _validateAndIngestValset(address[] calldata vals, uint256[] calldata powers)
        internal
        returns (uint256 total)
    {
        uint256 n = vals.length;
        if (n == 0) revert EmptyValidatorSet();
        if (powers.length != n) revert LengthMismatch();

        address prev;
        for (uint256 i = 0; i < n; i++) {
            address v = vals[i];
            if (v == address(0)) revert ZeroAddress();
            if (i > 0 && v <= prev) revert UnsortedValidators(prev, v);
            if (powers[i] == 0) revert ZeroPower();
            validators.push(v);
            validatorPower[v] = powers[i];
            total += powers[i];
            prev = v;
        }
    }

    /// @notice Verifies a checkpoint signed by 2/3+ validators and delivers messages to the gateway.
    /// @param checkpointNonce The sequential checkpoint nonce.
    /// @param dstChainID The destination chain ID (should match this chain).
    /// @param messagesHash The keccak256 hash of the encoded messages.
    /// @param messages The individual outbound message payloads.
    /// @param signers The addresses of validators who signed (must match signature order).
    /// @param v ECDSA v values.
    /// @param r ECDSA r values.
    /// @param s ECDSA s values.
    function verifyAndDeliver(
        uint256 checkpointNonce,
        uint256 dstChainID,
        bytes32 messagesHash,
        bytes[] calldata messages,
        address[] calldata signers,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external whenNotPaused nonReentrant {
        if (dstChainID != expectedDstChainID) {
            revert InvalidDstChainID(expectedDstChainID, dstChainID);
        }
        uint256 expected = lastCheckpointNonce[dstChainID] + 1;
        if (checkpointNonce != expected) {
            revert InvalidCheckpointNonce(expected, checkpointNonce);
        }
        if (signers.length != v.length || signers.length != r.length || signers.length != s.length) {
            revert InvalidSignatureLength();
        }
        // Bind the signed messagesHash to the actual messages being executed.
        if (keccak256(abi.encode(messages)) != messagesHash) {
            revert MessagesHashMismatch();
        }

        // Reconstruct and verify checkpoint hash with 2/3+ power
        _verifySigs(
            _toEthSignedMessageHash(keccak256(abi.encode(BRIDGE_ID, checkpointNonce, dstChainID, messagesHash))),
            signers, v, r, s
        );

        // Deliver and finalize
        _deliverMessages(dstChainID, checkpointNonce, messages);
        lastCheckpointNonce[dstChainID] = checkpointNonce;
    }

    /// @dev Delivers messages to the gateway and emits events.
    function _deliverMessages(uint256 dstChainID, uint256 checkpointNonce, bytes[] calldata messages) internal {
        for (uint256 i = 0; i < messages.length; i++) {
            try IBridgeGateway(gateway).oracleDeliver(messages[i]) {
                emit MessageDelivered(dstChainID, checkpointNonce, i);
            } catch {
                emit MessageDeliveryFailed(dstChainID, checkpointNonce, i);
            }
        }
        emit CheckpointExecuted(dstChainID, checkpointNonce, messages.length);
    }

    /// @notice Updates the validator set. Must be signed by 2/3+ of the CURRENT set.
    /// @param newNonce The new valset nonce (must be currentValsetNonce + 1).
    /// @param newValidators The new validator addresses.
    /// @param newPowers The new validator powers.
    /// @param signers Current validators who signed this update.
    /// @param v ECDSA v values.
    /// @param r ECDSA r values.
    /// @param s ECDSA s values.
    function updateValidatorSet(
        uint256 newNonce,
        address[] calldata newValidators,
        uint256[] calldata newPowers,
        address[] calldata signers,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external whenNotPaused nonReentrant {
        if (newNonce != currentValsetNonce + 1) {
            revert InvalidValsetNonce(currentValsetNonce + 1, newNonce);
        }

        // Hash the new validator set and verify current set signed it
        _verifySigs(_toEthSignedMessageHash(_hashValset(newNonce, newValidators, newPowers)), signers, v, r, s);

        // Apply the update
        _applyValsetUpdate(newNonce, newValidators, newPowers);
    }

    /// @dev Applies a validated validator set update to storage.
    function _applyValsetUpdate(uint256 newNonce, address[] calldata newValidators, uint256[] calldata newPowers) internal {
        // Clear old
        for (uint256 i = 0; i < validators.length; i++) {
            delete validatorPower[validators[i]];
        }
        delete validators;

        // Validate and ingest the new set
        uint256 newTotal = _validateAndIngestValset(newValidators, newPowers);
        totalPower = newTotal;
        currentValsetNonce = newNonce;

        emit ValidatorSetUpdated(newNonce, newValidators.length, newTotal);
    }

    /// @dev Hashes a validator set for signing. Requires equal-length inputs.
    function _hashValset(uint256 nonce, address[] calldata vals, uint256[] calldata powers) internal pure returns (bytes32) {
        if (vals.length != powers.length) revert LengthMismatch();
        bytes memory valsetData = abi.encode(BRIDGE_ID, nonce);
        for (uint256 i = 0; i < vals.length; i++) {
            valsetData = abi.encodePacked(valsetData, vals[i], powers[i]);
        }
        return keccak256(valsetData);
    }

    /// @dev Verifies that 2/3+ of total power signed the given hash.
    /// @dev Signers MUST be sorted in strictly ascending address order (O(N) duplicate check).
    function _verifySigs(
        bytes32 ethSignedHash,
        address[] calldata signers,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) internal view {
        uint256 signedPower;
        address prevSigner;
        for (uint256 i = 0; i < signers.length; i++) {
            // O(N) uniqueness: require strictly ascending signer addresses.
            if (i > 0 && signers[i] <= prevSigner) {
                revert DuplicateSigner(signers[i]);
            }
            prevSigner = signers[i];

            address recovered = ecrecover(ethSignedHash, v[i], r[i], s[i]);
            if (recovered != signers[i]) {
                revert SignatureMismatch(signers[i], recovered);
            }
            uint256 power = validatorPower[recovered];
            if (power == 0) {
                revert NotAValidator(recovered);
            }
            signedPower += power;
        }
        uint256 required = (totalPower * 2) / 3 + 1;
        if (signedPower < required) {
            revert InsufficientSigningPower(signedPower, required);
        }
    }

    /// @notice Returns the number of validators.
    function validatorCount() external view returns (uint256) {
        return validators.length;
    }

    /// @notice Pauses the contract. Only owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract. Only owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Updates the gateway address. Only owner.
    function setGateway(address gateway_) external onlyOwner {
        if (gateway_ == address(0)) revert ZeroAddress();
        gateway = gateway_;
    }

    /// @dev Wraps a hash in the Ethereum signed message format.
    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}

/// @dev Minimal interface for the gateway's oracleDeliver function.
interface IBridgeGateway {
    function oracleDeliver(bytes calldata message) external;
}
