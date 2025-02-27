// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILSTRestakingController} from "../interfaces/ILSTRestakingController.sol";

import {IVault} from "../interfaces/IVault.sol";

import {Action} from "../storage/GatewayStorage.sol";
import {BaseRestakingController} from "./BaseRestakingController.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title LSTRestakingController
/// @author imua-xyz
/// @notice Implementation of ILSTRestakingController, used to restake tokens.
abstract contract LSTRestakingController is
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ILSTRestakingController,
    BaseRestakingController
{

    /// @inheritdoc ILSTRestakingController
    function deposit(address token, uint256 amount)
        external
        payable
        isTokenWhitelisted(token)
        isValidAmount(amount)
        whenNotPaused
        nonReentrant
    {
        IVault vault = _getVault(token);
        vault.deposit(msg.sender, amount);

        bytes memory actionArgs = abi.encodePacked(bytes32(bytes20(msg.sender)), amount, bytes32(bytes20(token)));

        // deposit is supposed to be a must-succeed action, so we don't need to check the response
        _processRequest(Action.REQUEST_DEPOSIT_LST, actionArgs, bytes(""));
    }

    /// @inheritdoc ILSTRestakingController
    function claimPrincipalFromImuachain(address token, uint256 principalAmount)
        external
        payable
        isTokenWhitelisted(token)
        isValidAmount(principalAmount)
        whenNotPaused
        nonReentrant
    {
        // If we can get the vault, the token cannot be VIRTUAL_STAKED_ETH_ADDRESS, so that staker cannot bypass the
        // beacon chain merkle proof check to withdraw natively staked ETH
        _getVault(token);

        bytes memory actionArgs =
            abi.encodePacked(bytes32(bytes20(msg.sender)), principalAmount, bytes32(bytes20(token)));
        bytes memory encodedRequest = abi.encode(token, msg.sender, principalAmount);

        // we need to check the response to unlock the principal for later claim
        _processRequest(Action.REQUEST_WITHDRAW_LST, actionArgs, encodedRequest);
    }

    /// @inheritdoc ILSTRestakingController
    function depositThenDelegateTo(address token, uint256 amount, string calldata operator)
        external
        payable
        override
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(operator)
        whenNotPaused
        nonReentrant
    {
        IVault vault = _getVault(token);
        vault.deposit(msg.sender, amount);

        bytes memory actionArgs =
            abi.encodePacked(bytes32(bytes20(msg.sender)), amount, bytes32(bytes20(token)), bytes(operator));

        // deposit is supposed to be a must-succeed action and delegate does no need response, so we don't need to check
        // the response
        _processRequest(Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO, actionArgs, bytes(""));
    }

}
