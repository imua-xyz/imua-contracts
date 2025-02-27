// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBaseRestakingController} from "./IBaseRestakingController.sol";

/// @title ILSTRestakingController
/// @author imua-xyz
/// @notice Interface for the LSTRestakingController contract. It offers functions to deposit, withdraw principal,
/// withdraw rewards, and deposit + delegate.
/// @dev Provides methods for interacting with Imuachain, including depositing tokens, withdrawing principal
/// and rewards, and delegating tokens to node operators.
interface ILSTRestakingController is IBaseRestakingController {

    /// @notice Deposits tokens into Imua for further operations like delegation and staking.
    /// @dev This function locks the specified amount of tokens into a vault and forwards the information to Imuachain
    /// @dev Deposit is always considered successful on Imuachain
    /// @param token The address of the specific token that the user wants to deposit.
    /// @param amount The amount of the token that the user wants to deposit.
    function deposit(address token, uint256 amount) external payable;

    /// @notice Send request to Imuachain to claim the LST principal.
    /// @dev This function requests claim approval from Imuachain. If approved, the assets are
    /// unlocked and can be withdrawn by the user. Otherwise, they remain locked.
    /// @param token The address of the specific token that the user wants to claim from Imuachain.
    /// @param principalAmount The principal amount of assets the user deposited into Imuachain for delegation and
    /// staking.
    function claimPrincipalFromImuachain(address token, uint256 principalAmount) external payable;

    /// @notice Deposits tokens and then delegates them to a specific node operator.
    /// @dev This function locks the specified amount of tokens into a vault, informs Imuachain, and
    /// delegates the tokens to the specified node operator.
    /// Delegation can fail if the node operator is not registered in Imuachain.
    /// @param token The address of the specific token that the user wants to deposit and delegate.
    /// @param amount The amount of the token that the user wants to deposit and delegate.
    /// @param operator The address of a registered node operator that the user wants to delegate to.
    function depositThenDelegateTo(address token, uint256 amount, string calldata operator) external payable;

}
