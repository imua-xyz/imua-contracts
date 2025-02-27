// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Errors} from "../libraries/Errors.sol";

/**
 * @title UTXOGatewayStorage
 * @dev This contract manages the storage for the UTXO gateway
 */
contract UTXOGatewayStorage {

    /**
     * @notice Enum to represent the type of supported token
     * @dev Each field should be matched with the corresponding field of ClientChainID
     */
    enum Token {
        NONE, // 0: Invalid/uninitialized token
        BTC // 1: Bitcoin token, matches with ClientChainID.Bitcoin

    }

    /**
     * @notice Enum to represent the supported client chain ID
     * @dev Each field should be matched with the corresponding field of Token
     */
    enum ClientChainID {
        NONE, // 0: Invalid/uninitialized chain
        BITCOIN // 1: Bitcoin chain, matches with Token.BTC

    }

    /**
     * @dev Enum to represent the status of a transaction
     */
    enum TxStatus {
        NOT_STARTED_OR_PROCESSED, // 0: transaction hasn't started collecting proofs or has been processed
        PENDING, // 1: Currently collecting witness proofs
        EXPIRED // 2: Failed due to timeout, but can be retried

    }

    /**
     * @dev Enum to represent the WithdrawType
     */
    enum WithdrawType {
        UNDEFINED,
        WITHDRAW_PRINCIPAL,
        WITHDRAW_REWARD
    }

    /**
     * @dev Struct to store stake message information
     * @param clientChainId The client chain ID
     * @param nonce The nonce
     * @param clientTxId The client chain transaction ID
     * @param clientAddress The client chain address
     * @param imuachainAddress The Imuachain address
     * @param operator The operator
     * @param amount The amount
     */
    struct StakeMsg {
        ClientChainID clientChainId;
        uint64 nonce;
        bytes32 clientTxId;
        bytes clientAddress;
        address imuachainAddress;
        string operator;
        uint256 amount;
    }

    /**
     * @dev Struct to store proof information
     */
    struct Proof {
        address witness;
        StakeMsg message;
        uint256 timestamp;
        bytes signature;
    }

    /**
     * @dev Struct to store transaction information
     */
    struct Transaction {
        TxStatus status;
        uint256 proofCount;
        uint256 expiryTime;
        mapping(address => uint256) witnessTime;
        StakeMsg stakeMsg;
    }

    /**
     * @dev Struct for peg-out requests
     */
    struct PegOutRequest {
        ClientChainID clientChainId;
        uint64 nonce;
        address requester;
        bytes clientAddress;
        uint256 amount;
        WithdrawType withdrawType;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */
    /// @notice the app version
    uint256 public constant APP_VERSION = 1;

    /// @notice the human readable prefix for Imuachain bech32 encoded account address.
    bytes public constant IMUA_ADDRESS_PREFIX = bytes("im1");

    // the virtual chain id for Bitcoin, compatible with other chain ids(endpoint ids) maintained by layerzero
    string public constant BITCOIN_NAME = "Bitcoin";
    string public constant BITCOIN_METADATA = "Bitcoin";
    string public constant BITCOIN_SIGNATURE_SCHEME = "ECDSA";
    uint8 public constant STAKER_ACCOUNT_LENGTH = 20;

    // virtual token address and token, shared for tokens supported by the gateway
    address public constant VIRTUAL_TOKEN_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    bytes public constant VIRTUAL_TOKEN = abi.encodePacked(bytes32(bytes20(VIRTUAL_TOKEN_ADDRESS)));

    uint8 public constant BTC_DECIMALS = 8;
    string public constant BTC_NAME = "BTC";
    string public constant BTC_METADATA = "BTC";
    string public constant BTC_ORACLE_INFO = "BTC,BITCOIN,8";

    uint256 public constant PROOF_TIMEOUT = 1 days;
    uint256 public bridgeFeeRate; // e.g., 100 (basis points) means 1%
    uint256 public constant BASIS_POINTS = 10_000; // 100% = 10000 basis points
    uint256 public constant MAX_BRIDGE_FEE_RATE = 1000; // 10%

    // Add min/max bounds for safety
    uint256 public constant MIN_REQUIRED_PROOFS = 1;
    uint256 public constant MAX_REQUIRED_PROOFS = 10;

    /// @notice The minimum number of proofs required for consensus
    /// @dev If the number of authorized witnesses is greater than or equal to the minimum number of proofs,
    /// the consensus would be activated
    uint256 public requiredProofs;

    /// @notice The count of authorized witnesses
    uint256 public authorizedWitnessCount;

    /**
     * @dev Mapping to store transaction information, key is the message hash
     */
    mapping(bytes32 => Transaction) public transactions;

    /**
     * @dev Mapping from client transaction ID to its nonce
     * @dev Key1: ClientChainID
     * @dev Key2: stake message's clientTxId
     * @dev Value: nonce of the processed message (0 if not processed)
     */
    mapping(ClientChainID => mapping(bytes32 => uint64)) public clientTxIdToNonce;

    /**
     * @dev Mapping from nonce to client transaction details
     * @dev Key1: ClientChainID
     * @dev Key2: nonce
     * @dev Value: clientTxId
     */
    mapping(ClientChainID => mapping(uint64 => bytes32)) public nonceToClientTxId;

    /**
     * @dev Mapping to store peg-out requests
     * @dev Key1: ClientChainID
     * @dev Key2: nonce
     * @dev Value: PegOutRequest
     */
    mapping(ClientChainID => mapping(uint64 => PegOutRequest)) public pegOutRequests;

    /**
     * @dev Mapping to store authorized witnesses
     */
    mapping(address => bool) public authorizedWitnesses;

    /**
     * @dev Maps client chain addresses to their registered Imuachain addresses
     * @dev Key1: Client chain ID (Bitcoin, etc.)
     * @dev Key2: Client chain address in bytes
     * @dev Value: Registered Imuachain address
     */
    mapping(ClientChainID => mapping(bytes => address)) public inboundRegistry;

    /**
     * @dev Maps Imuachain addresses to their registered client chain addresses
     * @dev Key1: Client chain ID (Bitcoin, etc.)
     * @dev Key2: Imuachain address
     * @dev Value: Registered client chain address in bytes
     */
    mapping(ClientChainID => mapping(address => bytes)) public outboundRegistry;

    /**
     * @dev Mapping to store inbound nonce for each chain
     */
    mapping(ClientChainID => uint64) public inboundNonce;

    /**
     * @notice Mapping to store outbound nonce for each chain
     */
    mapping(ClientChainID => uint64) public outboundNonce;

    /**
     * @notice Mapping to store peg-out nonce for each chain
     */
    mapping(ClientChainID => uint64) public pegOutNonce;

    /**
     * @notice Mapping to store delegation nonce for each chain
     * @dev The nonce is incremented for each delegate/undelegate operation
     * @dev The nonce is provided to the precompile as operation id
     */
    mapping(ClientChainID => uint64) public delegationNonce;

    // Mapping from chain ID and request ID to client chain transaction ID
    mapping(ClientChainID => mapping(uint64 => bytes32)) public pegOutTxIds;

    uint256[50] private __gap;

    // Events

    /**
     * @dev Emitted when the minimum number of proofs is updated
     * @param oldNumber The old minimum number of proofs
     * @param newNumber The new minimum number of proofs
     */
    event MinProofsUpdated(uint256 indexed oldNumber, uint256 indexed newNumber);

    /**
     * @dev Emitted when a stake message is executed
     * @param clientChainId The chain ID of the client chain, should not violate the layerzero chain id
     * @param nonce The nonce of the stake message
     * @param imAddress The Imuachain address of the depositor
     * @param amount The amount deposited(delegated)
     */
    event StakeMsgExecuted(
        ClientChainID indexed clientChainId, uint64 indexed nonce, address indexed imAddress, uint256 amount
    );

    /**
     * @dev Emitted when a transaction is processed
     * @param txId The hash of the stake message
     */
    event TransactionProcessed(bytes32 indexed txId);

    /**
     * @dev Emitted when a deposit is completed
     * @param clientChainId The client chain ID
     * @param clientTxId The client chain transaction ID
     * @param depositorImAddr The depositor's Imuachain
     * @param depositorClientChainAddr The depositor's client chain address
     * @param amount The amount deposited
     * @param updatedBalance The updated balance after deposit
     */
    event DepositCompleted(
        ClientChainID indexed clientChainId,
        bytes32 indexed clientTxId,
        address indexed depositorImAddr,
        bytes depositorClientChainAddr,
        uint256 amount,
        uint256 updatedBalance
    );

    /**
     * @dev Emitted when a principal withdrawal is requested
     * @param requestId The unique identifier for the withdrawal request
     * @param clientChainId The client chain ID
     * @param withdrawerImAddr The withdrawer's Imuachain
     * @param withdrawerClientChainAddr The withdrawer's client chain address
     * @param amount The amount to withdraw
     * @param updatedBalance The updated balance after withdrawal request
     */
    event WithdrawPrincipalRequested(
        ClientChainID indexed clientChainId,
        uint64 indexed requestId,
        address indexed withdrawerImAddr,
        bytes withdrawerClientChainAddr,
        uint256 amount,
        uint256 updatedBalance
    );

    /**
     * @dev Emitted when a reward withdrawal is requested
     * @param requestId The unique identifier for the withdrawal request
     * @param clientChainId The client chain ID
     * @param withdrawerImAddr The withdrawer's Imuachain
     * @param withdrawerClientChainAddr The withdrawer's client chain address
     * @param amount The amount to withdraw
     * @param updatedBalance The updated balance after withdrawal request
     */
    event WithdrawRewardRequested(
        ClientChainID indexed clientChainId,
        uint64 indexed requestId,
        address indexed withdrawerImAddr,
        bytes withdrawerClientChainAddr,
        uint256 amount,
        uint256 updatedBalance
    );

    /**
     * @dev Emitted when a delegation is completed
     * @param clientChainId The chain ID of the client chain, should not violate the layerzero chain id
     * @param imDelegator The delegator's Imuachain address
     * @param operator The operator's address
     * @param amount The amount delegated
     */
    event DelegationCompleted(
        ClientChainID indexed clientChainId, address indexed imDelegator, string operator, uint256 amount
    );

    /**
     * @dev Emitted when a delegation fails for a stake message
     * @param clientChainId The chain ID of the client chain, should not violate the layerzero chain id
     * @param imDelegator The delegator's Imuachain address
     * @param operator The operator's address
     * @param amount The amount delegated
     */
    event DelegationFailedForStake(
        ClientChainID indexed clientChainId, address indexed imDelegator, string operator, uint256 amount
    );

    /**
     * @dev Emitted when an undelegation is completed
     * @param clientChainId The chain ID of the client chain, should not violate the layerzero chain id
     * @param imDelegator The delegator's Imuachain address
     * @param operator The operator's address
     * @param amount The amount undelegated
     */
    event UndelegationCompleted(
        ClientChainID indexed clientChainId, address indexed imDelegator, string operator, uint256 amount
    );

    /**
     * @dev Emitted when an address is registered
     * @param clientChainId The client chain ID
     * @param depositor The depositor's address
     * @param imAddress The corresponding Imuachain address
     */
    event AddressRegistered(ClientChainID indexed clientChainId, bytes depositor, address indexed imAddress);

    /**
     * @dev Emitted when a new witness is added
     * @param witness The address of the added witness
     */
    event WitnessAdded(address indexed witness);

    /**
     * @dev Emitted when a witness is removed
     * @param witness The address of the removed witness
     */
    event WitnessRemoved(address indexed witness);

    /**
     * @dev Emitted when a proof is submitted
     * @param messageHash The hash of the stake message
     * @param witness The address of the witness submitting the proof
     */
    event ProofSubmitted(bytes32 indexed messageHash, address indexed witness);

    /**
     * @dev Emitted when a deposit is processed
     * @param clientTxId The client chain transaction ID
     * @param recipient The address of the recipient
     * @param amount The amount processed
     */
    event DepositProcessed(bytes32 indexed clientTxId, address indexed recipient, uint256 amount);

    /**
     * @dev Emitted when a transaction expires
     * @param txid The message hash of the expired transaction
     */
    event TransactionExpired(bytes32 indexed txid);

    /**
     * @dev Emitted when the bridge rate is updated
     * @param newRate The new bridge rate
     */
    event BridgeFeeRateUpdated(uint256 newRate);

    /**
     * @dev Emitted when the deposit limit is updated
     * @param newLimit The new deposit limit
     */
    event DepositLimitUpdated(uint256 newLimit);

    /**
     * @dev Emitted when the withdrawal limit is updated
     * @param newLimit The new withdrawal limit
     */
    event WithdrawalLimitUpdated(uint256 newLimit);

    /**
     * @dev Emitted when a peg-out request is under processing
     * @param withdrawType The type of withdrawal
     * @param clientChainId The client chain ID
     * @param requestNonce The nonce of the peg-out request
     * @param requester The requester's address
     * @param clientAddress The client chain address
     * @param amount The amount to withdraw
     */
    event PegOutRequestProcessing(
        uint8 withdrawType,
        ClientChainID indexed clientChainId,
        uint64 indexed requestNonce,
        address indexed requester,
        bytes clientAddress,
        uint256 amount
    );

    /**
     * @dev Emitted when a peg-out request is processed
     * @param clientChainId The client chain ID
     * @param requestNonce The nonce of the peg-out request
     * @param pegOutTxId The client chain(e.g. Bitcoin) transaction ID
     */
    event PegOutRequestProcessed(
        ClientChainID indexed clientChainId, uint64 indexed requestNonce, bytes32 indexed pegOutTxId
    );

    /// @notice Emitted upon the registration of a new client chain.
    /// @param clientChainId The chain ID of the client chain.
    event ClientChainRegistered(ClientChainID indexed clientChainId);

    /// @notice Emitted upon the update of a client chain.
    /// @param clientChainId The chain ID of the client chain.
    event ClientChainUpdated(ClientChainID indexed clientChainId);

    /// @notice Emitted when a token is added to the whitelist.
    /// @param clientChainId The chain ID of the client chain.
    /// @param token The address of the token.
    event WhitelistTokenAdded(ClientChainID indexed clientChainId, address indexed token);

    /// @notice Emitted when a token is updated in the whitelist.
    /// @param clientChainId The chain ID of the client chain.
    /// @param token The address of the token.
    event WhitelistTokenUpdated(ClientChainID indexed clientChainId, address indexed token);

    /// @notice Emitted when consensus is activated
    /// @param requiredWitnessesCount The number of required witnesses
    /// @param authorizedWitnessesCount The number of authorized witnesses
    event ConsensusActivated(uint256 requiredWitnessesCount, uint256 authorizedWitnessesCount);

    /// @notice Emitted when consensus is deactivated
    /// @param requiredWitnessesCount The number of required witnesses
    /// @param authorizedWitnessesCount The number of authorized witnesses
    event ConsensusDeactivated(uint256 requiredWitnessesCount, uint256 authorizedWitnessesCount);

    /**
     * @dev Modifier to check if an amount is valid
     * @param amount The amount to check
     */
    modifier isValidAmount(uint256 amount) {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }
        _;
    }

    modifier isRegistered(Token token, address imAddress) {
        if (outboundRegistry[ClientChainID(uint8(token))][imAddress].length == 0) {
            revert Errors.AddressNotRegistered();
        }
        _;
    }

    /**
     * @dev Modifier to restrict access to authorized witnesses only.
     */
    modifier onlyAuthorizedWitness() {
        if (!authorizedWitnesses[msg.sender]) {
            revert Errors.UnauthorizedWitness();
        }
        _;
    }

    /// @notice Checks if the provided string is a valid Imuachain address.
    /// @param addressToValidate The string to check.
    /// @return True if the string is valid, false otherwise.
    /// @dev Since implementation of bech32 is difficult in Solidity, this function only
    /// checks that the address is 42 characters long and starts with "im1".
    function isValidOperatorAddress(string calldata addressToValidate) public pure returns (bool) {
        bytes memory stringBytes = bytes(addressToValidate);
        if (stringBytes.length != 41) {
            return false;
        }
        for (uint256 i = 0; i < IMUA_ADDRESS_PREFIX.length; ++i) {
            if (stringBytes[i] != IMUA_ADDRESS_PREFIX[i]) {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev Internal function to verify and update the inbound bytes nonce
     * @param srcChainId The source chain ID
     * @param nonce The nonce to verify
     */
    function _verifyInboundNonce(ClientChainID srcChainId, uint64 nonce) internal view {
        if (nonce != inboundNonce[srcChainId] + 1) {
            revert Errors.UnexpectedInboundNonce(inboundNonce[srcChainId] + 1, nonce);
        }
    }

}
