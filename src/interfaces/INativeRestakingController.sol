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

    /// @notice Send request to Imuachain to claim the NST principal.
    /// @notice This would not result in ETH transfer even if result is successful because it only unlocks the NST.
    /// @dev This function requests claim approval from Imuachain. If approved, the assets are
    /// unlocked and can be withdrawn by the user. Otherwise, they remain locked.
    /// @param claimAmount The amount of NST the user intends to claim, cannot be greater than the
    /// staker's capsule's balance and staker's staking position's withdrawable balance.
    function claimNSTFromImuachain(uint256 claimAmount) external payable;

}
