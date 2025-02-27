// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import {IOAppReceiver} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppReceiver.sol";

/// @title ImuachainGateway interface
/// @author imua-xyz
/// @notice ImuachainGateway is the interface for the ImuachainGateway contract. It provides a set of functions for
/// ImuachainGateway operations.
/// @dev It is deployed on the Imuachain end and is designed to interact with other chains,
/// as well as precompiles on Imuachain in response to messages from other chains.
interface IImuachainGateway is IOAppReceiver, IOAppCore {

    /// @notice Calculates the native fee for sending a message with specific options.
    /// @param srcChainid The chain id of the source chain, from which a message was received,
    /// and to which a response is being sent.
    /// @param _message The message for which the fee is being calculated.
    /// @return nativeFee The calculated native fee for the given message.
    function quote(uint32 srcChainid, bytes memory _message) external view returns (uint256 nativeFee);

    /// @notice Registers the @param clientChainId and other meta data to Imuachain native module or update the client
    /// chain's meta data, if a chain identified by @param clientChainId already exists. Sets trusted @param peer to
    /// enable cross-chain communication.
    /// @param clientChainId The endpoint ID for client chain.
    /// @param peer The trusted remote contract address to be associated with the corresponding endpoint or some
    /// authorized signer that would be trusted for sending messages from/to source chain to/from this contract.
    /// @param addressLength The bytes length of address type on that client chain.
    /// @param name The name of client chain.
    /// @param metaInfo The arbitrary metadata for client chain.
    /// @param signatureType The cryptographic signature type that client chain supports.
    /// @dev Only the owner/admin of the OApp can call this function.
    /// @dev Indicates that the peer is trusted to send LayerZero messages to this OApp.
    /// @dev Peer is a bytes32 to accommodate non-evm chains.
    function registerOrUpdateClientChain(
        uint32 clientChainId,
        bytes32 peer,
        uint8 addressLength,
        string calldata name,
        string calldata metaInfo,
        string calldata signatureType
    ) external;

    /// @notice Add a single whitelisted token to the client chain.
    /// @param clientChainId The LayerZero chain id of the client chain.
    /// @param token The token address to be whitelisted.
    /// @param decimals The decimals of the token.
    /// @param name The name of the token.
    /// @param metaData The meta information of the token.
    /// @param oracleInfo The oracle information of the token.
    /// @param tvlLimit The TVL limit of the token to set on the client chain.
    /// @dev The chain must be registered before adding tokens.
    /// @dev This function is payable because it sends a message to the client chain.
    /// @dev The tvlLimit is a `uint128` so that it can work on Solana easily. Within this uint,
    /// we can fit 1 trillion tokens with 18 decimals.
    function addWhitelistToken(
        uint32 clientChainId,
        bytes32 token,
        uint8 decimals,
        string calldata name,
        string calldata metaData,
        string calldata oracleInfo,
        uint128 tvlLimit
    ) external payable;

    /// @notice Updates the parameters for a whitelisted token on the client chain.
    /// @param clientChainId The LayerZero chain id of the client chain.
    /// @param token The address of the token to be updated.
    /// @param metaData The new meta information of the token.
    /// @dev The token must exist in the whitelist before updating.
    function updateWhitelistToken(uint32 clientChainId, bytes32 token, string calldata metaData) external;

    /// @notice Marks the network as bootstrapped, on the client chain.
    /// @dev Causes an upgrade of the Bootstrap contract to the ClientChainGateway contract.
    /// @dev Only works if LZ infrastructure is set up and SetPeer has been called.
    /// @dev This is payable because it requires a fee to be paid to LZ.
    /// @param clientChainId The LayerZero chain id of the client chain.
    function markBootstrap(uint32 clientChainId) external payable;

}
