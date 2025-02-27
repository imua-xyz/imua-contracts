// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Errors} from "../libraries/Errors.sol";
import {ImuachainBytes} from "../libraries/ImuachainBytes.sol";

import {ASSETS_CONTRACT} from "../interfaces/precompiles/IAssets.sol";
import {DELEGATION_CONTRACT} from "../interfaces/precompiles/IDelegation.sol";
import {REWARD_CONTRACT} from "../interfaces/precompiles/IReward.sol";
import {SignatureVerifier} from "../libraries/SignatureVerifier.sol";
import {UTXOGatewayStorage} from "../storage/UTXOGatewayStorage.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/**
 * @title UTXOGateway
 * @dev This contract manages the gateway between Bitcoin like chains and Imua
 * It handles deposits, delegations, withdrawals, and peg-out requests for BTC like tokens.
 */
contract UTXOGateway is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UTXOGatewayStorage
{

    using ImuachainBytes for address;
    using SignatureVerifier for bytes32;

    /**
     * @notice Constructor to initialize the contract with the client chain ID.
     * @dev Sets up initial configuration for testing purposes.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Returns the app version.
     * @dev This is used to check the compatibility of the gateway with Imua
     * @return The app version.
     */
    function appVersion() external pure returns (uint256) {
        return APP_VERSION;
    }

    /**
     * @notice Initializes the contract with the Imuachain witness address, owner address and required proofs.
     * @dev If the witnesses length is greater or equal to the required proofs, the consensus requirement for stake
     * message would be activated.
     * @param owner_ The address of the owner.
     * @param witnesses The addresses of the witnesses.
     * @param requiredProofs_ The number of required proofs.
     */
    function initialize(address owner_, address[] calldata witnesses, uint256 requiredProofs_) external initializer {
        if (owner_ == address(0) || witnesses.length == 0) {
            revert Errors.ZeroAddress();
        }
        if (requiredProofs_ < MIN_REQUIRED_PROOFS || requiredProofs_ > MAX_REQUIRED_PROOFS) {
            revert Errors.InvalidRequiredProofs();
        }

        requiredProofs = requiredProofs_;
        for (uint256 i = 0; i < witnesses.length; i++) {
            _addWitness(witnesses[i]);
        }
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        _transferOwnership(owner_);
    }

    /**
     * @notice Pauses the contract.
     * @dev Can only be called by the contract owner.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     * @dev Can only be called by the contract owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Activates token staking by registering or updating the chain and token with Imua
     */
    function activateStakingForClientChain(ClientChainID clientChainId) external onlyOwner whenNotPaused {
        if (clientChainId == ClientChainID.BITCOIN) {
            _registerOrUpdateClientChain(
                clientChainId, STAKER_ACCOUNT_LENGTH, BITCOIN_NAME, BITCOIN_METADATA, BITCOIN_SIGNATURE_SCHEME
            );
            _registerOrUpdateToken(clientChainId, VIRTUAL_TOKEN, BTC_DECIMALS, BTC_NAME, BTC_METADATA, BTC_ORACLE_INFO);
        } else {
            revert Errors.InvalidClientChain();
        }
    }

    /**
     * @notice Updates the required proofs for consensus.
     * @notice The consensus requirement for stake message would be activated if the current authorized witness count is
     * greater than or equal to the new required proofs.
     * @dev Can only be called by the contract owner.
     * @param newRequiredProofs The new required proofs.
     */
    function updateRequiredProofs(uint256 newRequiredProofs) external onlyOwner whenNotPaused {
        if (newRequiredProofs < MIN_REQUIRED_PROOFS || newRequiredProofs > MAX_REQUIRED_PROOFS) {
            revert Errors.InvalidRequiredProofs();
        }

        bool wasConsensusRequired = _isConsensusRequired();
        uint256 oldRequiredProofs = requiredProofs;
        requiredProofs = newRequiredProofs;

        emit MinProofsUpdated(oldRequiredProofs, newRequiredProofs);

        // Check if consensus state changed due to new requirement
        bool isConsensusRequired_ = _isConsensusRequired();
        if (!wasConsensusRequired && isConsensusRequired_) {
            emit ConsensusActivated(requiredProofs, authorizedWitnessCount);
        } else if (wasConsensusRequired && !isConsensusRequired_) {
            emit ConsensusDeactivated(requiredProofs, authorizedWitnessCount);
        }
    }

    /**
     * @notice Adds a group of authorized witnesses.
     * @notice This could potentially activate consensus for stake message if the total witness count is greater than or
     * equal to the required proofs.
     * @param witnesses The addresses of the witnesses to be added.
     * @dev Can only be called by the contract owner.
     */
    function addWitnesses(address[] calldata witnesses) external onlyOwner whenNotPaused {
        for (uint256 i = 0; i < witnesses.length; i++) {
            _addWitness(witnesses[i]);
        }
    }

    /**
     * @notice Removes a group of authorized witnesses.
     * @notice This could potentially deactivate consensus for stake message if the total witness count is less than the
     * required proofs.
     * @param witnesses The addresses of the witnesses to be removed.
     * @dev Can only be called by the contract owner.
     */
    function removeWitnesses(address[] calldata witnesses) external onlyOwner whenNotPaused {
        for (uint256 i = 0; i < witnesses.length; i++) {
            _removeWitness(witnesses[i]);
        }
    }

    /**
     * @notice Updates the bridge fee rate.
     * @param bridgeFeeRate_ The new bridge fee rate, with basis as 10000, so 100 means 1%
     * @dev Can only be called by the contract owner.
     */
    function updateBridgeFeeRate(uint256 bridgeFeeRate_) external onlyOwner whenNotPaused {
        require(bridgeFeeRate_ <= MAX_BRIDGE_FEE_RATE, "Fee cannot exceed max bridge fee rate");
        bridgeFeeRate = bridgeFeeRate_;
        emit BridgeFeeRateUpdated(bridgeFeeRate_);
    }

    /**
     * @notice Submits a proof for a stake message.
     * @notice The submitted message would be processed after collecting enough proofs from withnesses.
     * @dev The stake message would be deleted after it has been processed to refund some gas, though the mapping
     * inside it cannot be deleted.
     * @param witness The witness address that signed the message.
     * @param _message The stake message.
     * @param _signature The signature of the message.
     */
    // slither-disable-next-line reentrancy-no-eth
    function submitProofForStakeMsg(address witness, StakeMsg calldata _message, bytes calldata _signature)
        external
        nonReentrant
        whenNotPaused
    {
        if (!_isConsensusRequired()) {
            revert Errors.ConsensusNotRequired();
        }

        if (!_isAuthorizedWitness(witness)) {
            revert Errors.WitnessNotAuthorized(witness);
        }

        bytes32 messageHash = _verifyStakeMessage(witness, _message, _signature);

        // we should revoke the tx by setting it as expired if it has expired
        _revokeTxIfExpired(messageHash);

        Transaction storage txn = transactions[messageHash];

        if (txn.status == TxStatus.PENDING) {
            // if the witness has already submitted proof at or after the start of the proof window, they cannot submit
            // again
            if (txn.witnessTime[witness] >= txn.expiryTime - PROOF_TIMEOUT) {
                revert Errors.WitnessAlreadySubmittedProof();
            }
            txn.witnessTime[witness] = block.timestamp;
            txn.proofCount++;
        } else {
            txn.status = TxStatus.PENDING;
            txn.expiryTime = block.timestamp + PROOF_TIMEOUT;
            txn.proofCount = 1;
            txn.witnessTime[witness] = block.timestamp;
            txn.stakeMsg = _message;
        }

        emit ProofSubmitted(messageHash, witness);

        // Check for consensus
        if (txn.proofCount >= requiredProofs) {
            _processStakeMsg(txn.stakeMsg);
            // we delete the transaction after it has been processed to refund some gas, so no need to worry about
            // reentrancy
            delete transactions[messageHash];

            emit TransactionProcessed(messageHash);
        }
    }

    /**
     * @notice Deposits BTC like tokens to Imua
     * @param witness The witness address that signed the message.
     * @param _msg The stake message.
     * @param signature The signature of the message.
     */
    function processStakeMessage(address witness, StakeMsg calldata _msg, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        if (_isConsensusRequired()) {
            revert Errors.ConsensusRequired();
        }

        if (!_isAuthorizedWitness(witness)) {
            revert Errors.WitnessNotAuthorized(witness);
        }
        _verifyStakeMessage(witness, _msg, signature);

        _processStakeMsg(_msg);
    }

    /**
     * @notice Delegates BTC like tokens to an operator.
     * @param token The value of the token enum.
     * @param operator The operator's Imuachain address.
     * @param amount The amount to delegate.
     */
    function delegateTo(Token token, string calldata operator, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        isValidAmount(amount)
        isRegistered(token, msg.sender)
    {
        if (!isValidOperatorAddress(operator)) {
            revert Errors.InvalidOperator();
        }

        ClientChainID clientChainId = ClientChainID(uint8(token));

        bool success = _delegate(clientChainId, msg.sender, operator, amount);
        if (!success) {
            revert Errors.DelegationFailed();
        }

        emit DelegationCompleted(clientChainId, msg.sender, operator, amount);
    }

    /**
     * @notice Undelegates BTC like tokens from an operator.
     * @param token The value of the token enum.
     * @param operator The operator's Imuachain address.
     * @param amount The amount to undelegate.
     */
    function undelegateFrom(Token token, string calldata operator, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        isValidAmount(amount)
        isRegistered(token, msg.sender)
    {
        if (!isValidOperatorAddress(operator)) {
            revert Errors.InvalidOperator();
        }

        ClientChainID clientChainId = ClientChainID(uint8(token));

        uint64 nonce = ++delegationNonce[clientChainId];
        bool success = DELEGATION_CONTRACT.undelegate(
            uint32(uint8(clientChainId)), nonce, VIRTUAL_TOKEN, msg.sender.toImuachainBytes(), bytes(operator), amount
        );
        if (!success) {
            revert Errors.UndelegationFailed();
        }
        emit UndelegationCompleted(clientChainId, msg.sender, operator, amount);
    }

    /**
     * @notice Withdraws the principal BTC like tokens.
     * @param token The value of the token enum.
     * @param amount The amount to withdraw.
     */
    function withdrawPrincipal(Token token, uint256 amount) external nonReentrant whenNotPaused isValidAmount(amount) {
        ClientChainID clientChainId = ClientChainID(uint8(token));

        bytes memory clientAddress = outboundRegistry[clientChainId][msg.sender];
        if (clientAddress.length == 0) {
            revert Errors.AddressNotRegistered();
        }

        (bool success, uint256 updatedBalance) = ASSETS_CONTRACT.withdrawLST(
            uint32(uint8(clientChainId)), VIRTUAL_TOKEN, msg.sender.toImuachainBytes(), amount
        );
        if (!success) {
            revert Errors.WithdrawPrincipalFailed();
        }

        uint64 requestId =
            _initiatePegOut(clientChainId, amount, msg.sender, clientAddress, WithdrawType.WITHDRAW_PRINCIPAL);
        emit WithdrawPrincipalRequested(clientChainId, requestId, msg.sender, clientAddress, amount, updatedBalance);
    }

    /**
     * @notice Withdraws the reward BTC like tokens.
     * @param token The value of the token enum.
     * @param amount The amount to withdraw.
     */
    function withdrawReward(Token token, uint256 amount) external nonReentrant whenNotPaused isValidAmount(amount) {
        ClientChainID clientChainId = ClientChainID(uint8(token));
        bytes memory clientAddress = outboundRegistry[clientChainId][msg.sender];
        if (clientAddress.length == 0) {
            revert Errors.AddressNotRegistered();
        }

        (bool success, uint256 updatedBalance) = REWARD_CONTRACT.claimReward(
            uint32(uint8(clientChainId)), VIRTUAL_TOKEN, msg.sender.toImuachainBytes(), amount
        );
        if (!success) {
            revert Errors.WithdrawRewardFailed();
        }

        uint64 requestId =
            _initiatePegOut(clientChainId, amount, msg.sender, clientAddress, WithdrawType.WITHDRAW_REWARD);
        emit WithdrawRewardRequested(clientChainId, requestId, msg.sender, clientAddress, amount, updatedBalance);
    }

    /**
     * @notice Processes the next peg-out request for a given client chain.
     * @dev Only authorized witnesses can call this function
     * @param clientChainId The client chain ID.
     * @return nextPegOutRequest The peg-out request that is under processing.
     */
    function processNextPegOutRequest(ClientChainID clientChainId)
        external
        onlyAuthorizedWitness
        nonReentrant
        whenNotPaused
        returns (PegOutRequest memory nextPegOutRequest)
    {
        // Get the next request ID that should be processed
        uint64 nextRequestNonce = outboundNonce[clientChainId] + 1;

        // check if the pegout request has already been processed
        if (_isPegoutRequestProcessed(clientChainId, nextRequestNonce)) {
            revert Errors.RequestAlreadyProcessed(nextRequestNonce);
        }

        // Get the specified request
        nextPegOutRequest = pegOutRequests[clientChainId][nextRequestNonce];

        // Check if the request exists
        if (nextPegOutRequest.requester == address(0)) {
            revert Errors.RequestNotFound(nextRequestNonce);
        }

        // Increment the nonce only after successful processing
        outboundNonce[clientChainId] = nextRequestNonce;

        // Emit event with the Bitcoin transaction ID
        emit PegOutRequestProcessing(
            uint8(nextPegOutRequest.withdrawType),
            clientChainId,
            nextRequestNonce,
            nextPegOutRequest.requester,
            nextPegOutRequest.clientAddress,
            nextPegOutRequest.amount
        );
    }

    /**
     * @notice Marks a peg-out request as processed, after the peg-out tx is confirmed on the client chain(e.g. Bitcoin).
     * @dev Only authorized witnesses can call this function
     * @param clientChainId The client chain ID.
     * @param requestNonce The nonce of the peg-out request.
     * @param pegOutTxId The client chain(e.g. Bitcoin) transaction ID.
     */
    function markPegOutRequestProcessed(ClientChainID clientChainId, uint64 requestNonce, bytes32 pegOutTxId)
        external
        onlyAuthorizedWitness
        nonReentrant
        whenNotPaused
    {
        if (_isPegoutRequestProcessed(clientChainId, requestNonce)) {
            revert Errors.RequestAlreadyProcessed(requestNonce);
        }

        if (requestNonce < 1 || requestNonce > outboundNonce[clientChainId]) {
            revert Errors.RequestNonceOutOfBounds(requestNonce);
        }

        pegOutTxIds[clientChainId][requestNonce] = pegOutTxId;

        emit PegOutRequestProcessed(clientChainId, requestNonce, pegOutTxId);
    }

    /**
     * @notice Gets the client chain address for a given Imuachain address
     * @param clientChainId The client chain ID
     * @param imuachainAddress The Imuachain address
     * @return The client chain address
     */
    function getClientAddress(ClientChainID clientChainId, address imuachainAddress)
        external
        view
        returns (bytes memory)
    {
        return outboundRegistry[clientChainId][imuachainAddress];
    }

    /**
     * @notice Gets the Imuachain address for a given client chain address
     * @param clientChainId The client chain ID
     * @param clientAddress The client chain address
     * @return The Imuachain address
     */
    function getImuachainAddress(ClientChainID clientChainId, bytes calldata clientAddress)
        external
        view
        returns (address)
    {
        return inboundRegistry[clientChainId][clientAddress];
    }

    /**
     * @notice Gets the next inbound nonce for a given source chain ID.
     * @param clientChainId The client chain ID.
     * @return The next inbound nonce.
     */
    function nextInboundNonce(ClientChainID clientChainId) external view returns (uint64) {
        return inboundNonce[clientChainId] + 1;
    }

    /**
     * @notice Checks if a stake message originated from a client chain transaction has been processed.
     * @param clientChainId The client chain ID.
     * @param clientTxId The client chain transaction ID.
     * @return True if the transaction has been processed, false otherwise.
     */
    function isStakeMsgProcessed(ClientChainID clientChainId, bytes32 clientTxId) external view returns (bool) {
        return clientTxIdToNonce[clientChainId][clientTxId] != 0;
    }

    /**
     * @notice Retrieves a PegOutRequest by client chain id and request id
     * @param clientChainId The client chain ID
     * @param requestId The unique identifier of the request.
     * @return The PegOutRequest struct associated with the given requestId.
     */
    function getPegOutRequest(ClientChainID clientChainId, uint64 requestId)
        public
        view
        returns (PegOutRequest memory)
    {
        return pegOutRequests[clientChainId][requestId];
    }

    /**
     * @notice Retrieves the status of a transaction.
     * @param messageHash The hash of the transaction.
     * @return The status of the transaction.
     */
    function getTransactionStatus(bytes32 messageHash) public view returns (TxStatus) {
        return transactions[messageHash].status;
    }

    /**
     * @notice Retrieves the proof count of a transaction.
     * @param messageHash The hash of the transaction.
     * @return The proof count of the transaction.
     */
    function getTransactionProofCount(bytes32 messageHash) public view returns (uint256) {
        return transactions[messageHash].proofCount;
    }

    /**
     * @notice Retrieves the expiry time of a transaction.
     * @param messageHash The hash of the transaction.
     * @return The expiry time of the transaction.
     */
    function getTransactionExpiryTime(bytes32 messageHash) public view returns (uint256) {
        return transactions[messageHash].expiryTime;
    }

    /**
     * @notice Retrieves the witness time of a transaction.
     * @param messageHash The hash of the transaction.
     * @param witness The witness address.
     * @return The witness time of the transaction.
     */
    function getTransactionWitnessTime(bytes32 messageHash, address witness) public view returns (uint256) {
        return transactions[messageHash].witnessTime[witness];
    }

    /**
     * @notice Retrieves the client chain(e.g. Bitcoin) peg-out txid for a given peg-out request
     * @param clientChainId The client chain ID
     * @param requestNonce The nonce of the peg-out request
     * @return The client chain(e.g. Bitcoin) peg-out txid for the peg-out request
     */
    function getPegoutTxId(ClientChainID clientChainId, uint64 requestNonce) external view returns (bytes32) {
        return pegOutTxIds[clientChainId][requestNonce];
    }

    /**
     * @notice Checks if consensus is required for a stake message.
     * @return True if count of authorized witnesses is greater than or equal to requiredProofs, false otherwise.
     */
    function isConsensusRequired() external view returns (bool) {
        return _isConsensusRequired();
    }

    /**
     * @notice Checks if a peg-out request has been processed.
     * @param clientChainId The client chain ID.
     * @param requestNonce The nonce of the peg-out request.
     * @return True if the peg-out request has been processed, false otherwise.
     */
    function isPegoutRequestProcessed(ClientChainID clientChainId, uint64 requestNonce) external view returns (bool) {
        return _isPegoutRequestProcessed(clientChainId, requestNonce);
    }

    /**
     * @notice Checks if consensus is required for a stake message.
     * @return True if count of authorized witnesses is greater than or equal to REQUIRED_PROOFS, false otherwise.
     */
    function _isConsensusRequired() internal view returns (bool) {
        return authorizedWitnessCount >= requiredProofs;
    }

    function _isPegoutRequestProcessed(ClientChainID clientChainId, uint64 requestNonce) internal view returns (bool) {
        return pegOutTxIds[clientChainId][requestNonce] != bytes32(0);
    }

    /**
     * @notice Checks if a witness is authorized.
     * @param witness The witness address.
     * @return True if the witness is authorized, false otherwise.
     */
    function _isAuthorizedWitness(address witness) internal view returns (bool) {
        return authorizedWitnesses[witness];
    }

    function _addWitness(address _witness) internal {
        if (_witness == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (_isAuthorizedWitness(_witness)) {
            revert Errors.WitnessAlreadyAuthorized(_witness);
        }

        bool wasConsensusRequired = _isConsensusRequired();

        authorizedWitnesses[_witness] = true;
        authorizedWitnessCount++;
        emit WitnessAdded(_witness);

        // Emit only when crossing the threshold from false to true
        if (!wasConsensusRequired && _isConsensusRequired()) {
            emit ConsensusActivated(requiredProofs, authorizedWitnessCount);
        }
    }

    function _removeWitness(address _witness) internal {
        if (authorizedWitnessCount <= 1) {
            revert Errors.CannotRemoveLastWitness();
        }
        if (!authorizedWitnesses[_witness]) {
            revert Errors.WitnessNotAuthorized(_witness);
        }

        bool wasConsensusRequired = _isConsensusRequired();

        authorizedWitnesses[_witness] = false;
        authorizedWitnessCount--;
        emit WitnessRemoved(_witness);

        // Emit only when crossing the threshold from true to false
        if (wasConsensusRequired && !_isConsensusRequired()) {
            emit ConsensusDeactivated(requiredProofs, authorizedWitnessCount);
        }
    }

    /**
     * @notice Registers or updates the Bitcoin chain with Imua
     */
    function _registerOrUpdateClientChain(
        ClientChainID clientChainId,
        uint8 stakerAccountLength,
        string memory name,
        string memory metadata,
        string memory signatureScheme
    ) internal {
        (bool success, bool updated) = ASSETS_CONTRACT.registerOrUpdateClientChain(
            uint32(uint8(clientChainId)), stakerAccountLength, name, metadata, signatureScheme
        );
        if (!success) {
            revert Errors.RegisterClientChainToImuachainFailed(uint32(uint8(clientChainId)));
        }
        if (updated) {
            emit ClientChainUpdated(clientChainId);
        } else {
            emit ClientChainRegistered(clientChainId);
        }
    }

    function _registerOrUpdateToken(
        ClientChainID clientChainId,
        bytes memory token,
        uint8 decimals,
        string memory name,
        string memory metadata,
        string memory oracleInfo
    ) internal {
        uint32 clientChainIdUint32 = uint32(uint8(clientChainId));
        bool registered =
            ASSETS_CONTRACT.registerToken(clientChainIdUint32, token, decimals, name, metadata, oracleInfo);
        if (!registered) {
            bool updated = ASSETS_CONTRACT.updateToken(clientChainIdUint32, token, metadata);
            if (!updated) {
                revert Errors.AddWhitelistTokenFailed(clientChainIdUint32, bytes32(token));
            }
            emit WhitelistTokenUpdated(clientChainId, VIRTUAL_TOKEN_ADDRESS);
        } else {
            emit WhitelistTokenAdded(clientChainId, VIRTUAL_TOKEN_ADDRESS);
        }
    }

    /**
     * @notice Verifies the signature of a stake message.
     * @param signer The signer address.
     * @param _msg The stake message.
     * @param signature The signature to verify.
     */
    function _verifySignature(address signer, StakeMsg calldata _msg, bytes memory signature)
        internal
        pure
        returns (bytes32 messageHash)
    {
        // StakeMsg, EIP721 is preferred next step.
        bytes memory encodeMsg = abi.encode(
            _msg.clientChainId,
            _msg.nonce,
            _msg.clientTxId,
            _msg.clientAddress,
            _msg.imuachainAddress,
            _msg.operator,
            _msg.amount
        );
        messageHash = keccak256(encodeMsg);

        SignatureVerifier.verifyMsgSig(signer, messageHash, signature);
    }

    /**
     * @dev Verifies that all required fields in StakeMsg are valid
     * @param _msg The stake message to verify
     */
    function _verifyStakeMsgFields(StakeMsg calldata _msg) internal pure {
        if (
            uint8(_msg.clientChainId) == 0 || _msg.nonce == 0 || uint256(_msg.clientTxId) == 0
                || _msg.clientAddress.length == 0 || _msg.amount == 0
        ) {
            revert Errors.InvalidStakeMessage();
        }

        if (bytes(_msg.operator).length > 0 && !isValidOperatorAddress(_msg.operator)) {
            revert Errors.InvalidOperator();
        }
    }

    function _verifyClientTxIdNotProcessed(ClientChainID clientChainId, bytes32 clientTxId) internal view {
        if (clientTxIdToNonce[clientChainId][clientTxId] != 0) {
            revert Errors.TxTagAlreadyProcessed();
        }
    }

    /**
     * @notice Verifies a stake message.
     * @param witness The witness address that signed the message.
     * @param _msg The stake message.
     * @param signature The signature to verify.
     */
    function _verifyStakeMessage(address witness, StakeMsg calldata _msg, bytes calldata signature)
        internal
        view
        returns (bytes32 messageHash)
    {
        // verify that the stake message fields are valid
        _verifyStakeMsgFields(_msg);

        // Verify nonce
        _verifyInboundNonce(_msg.clientChainId, _msg.nonce);

        // Verify that the txTag has not been processed
        _verifyClientTxIdNotProcessed(_msg.clientChainId, _msg.clientTxId);

        // Verify signature
        messageHash = _verifySignature(witness, _msg, signature);
    }

    /**
     * @notice Initiates a peg-out request for a given token amount to a Bitcoin address
     * @dev This function creates a new peg-out request and stores it in the contract's state
     * @param clientChainId The client chain to be pegged out
     * @param _amount The amount of tokens to be pegged out
     * @param withdrawer The Imuachain address associated with the Bitcoin address
     * @param clientAddress The client chain address
     * @param _withdrawType The type of withdrawal (e.g., normal, fast)
     * @return requestId The unique identifier for the peg-out request
     * @custom:throws RequestAlreadyExists if a request with the same parameters already exists
     */
    function _initiatePegOut(
        ClientChainID clientChainId,
        uint256 _amount,
        address withdrawer,
        bytes memory clientAddress,
        WithdrawType _withdrawType
    ) internal returns (uint64 requestId) {
        // 2. increase the peg-out nonce for the client chain and return as requestId
        requestId = ++pegOutNonce[clientChainId];

        // 3. Check if request already exists
        PegOutRequest storage request = pegOutRequests[clientChainId][requestId];
        if (request.requester != address(0)) {
            revert Errors.RequestAlreadyExists(uint32(uint8(clientChainId)), requestId);
        }

        // 4. Create new PegOutRequest
        request.clientChainId = clientChainId;
        request.nonce = requestId;
        request.requester = withdrawer;
        request.clientAddress = clientAddress;
        request.amount = _amount;
        request.withdrawType = _withdrawType;
    }

    /**
     * @notice Internal function to deposit BTC like token.
     * @param clientChainId The client chain ID.
     * @param srcAddress The source address.
     * @param depositorImAddr The Imuachain address.
     * @param amount The amount to deposit.
     * @param clientTxId The client chain transaction ID.
     */
    function _deposit(
        ClientChainID clientChainId,
        bytes memory srcAddress,
        address depositorImAddr,
        uint256 amount,
        bytes32 clientTxId
    ) internal {
        (bool success, uint256 updatedBalance) = ASSETS_CONTRACT.depositLST(
            uint32(uint8(clientChainId)), VIRTUAL_TOKEN, depositorImAddr.toImuachainBytes(), amount
        );
        if (!success) {
            revert Errors.DepositFailed(clientTxId);
        }

        emit DepositCompleted(clientChainId, clientTxId, depositorImAddr, srcAddress, amount, updatedBalance);
    }

    /**
     * @notice Internal function to delegate BTC like token.
     * @param clientChainId The client chain ID.
     * @param delegator The Imuachain address.
     * @param operator The operator's address.
     * @param amount The amount to delegate.
     * @return success True if the delegation was successful, false otherwise.
     * @dev Sometimes we may not want to revert on failure, so we return a boolean.
     */
    function _delegate(ClientChainID clientChainId, address delegator, string memory operator, uint256 amount)
        internal
        returns (bool success)
    {
        uint64 nonce = ++delegationNonce[clientChainId];
        success = DELEGATION_CONTRACT.delegate(
            uint32(uint8(clientChainId)), nonce, VIRTUAL_TOKEN, delegator.toImuachainBytes(), bytes(operator), amount
        );
    }

    function _revokeTxIfExpired(bytes32 txid) internal {
        Transaction storage txn = transactions[txid];
        if (txn.status == TxStatus.PENDING && block.timestamp >= txn.expiryTime) {
            txn.status = TxStatus.EXPIRED;
            emit TransactionExpired(txid);
        }
    }

    function _registerAddress(ClientChainID clientChainId, bytes memory depositor, address imuachainAddress) internal {
        require(depositor.length > 0 && imuachainAddress != address(0), "Invalid address");
        require(inboundRegistry[clientChainId][depositor] == address(0), "Depositor address already registered");
        require(outboundRegistry[clientChainId][imuachainAddress].length == 0, "Imuachain address already registered");

        inboundRegistry[clientChainId][depositor] = imuachainAddress;
        outboundRegistry[clientChainId][imuachainAddress] = depositor;

        emit AddressRegistered(clientChainId, depositor, imuachainAddress);
    }

    function _processStakeMsg(StakeMsg memory _msg) internal {
        // increment inbound nonce for the client chain and mark the tx as processed
        inboundNonce[_msg.clientChainId]++;
        clientTxIdToNonce[_msg.clientChainId][_msg.clientTxId] = _msg.nonce;
        nonceToClientTxId[_msg.clientChainId][_msg.nonce] = _msg.clientTxId;

        // register address if not already registered
        if (
            inboundRegistry[_msg.clientChainId][_msg.clientAddress] == address(0)
                && outboundRegistry[_msg.clientChainId][_msg.imuachainAddress].length == 0
        ) {
            if (_msg.imuachainAddress == address(0)) {
                revert Errors.ZeroAddress();
            }
            _registerAddress(_msg.clientChainId, _msg.clientAddress, _msg.imuachainAddress);
        }

        address stakerImAddr = inboundRegistry[_msg.clientChainId][_msg.clientAddress];
        uint256 fee = _msg.amount * bridgeFeeRate / BASIS_POINTS;
        uint256 amountAfterFee = _msg.amount - fee;

        // we use registered Imuachain address as the depositor
        // this should always succeed and never revert, otherwise something is wrong.
        _deposit(_msg.clientChainId, _msg.clientAddress, stakerImAddr, amountAfterFee, _msg.clientTxId);

        // delegate to operator if operator is provided, and do not revert if it fails since we need to count the stake
        // as deposited
        if (bytes(_msg.operator).length > 0) {
            bool success = _delegate(_msg.clientChainId, stakerImAddr, _msg.operator, amountAfterFee);
            if (!success) {
                emit DelegationFailedForStake(_msg.clientChainId, stakerImAddr, _msg.operator, amountAfterFee);
            } else {
                emit DelegationCompleted(_msg.clientChainId, stakerImAddr, _msg.operator, amountAfterFee);
            }
        }

        emit StakeMsgExecuted(_msg.clientChainId, _msg.nonce, stakerImAddr, amountAfterFee);
    }

}
