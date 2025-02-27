// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IBaseRestakingController
/// @author imua-xyz
/// @notice The IBaseRestakingController interface provides a set of functions for staker operations.
interface IBaseRestakingController {

    /// @notice Delegates a specified amount of tokens to a given operator.
    /// @param operator The address of the operator to delegate tokens to.
    /// @param token The address of the token to be delegated.
    /// @param amount The amount of tokens to delegate.
    function delegateTo(string calldata operator, address token, uint256 amount) external payable;

    /// @notice Undelegates a specified amount of tokens from a given operator.
    /// @param operator The address of the operator to undelegate tokens from.
    /// @param token The address of the token to be undelegated.
    /// @param amount The amount of tokens to undelegate.
    function undelegateFrom(string calldata operator, address token, uint256 amount) external payable;

    /// @notice Client chain users call to withdraw their unlocked assets from the vault.
    /// @dev This function assumes that the withdrawable assets should have been unlocked before calling this.
    /// @dev This function does not interact with Imuachain.
    /// @param token The address of specific token that the user wants to claim from the vault.
    /// @param amount The amount of @param token that the user wants to claim from the vault.
    /// @param recipient The destination address that the assets would be transfered to.
    function withdrawPrincipal(address token, uint256 amount, address recipient) external;

    /// @notice Submits reward to the reward module on behalf of the AVS
    /// @param token The address of the specific token that the user wants to submit as a reward.
    /// @param avs The address of the AVS that the user wants to submit the reward to.
    /// @param rewardAmount The amount of reward tokens that the user wants to submit.
    function submitReward(address token, address avs, uint256 rewardAmount) external payable;

    /// @notice Claims reward tokens from Imuachain.
    /// @param token The address of the specific token that the user wants to claim as a reward.
    /// @param rewardAmount The amount of reward tokens that the user wants to claim.
    function claimRewardFromImuachain(address token, uint256 rewardAmount) external payable;

    /// @notice Withdraws reward tokens from vault to the recipient.
    /// @param token The address of the specific token that the user wants to withdraw as a reward.
    /// @param recipient The address of the recipient of the reward tokens.
    /// @param rewardAmount The amount of reward tokens that the user wants to withdraw.
    function withdrawReward(address token, address recipient, uint256 rewardAmount) external;

}
