// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBaseRestakingController} from "../interfaces/IBaseRestakingController.sol";
import {IImuaCapsule} from "../interfaces/IImuaCapsule.sol";
import {IVault} from "../interfaces/IVault.sol";

import {Errors} from "../libraries/Errors.sol";
import {MessagingFee, MessagingReceipt, OAppSenderUpgradeable} from "../lzApp/OAppSenderUpgradeable.sol";
import {ClientChainGatewayStorage} from "../storage/ClientChainGatewayStorage.sol";
import {Action} from "../storage/GatewayStorage.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title BaseRestakingController
/// @author imua-xyz
/// @notice The base contract for the restaking controller. It only controls ERC20 tokens.
/// @dev This contract is abstract because it does not call the base contract's constructor. It is not used by
/// Bootstrap.
abstract contract BaseRestakingController is
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    OAppSenderUpgradeable,
    IBaseRestakingController,
    ClientChainGatewayStorage
{

    using OptionsBuilder for bytes;

    receive() external payable {}

    /// @inheritdoc IBaseRestakingController
    function withdrawPrincipal(address token, uint256 amount, address recipient)
        external
        isTokenWhitelisted(token)
        isValidAmount(amount)
        whenNotPaused
        nonReentrant
    {
        require(recipient != address(0), "BaseRestakingController: recipient address cannot be empty or zero address");
        if (token == VIRTUAL_NST_ADDRESS) {
            IImuaCapsule capsule = _getCapsule(msg.sender);
            capsule.withdraw(amount, payable(recipient));
        } else {
            IVault vault = _getVault(token);
            vault.withdraw(msg.sender, recipient, amount);
        }
    }

    /// @inheritdoc IBaseRestakingController
    function delegateTo(string calldata operator, address token, uint256 amount)
        external
        payable
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(operator)
        whenNotPaused
        nonReentrant
    {
        bytes memory actionArgs = abi.encodePacked(
            bytes32(bytes20(msg.sender)), amount, bytes32(bytes20(token)), bytes(operator)
        );
        _processRequest(Action.REQUEST_DELEGATE_TO, actionArgs, bytes(""));
    }

    /// @inheritdoc IBaseRestakingController
    function undelegateFrom(string calldata operator, address token, uint256 amount, bool instantUnbond)
        external
        payable
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(operator)
        whenNotPaused
        nonReentrant
    {
        bytes memory actionArgs = abi.encodePacked(
            bytes32(bytes20(msg.sender)), amount, bytes32(bytes20(token)), bytes(operator), instantUnbond
        );
        _processRequest(Action.REQUEST_UNDELEGATE_FROM, actionArgs, bytes(""));
    }

    /// @inheritdoc IBaseRestakingController
    function fundAVSReward(address token, address avs, uint256 rewardAmount)
        external
        payable
        isValidAmount(rewardAmount)
        whenNotPaused
        nonReentrant
    {
        if (address(rewardVault) == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (avs == address(0)) {
            revert Errors.ZeroAddress();
        }

        // Deposit tokens into reward vault
        rewardVault.deposit(token, msg.sender, avs, rewardAmount);

        // Send cross-chain message to Imuachain
        // Format: bytes32(token) + bytes32(avs) + amount (depositor is not needed on Imuachain side)
        bytes memory actionArgs = abi.encodePacked(bytes32(bytes20(token)), bytes32(bytes20(avs)), rewardAmount);

        // fundAVSReward is supposed to be a must-succeed action, so we don't need to check the response
        _processRequest(Action.REQUEST_FUND_AVS_REWARD, actionArgs, bytes(""));
    }

    /// @inheritdoc IBaseRestakingController
    function claimRewardFromImuachain(address token, uint256 rewardAmount)
        external
        payable
        isValidAmount(rewardAmount)
        whenNotPaused
        nonReentrant
    {
        // Send cross-chain message to Imuachain
        // Format: bytes32(assetAddress) + bytes32(stakerAddress) + amount
        bytes memory actionArgs = abi.encodePacked(bytes32(bytes20(token)), bytes32(bytes20(msg.sender)), rewardAmount);

        // Cache the request to unlock rewards on response
        bytes memory encodedRequest = abi.encode(token, msg.sender, rewardAmount);
        _processRequest(Action.REQUEST_CLAIM_REWARD, actionArgs, encodedRequest);
    }

    /// @inheritdoc IBaseRestakingController
    function withdrawReward(address token, address recipient, uint256 rewardAmount)
        external
        isValidAmount(rewardAmount)
        whenNotPaused
        nonReentrant
    {
        if (address(rewardVault) == address(0) || recipient == address(0)) {
            revert Errors.ZeroAddress();
        }

        rewardVault.withdraw(token, msg.sender, recipient, rewardAmount);
    }

    /// @dev Processes the request by sending it to Imuachain.
    /// @dev If the encodedRequest is not empty, it is regarded as a request that expects a response and the request
    /// would be cached
    /// @param action The action to be performed.
    /// @param actionArgs The encodePacked arguments for the action.
    /// @param encodedRequest The encoded request if the request expects a response.
    function _processRequest(Action action, bytes memory actionArgs, bytes memory encodedRequest) internal {
        uint64 requestNonce = _sendMsgToImuachain(action, actionArgs);
        if (encodedRequest.length > 0) {
            _registeredRequests[requestNonce] = encodedRequest;
            _registeredRequestActions[requestNonce] = action;
        }
    }

    /// @dev Sends a message to Imuachain.
    /// @param action The action to be performed.
    /// @param actionArgs The encodePacked arguments for the action.
    function _sendMsgToImuachain(Action action, bytes memory actionArgs) internal returns (uint64) {
        bytes memory payload = abi.encodePacked(action, actionArgs);
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(DESTINATION_GAS_LIMIT, DESTINATION_MSG_VALUE)
            .addExecutorOrderedExecutionOption();
        MessagingFee memory fee = _quote(IMUACHAIN_CHAIN_ID, payload, options, false);

        MessagingReceipt memory receipt =
            _lzSend(IMUACHAIN_CHAIN_ID, payload, options, MessagingFee(fee.nativeFee, 0), msg.sender, false);
        emit MessageSent(action, receipt.guid, receipt.nonce, receipt.fee.nativeFee);

        return receipt.nonce;
    }

}
