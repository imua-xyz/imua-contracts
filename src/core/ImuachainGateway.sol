// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IImuachainGateway} from "../interfaces/IImuachainGateway.sol";

import {Action} from "../storage/GatewayStorage.sol";

import {ASSETS_CONTRACT} from "../interfaces/precompiles/IAssets.sol";

import {DELEGATION_CONTRACT} from "../interfaces/precompiles/IDelegation.sol";
import {REWARD_CONTRACT} from "../interfaces/precompiles/IReward.sol";

import {
    MessagingFee,
    MessagingReceipt,
    OAppReceiverUpgradeable,
    OAppUpgradeable,
    Origin
} from "../lzApp/OAppUpgradeable.sol";
import {ImuachainGatewayStorage} from "../storage/ImuachainGatewayStorage.sol";

import {Errors} from "../libraries/Errors.sol";
import {OAppCoreUpgradeable} from "../lzApp/OAppCoreUpgradeable.sol";
import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title ImuachainGateway
/// @author imua-xyz
/// @notice The gateway contract deployed on Imuachain for client chain operations.
/// @dev This contract address must be registered in the `x/assets` module for the precompile operations to go through.
contract ImuachainGateway is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IImuachainGateway,
    ImuachainGatewayStorage,
    OAppUpgradeable
{

    using OptionsBuilder for bytes;

    /// @dev Ensures that the function is called only from this contract via low-level call.
    modifier onlyCalledFromThis() {
        if (msg.sender != address(this)) {
            revert Errors.ImuachainGatewayOnlyCalledFromThis();
        }
        _;
    }

    /// @notice Creates the ImuachainGateway contract.
    /// @param endpoint_ The LayerZero endpoint address deployed on this chain
    constructor(address endpoint_) OAppUpgradeable(endpoint_) {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Initializes the ImuachainGateway contract.
    /// @param owner_ The address of the contract owner.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        _initializeWhitelistFunctionSelectors();
        _transferOwnership(owner_);
        __OAppCore_init_unchained(owner_);
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /// @dev Initializes the whitelist function selectors.
    function _initializeWhitelistFunctionSelectors() private {
        _whiteListFunctionSelectors[Action.REQUEST_DEPOSIT_LST] = this.handleLSTTransfer.selector;
        _whiteListFunctionSelectors[Action.REQUEST_WITHDRAW_LST] = this.handleLSTTransfer.selector;
        _whiteListFunctionSelectors[Action.REQUEST_DEPOSIT_NST] = this.handleNSTTransfer.selector;
        _whiteListFunctionSelectors[Action.REQUEST_WITHDRAW_NST] = this.handleNSTTransfer.selector;
        _whiteListFunctionSelectors[Action.REQUEST_SUBMIT_REWARD] = this.handleRewardOperation.selector;
        _whiteListFunctionSelectors[Action.REQUEST_CLAIM_REWARD] = this.handleRewardOperation.selector;
        _whiteListFunctionSelectors[Action.REQUEST_DELEGATE_TO] = this.handleDelegation.selector;
        _whiteListFunctionSelectors[Action.REQUEST_UNDELEGATE_FROM] = this.handleDelegation.selector;
        _whiteListFunctionSelectors[Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO] = this.handleDepositAndDelegate.selector;
        _whiteListFunctionSelectors[Action.REQUEST_ASSOCIATE_OPERATOR] = this.handleOperatorAssociation.selector;
        _whiteListFunctionSelectors[Action.REQUEST_DISSOCIATE_OPERATOR] = this.handleOperatorAssociation.selector;
    }

    /// @notice Pauses the contract.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sends a request to mark the bootstrap on a chain.
    /// @param chainIndex The index of the chain.
    /// @dev This function is useful if the bootstrap failed on a chain and needs to be retried.
    function markBootstrap(uint32 chainIndex) public payable whenNotPaused nonReentrant {
        _markBootstrap(chainIndex);
    }

    /// @dev Internal function to mark the bootstrap on a chain.
    /// @param chainIndex The index of the chain.
    function _markBootstrap(uint32 chainIndex) internal {
        // we don't track that a request was sent to a chain to allow for retrials
        // if the transaction fails on the destination chain
        _sendInterchainMsg(chainIndex, Action.REQUEST_MARK_BOOTSTRAP, "", false);
        emit BootstrapRequestSent(chainIndex);
    }

    /// @inheritdoc IImuachainGateway
    function registerOrUpdateClientChain(
        uint32 clientChainId,
        bytes32 peer,
        uint8 addressLength,
        string calldata name,
        string calldata metaInfo,
        string calldata signatureType
    ) public onlyOwner whenNotPaused {
        if (
            clientChainId == uint32(0) || peer == bytes32(0) || addressLength == 0 || bytes(name).length == 0
                || bytes(metaInfo).length == 0
        ) {
            revert Errors.ZeroValue();
        }

        bool updated = _registerOrUpdateClientChain(clientChainId, addressLength, name, metaInfo, signatureType);
        // the peer is always set, regardless of `updated`
        super.setPeer(clientChainId, peer);

        if (updated) {
            emit ClientChainUpdated(clientChainId);
        } else {
            emit ClientChainRegistered(clientChainId);
        }
    }

    /// @notice Sets a peer on the destination chain for this contract.
    /// @dev This is the LayerZero peer. This function is here for the modifiers
    ///      as well as checking the registration of the client chain id.
    /// @param clientChainId The id of the client chain.
    /// @param clientChainGateway The address of the peer as bytes32.
    function setPeer(uint32 clientChainId, bytes32 clientChainGateway)
        public
        override(IOAppCore, OAppCoreUpgradeable)
        onlyOwner
        whenNotPaused
    {
        // This check, for the registration of the client chain id, is done here and
        // nowhere else. Elsewhere, the precompile is responsible for the checks.
        // The precompile is not called here at all, and hence, such a check must be
        // performed manually.
        _validateClientChainIdRegistered(clientChainId);
        super.setPeer(clientChainId, clientChainGateway);
    }

    /// @inheritdoc IImuachainGateway
    /// @notice Tokens can only be normal reward-bearing LST tokens like wstETH, rETH, jitoSol...
    /// And they are not intended to be: 1) rebasing tokens like stETH, since we assume staker's
    /// balance would not change if nothing is done after deposit, 2) fee-on-transfer tokens, since we
    /// assume Vault would account for the amount that staker transfers to it.
    /// @notice If we want to activate client chain's native restaking, we should add the corresponding virtual
    /// token address to the whitelist, bytes32(bytes20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) for Ethereum
    /// native restaking for example.
    function addWhitelistToken(
        uint32 clientChainId,
        bytes32 token,
        uint8 decimals,
        string calldata name,
        string calldata metaData,
        string calldata oracleInfo,
        uint128 tvlLimit
    ) external payable onlyOwner whenNotPaused nonReentrant {
        if (clientChainId == 0) {
            revert Errors.ZeroValue();
        }
        if (token == bytes32(0)) {
            revert Errors.ZeroAddress();
        }
        if (bytes(name).length == 0) {
            revert Errors.ZeroValue();
        }
        if (bytes(metaData).length == 0) {
            revert Errors.ZeroValue();
        }
        if (bytes(oracleInfo).length == 0) {
            revert Errors.ZeroValue();
        }
        // setting a TVL limit of 0 is permitted to simply add an inactive token, which may
        // be activated later by updating the TVL limit on the client chain

        bool success = ASSETS_CONTRACT.registerToken(
            clientChainId,
            abi.encodePacked(token), // convert to bytes from bytes32
            decimals,
            name,
            metaData,
            oracleInfo
        );
        if (success) {
            emit WhitelistTokenAdded(clientChainId, token);
            _sendInterchainMsg(
                clientChainId, Action.REQUEST_ADD_WHITELIST_TOKEN, abi.encodePacked(token, tvlLimit), false
            );
        } else {
            revert Errors.AddWhitelistTokenFailed(clientChainId, token);
        }
    }

    /// @inheritdoc IImuachainGateway
    function updateWhitelistToken(uint32 clientChainId, bytes32 token, string calldata metaData)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        if (clientChainId == 0) {
            revert Errors.ZeroValue();
        }
        if (token == bytes32(0)) {
            revert Errors.ZeroAddress();
        }
        if (bytes(metaData).length == 0) {
            revert Errors.ZeroValue();
        }
        bool success = ASSETS_CONTRACT.updateToken(clientChainId, abi.encodePacked(token), metaData);
        if (success) {
            emit WhitelistTokenUpdated(clientChainId, token);
        } else {
            revert Errors.UpdateWhitelistTokenFailed(clientChainId, token);
        }
    }

    /**
     * @notice Associate an Imuachain operator with an EVM staker(msg.sender),  and this would count staker's delegation
     * as operator's self-delegation when staker delegates to operator.
     * @param clientChainId The id of client chain
     * @param operator The Imuachain operator address
     * @dev one staker(chainId+stakerAddress) can only associate one operator, while one operator might be associated
     * with multiple stakers
     */
    function associateOperatorWithEVMStaker(uint32 clientChainId, string calldata operator)
        external
        whenNotPaused
        isValidBech32Address(operator)
    {
        bytes memory staker = abi.encodePacked(bytes32(bytes20(msg.sender)));
        bool success = DELEGATION_CONTRACT.associateOperatorWithStaker(clientChainId, staker, bytes(operator));
        if (!success) {
            revert Errors.AssociateOperatorFailed(clientChainId, msg.sender, operator);
        }
    }

    /**
     * @notice Dissociate an Imuachain operator from an EVM staker(msg.sender),  and this requires that the staker has
     * already been associated to operator.
     * @param clientChainId The id of client chain
     */
    function dissociateOperatorFromEVMStaker(uint32 clientChainId) external whenNotPaused {
        bytes memory staker = abi.encodePacked(bytes32(bytes20(msg.sender)));
        bool success = DELEGATION_CONTRACT.dissociateOperatorFromStaker(clientChainId, staker);
        if (!success) {
            revert Errors.DissociateOperatorFailed(clientChainId, msg.sender);
        }
    }

    /// @dev Validates that the client chain id is registered.
    /// @dev This is designed to be called only in the cases wherein the precompile isn't used.
    /// @dev In all other situations, it is the responsibility of the precompile to perform such
    ///      checks.
    /// @param clientChainId The client chain id.
    function _validateClientChainIdRegistered(uint32 clientChainId) internal view {
        (bool success, bool isRegistered) = ASSETS_CONTRACT.isRegisteredClientChain(clientChainId);
        if (!success) {
            revert Errors.ImuachainGatewayFailedToCheckClientChainId();
        }
        if (!isRegistered) {
            revert Errors.ImuachainGatewayNotRegisteredClientChainId();
        }
    }

    /// @dev The internal version of registerOrUpdateClientChain.
    /// @param clientChainId The client chain id.
    /// @param addressLength The length of the address type on the client chain.
    /// @param name The name of the client chain.
    /// @param metaInfo The arbitrary metadata for the client chain.
    /// @param signatureType The signature type supported by the client chain.
    function _registerOrUpdateClientChain(
        uint32 clientChainId,
        uint8 addressLength,
        string calldata name,
        string calldata metaInfo,
        string calldata signatureType
    ) internal returns (bool) {
        (bool success, bool updated) =
            ASSETS_CONTRACT.registerOrUpdateClientChain(clientChainId, addressLength, name, metaInfo, signatureType);
        if (!success) {
            revert Errors.RegisterClientChainToImuachainFailed(clientChainId);
        }
        return updated;
    }

    /// @inheritdoc OAppReceiverUpgradeable
    function _lzReceive(Origin calldata _origin, bytes calldata message)
        internal
        virtual
        override
        whenNotPaused
        nonReentrant
    {
        _verifyAndUpdateNonce(_origin.srcEid, _origin.sender, _origin.nonce);
        _validateMessageLength(message);

        Action act = Action(uint8(message[0]));
        bytes calldata payload = message[1:];
        bytes4 selector_ = _whiteListFunctionSelectors[act];
        if (selector_ == bytes4(0)) {
            revert Errors.UnsupportedRequest(act);
        }

        (bool success, bytes memory responseOrReason) =
            address(this).call(abi.encodePacked(selector_, abi.encode(_origin.srcEid, _origin.nonce, act, payload)));
        if (!success) {
            revert Errors.RequestOrResponseExecuteFailed(act, _origin.nonce, responseOrReason);
        }

        // decode to get the response, and send it back if it is not empty
        bytes memory response = abi.decode(responseOrReason, (bytes));
        if (response.length > 0) {
            _sendInterchainMsg(_origin.srcEid, Action.RESPOND, response, true);
        }

        emit MessageExecuted(act, _origin.nonce);
    }

    /// @notice Handles LST transfer from a client chain.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns empty bytes if the action is deposit, otherwise returns the lzNonce and success flag.
    /// @param srcChainId The source chain id.
    /// @param lzNonce The layer zero nonce.
    /// @param act The action type.
    /// @param payload The request payload.
    // slither-disable-next-line unused-return
    function handleLSTTransfer(uint32 srcChainId, uint64 lzNonce, Action act, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        bytes calldata staker = payload[:32];
        uint256 amount = uint256(bytes32(payload[32:64]));
        bytes calldata token = payload[64:96];

        bool isDeposit = act == Action.REQUEST_DEPOSIT_LST;
        bool success;
        if (isDeposit) {
            (success,) = ASSETS_CONTRACT.depositLST(srcChainId, token, staker, amount);
        } else {
            (success,) = ASSETS_CONTRACT.withdrawLST(srcChainId, token, staker, amount);
        }
        if (isDeposit && !success) {
            revert Errors.DepositRequestShouldNotFail(srcChainId, lzNonce); // we should not let this happen
        }
        emit LSTTransfer(isDeposit, success, bytes32(token), bytes32(staker), amount);

        response = isDeposit ? bytes("") : abi.encodePacked(lzNonce, success);
    }

    /// @notice Handles NST transfer from a client chain.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns empty bytes if the action is deposit, otherwise returns the lzNonce and success flag.
    /// @param srcChainId The source chain id.
    /// @param lzNonce The layer zero nonce.
    /// @param act The action type.
    /// @param payload The request payload.
    // slither-disable-next-line unused-return
    function handleNSTTransfer(uint32 srcChainId, uint64 lzNonce, Action act, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        bytes calldata staker = payload[:32];
        uint256 amount = uint256(bytes32(payload[32:64]));
        // the length of the validatorID is not known. it depends on the chain.
        // for Ethereum, it is the validatorIndex uint256 as bytes so it becomes 32. its value may be 0.
        // for Solana, the pubkey is 32 bytes long but for Sui it is 96 bytes long.
        // these chains do not have the concept of validatorIndex, so the raw key must be used.
        bytes calldata validatorID = payload[64:];

        bool isDeposit = act == Action.REQUEST_DEPOSIT_NST;
        bool success;
        if (isDeposit) {
            (success,) = ASSETS_CONTRACT.depositNST(srcChainId, validatorID, staker, amount);
        } else {
            (success,) = ASSETS_CONTRACT.withdrawNST(srcChainId, validatorID, staker, amount);
        }
        if (isDeposit && !success) {
            revert Errors.DepositRequestShouldNotFail(srcChainId, lzNonce); // we should not let this happen
        }
        emit NSTTransfer(isDeposit, success, validatorID, bytes32(staker), amount);

        response = isDeposit ? bytes("") : abi.encodePacked(lzNonce, success);
    }

    /// @notice Handles rewards request from a client chain, submit reward or claim reward.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns the response to client chain including lzNonce and success flag.
    /// @param srcChainId The source chain id.
    /// @param lzNonce The layer zero nonce.
    /// @param act The action type.
    /// @param payload The request payload.
    // slither-disable-next-line unused-return
    function handleRewardOperation(uint32 srcChainId, uint64 lzNonce, Action act, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        bytes calldata token = payload[:32];
        // it could be either avsId or withdrawer, depending on the action
        bytes calldata avsOrWithdrawer = payload[32:64];
        uint256 amount = uint256(bytes32(payload[64:96]));

        bool isSubmitReward = act == Action.REQUEST_SUBMIT_REWARD;
        bool success;
        if (isSubmitReward) {
            (success,) = REWARD_CONTRACT.submitReward(srcChainId, token, avsOrWithdrawer, amount);
        } else {
            (success,) = REWARD_CONTRACT.claimReward(srcChainId, token, avsOrWithdrawer, amount);
        }
        if (isSubmitReward && !success) {
            revert Errors.DepositRequestShouldNotFail(srcChainId, lzNonce); // we should not let this happen
        }
        emit RewardOperation(isSubmitReward, success, bytes32(token), bytes32(avsOrWithdrawer), amount);

        response = isSubmitReward ? bytes("") : abi.encodePacked(lzNonce, success);
    }

    /// @notice Handles delegation request from a client chain.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns empty response because the client chain should not expect a response.
    /// @param srcChainId The source chain id.
    /// @param lzNonce The layer zero nonce.
    /// @param act The action type.
    /// @param payload The request payload.
    function handleDelegation(uint32 srcChainId, uint64 lzNonce, Action act, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        // use memory to avoid stack too deep
        bytes memory staker = payload[:32];
        uint256 amount = uint256(bytes32(payload[32:64]));
        bytes memory token = payload[64:96];
        bytes memory operator = payload[96:];

        bool isDelegate = act == Action.REQUEST_DELEGATE_TO;
        bool accepted;
        if (isDelegate) {
            accepted = DELEGATION_CONTRACT.delegate(srcChainId, lzNonce, token, staker, operator, amount);
        } else {
            accepted = DELEGATION_CONTRACT.undelegate(srcChainId, lzNonce, token, staker, operator, amount);
        }
        emit DelegationRequest(isDelegate, accepted, bytes32(token), bytes32(staker), string(operator), amount);
    }

    /// @notice Responds to a deposit-then-delegate request from a client chain.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns empty response because the client chain should not expect a response.
    /// @param srcChainId The source chain id.
    /// @param lzNonce The layer zero nonce.
    /// @param payload The request payload.
    // slither-disable-next-line unused-return
    function handleDepositAndDelegate(uint32 srcChainId, uint64 lzNonce, Action, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        // use memory to avoid stack too deep
        bytes memory depositor = payload[:32];
        uint256 amount = uint256(bytes32(payload[32:64]));
        bytes memory token = payload[64:96];
        bytes memory operator = payload[96:];

        (bool success,) = ASSETS_CONTRACT.depositLST(srcChainId, token, depositor, amount);
        if (!success) {
            revert Errors.DepositRequestShouldNotFail(srcChainId, lzNonce); // we should not let this happen
        }
        emit LSTTransfer(true, success, bytes32(token), bytes32(depositor), amount);

        bool accepted = DELEGATION_CONTRACT.delegate(srcChainId, lzNonce, token, depositor, operator, amount);
        emit DelegationRequest(true, accepted, bytes32(token), bytes32(depositor), string(operator), amount);
    }

    /// @notice Handles the associating/dissociating operator request, and no response would be returned.
    /// @dev Can only be called from this contract via low-level call.
    /// @dev Returns empty response because the client chain should not expect a response.
    /// @param srcChainId The source chain id.
    /// @param act The action type.
    /// @param payload The request payload.
    function handleOperatorAssociation(uint32 srcChainId, uint64, Action act, bytes calldata payload)
        public
        onlyCalledFromThis
        returns (bytes memory response)
    {
        bool success;
        bytes calldata staker = payload[:32];

        bool isAssociate = act == Action.REQUEST_ASSOCIATE_OPERATOR;
        if (isAssociate) {
            bytes calldata operator = payload[32:];
            success = DELEGATION_CONTRACT.associateOperatorWithStaker(srcChainId, staker, operator);
        } else {
            success = DELEGATION_CONTRACT.dissociateOperatorFromStaker(srcChainId, staker);
        }

        emit AssociationResult(success, isAssociate, bytes32(staker));
    }

    /// @dev Sends an interchain message to the client chain.
    /// @param srcChainId The chain id of the source chain, from which a message was received, and to which a response
    /// is being sent.
    /// @param act The action to be performed.
    /// @param actionArgs The arguments for the action.
    /// @param payByApp If the source for the transaction funds is this contract.
    function _sendInterchainMsg(uint32 srcChainId, Action act, bytes memory actionArgs, bool payByApp)
        internal
        whenNotPaused
    {
        bytes memory payload = abi.encodePacked(act, actionArgs);

        bytes memory options = _buildOptions(srcChainId, act);

        MessagingFee memory fee = _quote(srcChainId, payload, options, false);

        address refundAddress = payByApp ? address(this) : msg.sender;
        MessagingReceipt memory receipt =
            _lzSend(srcChainId, payload, options, MessagingFee(fee.nativeFee, 0), refundAddress, payByApp);
        emit MessageSent(act, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
    }

    /// @inheritdoc IImuachainGateway
    function quote(uint32 srcChainId, bytes calldata _message) public view returns (uint256 nativeFee) {
        Action act = Action(uint8(_message[0]));

        bytes memory options = _buildOptions(srcChainId, act);

        MessagingFee memory fee = _quote(srcChainId, _message, options, false);
        return fee.nativeFee;
    }

    /// @dev Builds options for interchain messages based on chain and action
    /// @param srcChainId The source chain ID
    /// @param act The action being performed
    /// @return options The built options
    function _buildOptions(uint32 srcChainId, Action act) private pure returns (bytes memory) {
        bytes memory options = OptionsBuilder.newOptions();
        // non-Solana defaults
        uint128 gasLimit = DESTINATION_GAS_LIMIT;
        uint128 value = DESTINATION_MSG_VALUE;
        // to change if Solana
        if (_isSolana(srcChainId)) {
            value = (act == Action.REQUEST_ADD_WHITELIST_TOKEN)
                ? SOLANA_WHITELIST_TOKEN_MSG_VALUE
                : SOLANA_DESTINATION_MSG_VALUE;
            gasLimit = SOLANA_DESTINATION_GAS_LIMIT;
        } else {
            options = options.addExecutorOrderedExecutionOption();
        }
        options = options.addExecutorLzReceiveOption(gasLimit, value);
        return options;
    }

    /// @inheritdoc OAppReceiverUpgradeable
    function nextNonce(uint32 srcEid, bytes32 sender)
        public
        view
        virtual
        override(ILayerZeroReceiver, OAppReceiverUpgradeable)
        returns (uint64)
    {
        return inboundNonce[srcEid][sender] + 1;
    }

}
