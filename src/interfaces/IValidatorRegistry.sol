// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IValidatorRegistry {

    /// @dev Represents commission details, represented as 18 decimals.
    /// @param rate The current commission rate.
    /// @param maxRate The maximum allowable commission rate.
    /// @param maxChangeRate The maximum rate at which the commission rate can change.
    /// All rates must be less than or equal to 1e18.
    /// For example, a 10% commission rate would be represented as 1e17.
    /// rate must not exceed maxRate, and maxChangeRate must not exceed maxRate.
    struct Commission {
        uint256 rate;
        uint256 maxRate;
        uint256 maxChangeRate;
    }

    /// @dev Represents a validator in the system, including their name, commission,
    /// and consensus public key.
    /// @param name The name (meta info) for the validator.
    /// @param commission The commission for the validator.
    /// @param consensusPublicKey The public key used by the validator for consensus
    /// on Imuachain.
    struct Validator {
        string name;
        Commission commission;
        bytes32 consensusPublicKey;
    }

    /// @notice Registers a new validator in the registry with the provided details.
    /// @dev The set of validators is a subset of operators; the validators represent the subset of operators that
    /// intend to validate blocks on the Imuachain.
    /// @param validatorAddress The Imuachain address of the operator (corresponding to the validator) as a string.
    /// @param name The human-readable name of the operator (corresponding to the validator).
    /// @param commission A `Commission` struct containing the commission details for this operator (corresponding to
    /// the validator).
    /// @param consensusPublicKey The public key used for consensus operations, provided as a bytes32.
    function registerValidator(
        string calldata validatorAddress,
        string calldata name,
        Commission memory commission,
        bytes32 consensusPublicKey
    ) external;

    /// @dev Updates the consensus public key for the validator corresponding to `msg.sender`.
    /// @param newKey The new public key to use for consensus operations.
    function replaceKey(bytes32 newKey) external;

    /// @notice Updates the commission rate for the calling validator.
    /// @dev Can only be called by a registered validator. The function checks if the operation
    /// is allowed and not paused. Throws if the validator is not registered or the new rate
    /// exceeds the maximum allowed rate.
    /// @param newRate The new commission rate to be set for the calling validator.
    /// Must not exceed the validator's maximum rate.
    function updateRate(uint256 newRate) external;

    /// @dev Emitted when a new validator is registered in the contract.
    /// @param ethAddress The Ethereum address of the validator.
    /// @param validatorAddress The Imuachain address of the validator.
    /// @param name The human-readable name of the validator.
    /// @param commission The commission details for the validator.
    /// @param consensusPublicKey The public key used for consensus operations.
    event ValidatorRegistered(
        address ethAddress,
        string validatorAddress,
        string name,
        IValidatorRegistry.Commission commission,
        bytes32 consensusPublicKey
    );

    /// @dev Emitted when a validator's consensus key is updated.
    /// @param validatorAddress The Imuachain address of the validator.
    /// @param newConsensusPublicKey The new consensus key for the validator.
    event ValidatorKeyReplaced(string validatorAddress, bytes32 newConsensusPublicKey);

    /// @dev Emitted when a validator's commission rate is updated.
    /// @param newRate The new commission rate for the validator.
    event ValidatorCommissionUpdated(uint256 newRate);

}
