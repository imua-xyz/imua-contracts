// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IImuaCapsule} from "../interfaces/IImuaCapsule.sol";

import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";
import {Endian} from "../libraries/Endian.sol";
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
         * withdrawal_credentials[:1] == ETH1_ADDRESS_WITHDRAWAL_PREFIX
         * withdrawal_credentials[1:12] == b'\x00' * 11
         * withdrawal_credentials[12:] == eth1_withdrawal_address
         */
        return abi.encodePacked(bytes1(uint8(1)), bytes11(0), address(this));
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
            proof.stateRootProof
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

}
