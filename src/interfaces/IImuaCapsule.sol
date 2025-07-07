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

    /// @notice Starts a claim for the specified amount of NST.
    /// @dev This would set the inClaimProgress flag to true.
    /// @dev It checks: 1. the amount cannot be greater than capsule's balance - withdrawable balance(the accumulated
    /// amount of NST that has been claimed that has not been withdrawn).
    /// 2. the inClaimProgress flag cannot be true.
    /// 3. the time since the last successful NST claim is greater than the minimum claim interval.
    /// @param amount The amount of NST to claim.
    function startClaimNST(uint256 amount) external;

    /// @notice Ends a NST claim started by the startClaimNST function when receiving a response from imuachain.
    /// @dev This would set the inClaimProgress flag to false.
    function endClaimNST() external;

    /// @notice Allows the owner to withdraw the specified unlocked staked ETH to the recipient.
    /// @dev The amount must be available in the withdrawable balance.
    /// @param amount The amount to withdraw.
    /// @param recipient The recipient address.
    function withdraw(uint256 amount, address payable recipient) external;

    /// @notice Unlock and increase the withdrawable balance of the ImuaCapsule for later withdrawal.
    /// @dev This function is used to unlock the principal when receiving a response from imuachain indicating that a
    /// claim request is successful.
    /// @dev This also updates the lastClaimTimestamp.
    /// @param amount The amount of the ETH balance unlocked.
    function unlockETHPrincipal(uint256 amount) external;

    /// @notice Returns the withdrawal credentials of the ImuaCapsule.
    /// @return The withdrawal credentials.
    /// @dev Returns '0x1' + '0x0' * 11 + 'address' of capsule.
    function capsuleWithdrawalCredentials() external view returns (bytes memory);

    /// @notice Returns if the capsule is in a NST claim progress.
    /// @return True if the capsule is in a NST claim progress, false otherwise.
    function isInClaimProgress() external view returns (bool);

}
