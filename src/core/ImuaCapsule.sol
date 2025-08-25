// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IImuaCapsule} from "../interfaces/IImuaCapsule.sol";

import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";
import {Endian} from "../libraries/Endian.sol";

import {PectraConstants} from "../libraries/PectraConstants.sol";
import {ValidatorContainer} from "../libraries/ValidatorContainer.sol";
import {ImuaCapsuleStorage} from "../storage/ImuaCapsuleStorage.sol";

import {Errors} from "../libraries/Errors.sol";
import {IBeaconChainOracle} from "@beacon-oracle/contracts/src/IBeaconChainOracle.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
/// @title ImuaCapsule
/// @author imua-xyz
/// @notice The ImuaCapsule contract is used to stake, deposit and withdraw from the Imuachain beacon chain.

contract ImuaCapsule is ReentrancyGuardUpgradeable, ImuaCapsuleStorage, IImuaCapsule {

    using BeaconChainProofs for bytes32;
    using Endian for bytes32;
    using ValidatorContainer for bytes32[];

    /// @notice Emitted when the ETH principal balance is unlocked.
    /// @param owner The address of the capsule owner.
    /// @param unlockedAmount The amount added to the withdrawable balance.
    event ETHPrincipalUnlocked(address owner, uint256 unlockedAmount);

    /// @notice Emitted when a withdrawal is successfully completed.
    /// @param owner The address of the capsule owner.
    /// @param recipient The address of the recipient of the withdrawal.
    /// @param amount The amount withdrawn.
    event WithdrawalSuccess(address owner, address recipient, uint256 amount);

    /// @notice Emitted when a NST claim is started.
    event NSTClaimStarted();

    /// @notice Emitted when a NST claim is ended.
    event NSTClaimEnded();

    /// @notice Emitted when capsuleOwner enables restaking
    /// @param capsuleOwner The address of the capsule owner.
    event RestakingActivated(address indexed capsuleOwner);

    /// @notice Emitted when a partial withdrawal is successfully requested for a Type 2 validator
    /// @param pubkey The validator's BLS public key
    /// @param amount The amount requested for withdrawal (in wei)
    /// @param capsuleOwner The address of the capsule owner
    event PartialWithdrawalRequested(bytes indexed pubkey, uint256 amount, address indexed capsuleOwner);

    /// @notice Emitted when a full withdrawal is successfully requested for a Type 2 validator
    /// @param pubkey The validator's BLS public key
    /// @param capsuleOwner The address of the capsule owner
    event FullWithdrawalRequested(bytes indexed pubkey, address indexed capsuleOwner);

    /// @notice Emitted when a beacon withdrawal request fails
    /// @param pubkey The validator's BLS public key
    /// @param amount The amount that failed to be withdrawn
    /// @param reason The reason for the failure
    event BeaconWithdrawalRequestFailed(bytes indexed pubkey, uint256 amount, string reason);

    /// @notice Emitted when excess withdrawal fee is refunded to withdrawable balance
    /// @param capsuleOwner The address of the capsule owner
    /// @param excessFee The amount of excess fee refunded
    event ExcessWithdrawalFeeRefunded(address indexed capsuleOwner, uint256 excessFee);

    /// @dev Thrown when the validator container is invalid.
    /// @param pubkeyHash The validator's BLS12-381 public key hash.
    error InvalidValidatorContainer(bytes32 pubkeyHash);

    /// @dev Thrown when a validator is double deposited.
    /// @param pubkeyHash The validator's BLS12-381 public key hash.
    error DoubleDepositedValidator(bytes32 pubkeyHash);

    /// @dev Thrown when a validator container is stale.
    /// @param pubkeyHash The validator's BLS12-381 public key hash.
    /// @param timestamp The timestamp of the validator proof.
    error StaleValidatorContainer(bytes32 pubkeyHash, uint256 timestamp);

    /// @dev Thrown when a validator container is unregistered.
    /// @param pubkeyHash The validator's BLS12-381 public key hash.
    error UnregisteredValidator(bytes32 pubkeyHash);

    /// @dev Thrown when the beacon chain oracle does not have the root at the given timestamp.
    /// @param oracle The address of the beacon chain oracle.
    /// @param timestamp The timestamp for which the root is not available.
    error BeaconChainOracleNotUpdatedAtTime(address oracle, uint256 timestamp);

    /// @dev Thrown when sending ETH to @param recipient fails.
    /// @param withdrawer The address of the withdrawer.
    /// @param recipient The address of the recipient.
    /// @param amount The amount of ETH withdrawn.
    error WithdrawalFailure(address withdrawer, address recipient, uint256 amount);

    /// @dev Thrown when the validator's withdrawal credentials differ from the expected credentials.
    error WithdrawalCredentialsNotMatch();

    /// @dev Thrown when the caller of a message is not the gateway
    /// @param gateway The address of the gateway.
    /// @param caller The address of the caller.
    error InvalidCaller(address gateway, address caller);

    /// @dev Thrown when trying to use beacon withdrawal functionality in pre-Pectra mode
    error BeaconWithdrawalNotSupportedInPrePectraMode();

    /// @dev Thrown when an invalid withdrawal amount is provided
    /// @param amount The invalid amount
    error InvalidWithdrawalAmount(uint256 amount);

    /// @dev Thrown when an invalid validator public key is provided
    /// @param pubkey The invalid public key
    error InvalidValidatorPubkey(bytes pubkey);

    /// @dev Thrown when the beacon withdrawal precompile call fails
    /// @param pubkey The validator's public key
    /// @param amount The withdrawal amount
    error BeaconWithdrawalPrecompileFailed(bytes pubkey, uint256 amount);

    /// @dev Thrown when insufficient fee is provided for withdrawal request
    /// @param provided The provided fee amount
    /// @param required The required fee amount
    error InsufficientFee(uint256 provided, uint256 required);

    /// @dev Ensures that the caller is the gateway.
    modifier onlyGateway() {
        if (msg.sender != address(gateway)) {
            revert InvalidCaller(address(gateway), msg.sender);
        }
        _;
    }

    /// @notice Constructor to create the ImuaCapsule contract.
    /// @param networkConfig_ network configuration contract address.
    constructor(address networkConfig_) ImuaCapsuleStorage(networkConfig_) {
        _disableInitializers();
    }

    /// @inheritdoc IImuaCapsule
    function initialize(address gateway_, address payable capsuleOwner_, address beaconOracle_) external initializer {
        require(gateway_ != address(0), "ImuaCapsule: gateway address can not be empty");
        require(capsuleOwner_ != address(0), "ImuaCapsule: capsule owner address can not be empty");
        require(beaconOracle_ != address(0), "ImuaCapsule: beacon chain oracle address should not be empty");

        gateway = INativeRestakingController(gateway_);
        beaconOracle = IBeaconChainOracle(beaconOracle_);
        capsuleOwner = capsuleOwner_;

        // This is a storage variable. The capsule's mode is determined when it is created.
        // The mode defines how much balance a capsule can store: either exactly 32 ETH, or
        // in the range of [32 ETH, 2048 ETH].
        isPectra = block.timestamp >= getPectraHardForkTimestamp();

        __ReentrancyGuard_init_unchained();

        emit RestakingActivated(capsuleOwner);
    }

    /// @inheritdoc IImuaCapsule
    function verifyDepositProof(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata proof
    ) external onlyGateway returns (uint256 depositAmount) {
        bytes32 validatorPubkeyHash = validatorContainer.getPubkeyHash();
        bytes32 withdrawalCredentials = validatorContainer.getWithdrawalCredentials();
        Validator storage validator = _capsuleValidators[validatorPubkeyHash];

        if (!validatorContainer.verifyValidatorContainerBasic()) {
            revert InvalidValidatorContainer(validatorPubkeyHash);
        }

        if (validator.status != VALIDATOR_STATUS.UNREGISTERED) {
            revert DoubleDepositedValidator(validatorPubkeyHash);
        }

        if (_isStaleProof(proof.beaconBlockTimestamp)) {
            revert StaleValidatorContainer(validatorPubkeyHash, proof.beaconBlockTimestamp);
        }

        if (withdrawalCredentials != bytes32(capsuleWithdrawalCredentials())) {
            revert WithdrawalCredentialsNotMatch();
        }

        _verifyValidatorContainer(validatorContainer, proof);

        validator.status = VALIDATOR_STATUS.REGISTERED;
        validator.validatorIndex = proof.validatorIndex;
        uint64 depositAmountGwei = validatorContainer.getEffectiveBalance();
        if (depositAmountGwei > AFTER_PECTRA_MAX_EFFECTIVE_BALANCE_GWEI_PER_VALIDATOR) {
            depositAmount = AFTER_PECTRA_MAX_EFFECTIVE_BALANCE_GWEI_PER_VALIDATOR * GWEI_TO_WEI;
        } else {
            depositAmount = depositAmountGwei * GWEI_TO_WEI;
        }

        _capsuleValidatorsByIndex[proof.validatorIndex] = validatorPubkeyHash;
    }

    /// @inheritdoc IImuaCapsule
    function startClaimNST(uint256 amount) external onlyGateway {
        if (inClaimProgress) {
            revert Errors.ClaimAlreadyInProgress();
        }
        if (amount > address(this).balance - withdrawableBalance) {
            revert Errors.InsufficientBalance();
        }
        if (block.timestamp < lastClaimTimestamp + MIN_CLAIM_INTERVAL) {
            revert Errors.TooEarlySinceLastClaim();
        }
        inClaimProgress = true;

        emit NSTClaimStarted();
    }

    /// @inheritdoc IImuaCapsule
    function endClaimNST() external onlyGateway {
        inClaimProgress = false;

        emit NSTClaimEnded();
    }

    /// @inheritdoc IImuaCapsule
    function withdraw(uint256 amount, address payable recipient) external onlyGateway {
        require(recipient != address(0), "ImuaCapsule: recipient address cannot be zero or empty");
        require(amount > 0 && amount <= withdrawableBalance, "ImuaCapsule: invalid withdrawal amount");

        withdrawableBalance -= amount;
        _sendETH(recipient, amount);

        emit WithdrawalSuccess(capsuleOwner, recipient, amount);
    }

    /// @inheritdoc IImuaCapsule
    function unlockETHPrincipal(uint256 unlockPrincipalAmount) external onlyGateway {
        withdrawableBalance += unlockPrincipalAmount;
        lastClaimTimestamp = block.timestamp;

        emit ETHPrincipalUnlocked(capsuleOwner, unlockPrincipalAmount);
    }

    /// @inheritdoc IImuaCapsule
    function capsuleWithdrawalCredentials() public view returns (bytes memory) {
        /**
         * The withdrawal_credentials field must be such that:
         * withdrawal_credentials[:1] == 0x1 or 0x2 (if in Pectra mode)
         * withdrawal_credentials[1:12] == b'\x00' * 11
         * withdrawal_credentials[12:] == eth1_withdrawal_address
         */
        return abi.encodePacked(bytes1(uint8(isPectra ? 2 : 1)), bytes11(0), address(this));
    }

    /// @notice Gets the beacon block root at the provided timestamp.
    /// @param timestamp The timestamp for which the block root is requested.
    /// @return The block root at the given timestamp.
    function getBeaconBlockRoot(uint256 timestamp) public view returns (bytes32) {
        bytes32 root = beaconOracle.timestampToBlockRoot(timestamp);
        if (root == bytes32(0)) {
            revert BeaconChainOracleNotUpdatedAtTime(address(beaconOracle), timestamp);
        }

        return root;
    }

    /// @notice Gets the registered validator by pubkeyHash.
    /// @dev The validator status must be registered. Reverts if not.
    /// @param pubkeyHash The validator's BLS12-381 public key hash.
    /// @return The validator object, as defined in the `ImuaCapsuleStorage`.
    function getRegisteredValidatorByPubkey(bytes32 pubkeyHash) public view returns (Validator memory) {
        Validator memory validator = _capsuleValidators[pubkeyHash];
        if (validator.status == VALIDATOR_STATUS.UNREGISTERED) {
            revert UnregisteredValidator(pubkeyHash);
        }

        return validator;
    }

    /// @notice Gets the registered validator by index.
    /// @dev The validator status must be registered.
    /// @param index The index of the validator.
    /// @return The validator object, as defined in the `ImuaCapsuleStorage`.
    function getRegisteredValidatorByIndex(uint256 index) public view returns (Validator memory) {
        Validator memory validator = _capsuleValidators[_capsuleValidatorsByIndex[index]];
        if (validator.status == VALIDATOR_STATUS.UNREGISTERED) {
            revert UnregisteredValidator(_capsuleValidatorsByIndex[index]);
        }

        return validator;
    }

    /// @inheritdoc IImuaCapsule
    function isInClaimProgress() external view returns (bool) {
        return inClaimProgress;
    }

    /// @dev Sends @param amountWei of ETH to the @param recipient.
    /// @param recipient The address of the payable recipient.
    /// @param amountWei The amount of ETH to send, in wei.
    // slither-disable-next-line arbitrary-send-eth
    function _sendETH(address payable recipient, uint256 amountWei) internal nonReentrant {
        (bool sent,) = recipient.call{value: amountWei}("");
        if (!sent) {
            revert WithdrawalFailure(capsuleOwner, recipient, amountWei);
        }
    }

    /// @dev Verifies a validator container.
    /// @param validatorContainer The validator container to verify.
    /// @param proof The proof of the validator container.
    function _verifyValidatorContainer(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata proof
    ) internal view {
        bytes32 beaconBlockRoot = getBeaconBlockRoot(proof.beaconBlockTimestamp);
        bytes32 validatorContainerRoot = validatorContainer.merkleizeValidatorContainer();
        bool valid = validatorContainerRoot.isValidValidatorContainerRoot(
            proof.validatorContainerRootProof,
            proof.validatorIndex,
            beaconBlockRoot,
            proof.stateRoot,
            proof.stateRootProof,
            proof.beaconBlockTimestamp >= getPectraHardForkTimestamp()
        );
        if (!valid) {
            revert InvalidValidatorContainer(validatorContainer.getPubkeyHash());
        }
    }

    /// @dev Checks if the proof is stale (too old).
    /// @param proofTimestamp The timestamp of the proof.
    function _isStaleProof(uint256 proofTimestamp) internal view returns (bool) {
        return proofTimestamp + VERIFY_BALANCE_UPDATE_WINDOW_SECONDS < block.timestamp;
    }

    /// @inheritdoc IImuaCapsule
    function isPectraMode() external view returns (bool) {
        return isPectra;
    }

    /// @inheritdoc IImuaCapsule
    /// @dev Excess fees are refunded to withdrawable balance and can be withdrawn later.
    /// @dev Query getCurrentWithdrawalFee() before calling for optimal fee management.
    function requestPartialWithdrawal(bytes calldata pubkey, uint256 amount)
        external
        payable
        onlyGateway
        nonReentrant
    {
        // Validate input parameters
        if (!isPectra) {
            revert BeaconWithdrawalNotSupportedInPrePectraMode();
        }
        if (pubkey.length != PectraConstants.PUBKEY_LENGTH) {
            revert InvalidValidatorPubkey(pubkey);
        }
        if (amount == 0) {
            revert InvalidWithdrawalAmount(amount);
        }

        // Verify that the validator exists and is registered with this capsule
        bytes32 pubkeyHash = sha256(pubkey);
        Validator storage validator = _capsuleValidators[pubkeyHash];
        if (validator.status == VALIDATOR_STATUS.UNREGISTERED) {
            revert UnregisteredValidator(pubkeyHash);
        }

        // Check fee requirement (EIP-7002 requires minimum 1 wei)
        uint256 requiredFee = _getCurrentWithdrawalFee();
        if (msg.value < requiredFee) {
            revert InsufficientFee(msg.value, requiredFee);
        }

        // Call the beacon withdrawal precompile
        bool success = _callBeaconWithdrawalPrecompile(pubkey, amount);
        if (!success) {
            revert BeaconWithdrawalPrecompileFailed(pubkey, amount);
        }

        emit PartialWithdrawalRequested(pubkey, amount, capsuleOwner);
    }

    /// @inheritdoc IImuaCapsule
    /// @dev Excess fees are refunded to withdrawable balance and can be withdrawn later.
    /// @dev Query getCurrentWithdrawalFee() before calling for optimal fee management.
    function requestFullWithdrawal(bytes calldata pubkey) external payable onlyGateway nonReentrant {
        // Validate input parameters
        if (!isPectra) {
            revert BeaconWithdrawalNotSupportedInPrePectraMode();
        }
        if (pubkey.length != PectraConstants.PUBKEY_LENGTH) {
            revert InvalidValidatorPubkey(pubkey);
        }

        // Verify that the validator exists and is registered with this capsule
        bytes32 pubkeyHash = sha256(pubkey);
        Validator storage validator = _capsuleValidators[pubkeyHash];
        if (validator.status == VALIDATOR_STATUS.UNREGISTERED) {
            revert UnregisteredValidator(pubkeyHash);
        }

        // Check fee requirement (EIP-7002 requires minimum 1 wei)
        uint256 requiredFee = _getCurrentWithdrawalFee();
        if (msg.value < requiredFee) {
            revert InsufficientFee(msg.value, requiredFee);
        }

        // Call the beacon withdrawal precompile with amount = 0 for full withdrawal
        bool success = _callBeaconWithdrawalPrecompile(pubkey, 0);
        if (!success) {
            revert BeaconWithdrawalPrecompileFailed(pubkey, 0);
        }

        emit FullWithdrawalRequested(pubkey, capsuleOwner);
    }

    /**
     * @dev Internal function to call the beacon withdrawal precompile
     * @dev According to EIP-7002: input format is validator_pubkey (48 bytes) + amount (8 bytes)
     * @param pubkey The validator's BLS public key (48 bytes)
     * @param amount The amount to withdraw (0 for full withdrawal, uint64)
     * @return success Whether the precompile call was successful
     */
    function _callBeaconWithdrawalPrecompile(bytes calldata pubkey, uint256 amount) internal returns (bool) {
        // Ensure amount fits in uint64 (8 bytes)
        require(amount <= type(uint64).max, "ImuaCapsule: amount exceeds uint64 max");

        // Get exact fee to avoid overpayment (EIP-7002: overpaid fees are not returned)
        uint256 exactFee = _getCurrentWithdrawalFee();

        // Encode according to EIP-7002 specification
        bytes memory callData = abi.encodePacked(
            pubkey, // validator_pubkey (48 bytes)
            uint64(amount) // amount (8 bytes) - Solidity encodes as expected by precompile
        );

        // Call precompile with exact fee to prevent overpayment
        (bool success,) = PectraConstants.BEACON_WITHDRAWAL_PRECOMPILE.call{value: exactFee}(callData);

        // Refund any excess fee to withdrawable balance for user to withdraw later
        if (msg.value > exactFee) {
            uint256 excessFee = msg.value - exactFee;
            withdrawableBalance += excessFee;
            emit ExcessWithdrawalFeeRefunded(capsuleOwner, excessFee);
        }

        return success;
    }

    /// @inheritdoc IImuaCapsule
    function getCurrentWithdrawalFee() external view returns (uint256) {
        return _getCurrentWithdrawalFee();
    }

    /**
     * @dev Get current withdrawal fee from precompile
     * @dev NOTE: Fee is dynamic and can change rapidly due to network demand
     * @dev Callers should be aware that overpaid fees are not refunded by the precompile
     * @return fee Current fee in wei (minimum 1 wei per EIP-7002)
     */
    function _getCurrentWithdrawalFee() internal view returns (uint256 fee) {
        // According to EIP-7002, fee starts at 1 wei and increases dynamically
        // Try to query dynamic fee from precompile
        (bool success, bytes memory data) = PectraConstants.BEACON_WITHDRAWAL_PRECOMPILE.staticcall("");
        if (success) {
            fee = uint256(bytes32(data));
            if (fee < PectraConstants.MIN_WITHDRAWAL_FEE) {
                fee = PectraConstants.MIN_WITHDRAWAL_FEE;
            }
        } else {
            fee = PectraConstants.MIN_WITHDRAWAL_FEE; // Fallback to minimum fee
        }

        return fee;
    }

}
