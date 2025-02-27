// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";
import {IBaseRestakingController} from "./IBaseRestakingController.sol";

/// @title INativeRestakingController
/// @author imua-xyz
/// @notice Interface for the NativeRestakingController contract.
/// @dev Provides methods for interacting with the Ethereum beacon chain and Imuachain, including staking,
/// creating ImuaCapsules, and processing withdrawals.
interface INativeRestakingController is IBaseRestakingController {

    /// @notice Deposits to a beacon chain validator and sets withdrawal credentials to the staker's ImuaCapsule
    /// contract
    /// address.
    /// @dev If the ImuaCapsule contract does not exist, it will be created.
    /// @param pubkey The BLS pubkey of the beacon chain validator.
    /// @param signature The BLS signature.
    /// @param depositDataRoot The SHA-256 hash of the SSZ-encoded DepositData object, used as a protection against
    /// malformed input.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external payable;

    /// @notice Creates an ImuaCapsule owned by the Ethereum native restaker.
    /// @dev This should be done before staking to the beacon chain.
    /// @return capsule The address of the created ImuaCapsule.
    function createImuaCapsule() external returns (address capsule);

    /// @notice Deposits ETH staked on the Ethereum beacon chain to Imua for future restaking.
    /// @dev Before depositing, the staker should have created an ImuaCapsule and set the validator's withdrawal
    /// credentials to it.
    /// The effective balance of `validatorContainer` will be credited as the deposited value by the Imuachain.
    /// @param validatorContainer The data structure included in the `BeaconState` of `BeaconBlock` that contains beacon
    /// chain validator information.
    /// @param proof The proof needed to verify the validator container.
    function verifyAndDepositNativeStake(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata proof
    ) external payable;

    /// @notice Processes a partial withdrawal from the beacon chain to an ImuaCapsule contract.
    /// @dev This function is called with `validatorContainer`, `withdrawalContainer`, and corresponding proofs to prove
    /// the partial withdrawal.
    /// The withdrawn ETH will be unlocked and claimable for the ImuaCapsule owner.
    /// @param validatorContainer The data structure included in the `BeaconState` of `BeaconBlock` that contains beacon
    /// chain validator information.
    /// @param validatorProof The merkle proof needed to verify that `validatorContainer` is included in a beacon block
    /// root.
    /// @param withdrawalContainer The data structure included in the `ExecutionPayload` of `BeaconBlockBody` that
    /// contains withdrawals from the beacon chain to the execution layer.
    /// @param withdrawalProof The merkle proof needed to verify that `withdrawalContainer` is included in a beacon
    /// block root.
    function processBeaconChainWithdrawal(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata validatorProof,
        bytes32[] calldata withdrawalContainer,
        BeaconChainProofs.WithdrawalProof calldata withdrawalProof
    ) external payable;

    /// @notice Withdraws the nonBeaconChainETHBalance from the ImuaCapsule contract.
    /// @dev @param amountToWithdraw can not be greater than the available nonBeaconChainETHBalance.
    /// @param recipient The payable destination address to which the ETH are sent.
    /// @param amountToWithdraw The amount to withdraw.
    function withdrawNonBeaconChainETHFromCapsule(address payable recipient, uint256 amountToWithdraw) external;

}
