// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";

/// @title ImuaCapsule interface
/// @author imua-xyz
/// @notice ImuaCapsule is the interface for the ImuaCapsule contract. It provides a set of functions for ImuaCapsule
/// operations. It is a contract used for native restaking.
interface IImuaCapsule {

    /// @notice Initializes the ImuaCapsule contract with the given parameters.
    /// @param gateway The address of the ClientChainGateway contract.
    /// @param capsuleOwner The payable address of the ImuaCapsule owner.
    /// @param beaconOracle The address of the BeaconOracle contract.
    function initialize(address gateway, address payable capsuleOwner, address beaconOracle) external;

    /// @notice Verifies the deposit proof and returns the amount of deposit.
    /// @param validatorContainer The validator container.
    /// @param proof The validator container proof.
    /// @return The amount of deposit.
    /// @dev The container must not have been previously registered, must not be stale,
    /// must be activated at a previous epoch, must have the correct withdrawal credentials,
    /// and must have a valid container root.
    function verifyDepositProof(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata proof
    ) external returns (uint256);

    /// @notice Verifies the withdrawal proof and returns the partial withdrawal status and the withdrawal amount.
    /// @param validatorContainer The validator container.
    /// @param validatorProof The validator container proof.
    /// @param withdrawalContainer The withdrawal container.
    /// @param withdrawalProof The withdrawal proof.
    /// @return partialWithdrawal Whether the withdrawal is partial (rewards only).
    /// @return withdrawalAmount The amount of withdrawal.
    /// @dev The validator must have registered previously and not withdrawn yet, the proof must not
    /// have been used before, the state root of both the proofs must match, the roots must be valid.
    /// The withdrawal is considered partial if the epoch in the withdrawal proof is less than the
    /// withdrawable epoch of the validator.
    function verifyWithdrawalProof(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata validatorProof,
        bytes32[] calldata withdrawalContainer,
        BeaconChainProofs.WithdrawalProof calldata withdrawalProof
    ) external returns (bool partialWithdrawal, uint256 withdrawalAmount);

    /// @notice Allows the owner to withdraw the specified unlocked staked ETH to the recipient.
    /// @dev The amount must be available in the withdrawable balance.
    /// @param amount The amount to withdraw.
    /// @param recipient The recipient address.
    function withdraw(uint256 amount, address payable recipient) external;

    /// @notice Withdraws the nonBeaconChainETHBalance
    /// @param recipient The payable destination address to which the ETH are sent.
    /// @param amountToWithdraw The amount to withdraw.
    function withdrawNonBeaconChainETHBalance(address payable recipient, uint256 amountToWithdraw) external;

    /// @notice Unlock and increase the withdrawable balance of the ImuaCapsule for later withdrawal.
    /// @param amount The amount of the ETH balance unlocked.
    function unlockETHPrincipal(uint256 amount) external;

    /// @notice Returns the withdrawal credentials of the ImuaCapsule.
    /// @return The withdrawal credentials.
    /// @dev Returns '0x1' + '0x0' * 11 + 'address' of capsule.
    function capsuleWithdrawalCredentials() external view returns (bytes memory);

}
