// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Errors} from "../libraries/Errors.sol";

/// @notice Enum representing various actions that can be performed.
enum Action {
    RESPOND,
    REQUEST_ADD_WHITELIST_TOKEN,
    REQUEST_DEPOSIT_LST,
    REQUEST_DEPOSIT_NST,
    REQUEST_WITHDRAW_LST,
    REQUEST_WITHDRAW_NST,
    REQUEST_SUBMIT_REWARD,
    REQUEST_CLAIM_REWARD,
    REQUEST_DELEGATE_TO,
    REQUEST_UNDELEGATE_FROM,
    REQUEST_DEPOSIT_THEN_DELEGATE_TO,
    REQUEST_MARK_BOOTSTRAP,
    REQUEST_ASSOCIATE_OPERATOR,
    REQUEST_DISSOCIATE_OPERATOR
}

/// @title GatewayStorage
/// @notice Storage used by both ends of the gateway contract.
/// @dev This contract is used as the base storage and is inherited by the storage for Bootstrap and ImuachainGateway.
contract GatewayStorage {

    /// @notice the human readable prefix for Imuachain bech32 encoded address.
    bytes public constant IMUA_ADDRESS_PREFIX = bytes("im1");

    /// @dev Mapping of actions to their corresponding function selectors.
    mapping(Action => bytes4) internal _whiteListFunctionSelectors;

    /// @dev Mapping to track inbound nonces for each chain and sender.
    mapping(uint32 eid => mapping(bytes32 sender => uint64 nonce)) public inboundNonce;

    /// @dev Storage gap to allow for future upgrades.
    uint256[40] private __gap;

    /// @notice Emitted when a message is sent through the gateway.
    /// @param act The action being performed.
    /// @param packetId The unique identifier for the packet.
    /// @param nonce The nonce associated with the message.
    /// @param nativeFee The native fee paid for the message.
    event MessageSent(Action indexed act, bytes32 packetId, uint64 nonce, uint256 nativeFee);

    /// @notice Emitted when a message is received and successfully executed.
    /// @param act The action being performed.
    /// @param nonce The nonce associated with the message.
    event MessageExecuted(Action indexed act, uint64 nonce);

    /// @notice Ensures the provided address is a valid im Bech32 encoded address.
    /// @param addressToValidate The address to check.
    modifier isValidBech32Address(string calldata addressToValidate) {
        require(isValidImAddress(addressToValidate), "BootstrapStorage: invalid bech32 encoded Imuachain address");
        _;
    }

    /// @notice Checks if the provided string is a valid Imuachain account address.
    /// @param addressToValidate The string to check.
    /// @return True if the string is valid, false otherwise.
    /// @dev Since implementation of bech32 is difficult in Solidity, this function only
    /// checks that the address is 41 characters long and starts with "im1".
    function isValidImAddress(string calldata addressToValidate) public pure returns (bool) {
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

    /// @notice Verifies and updates the inbound nonce for a given source chain and address.
    /// @dev This function reverts if the nonce is not as expected.
    /// @param srcChainId The ID of the source chain.
    /// @param srcAddress The address of the sender on the source chain.
    /// @param nonce The nonce to be verified and updated.
    function _verifyAndUpdateNonce(uint32 srcChainId, bytes32 srcAddress, uint64 nonce) internal {
        uint64 expectedNonce = inboundNonce[srcChainId][srcAddress] + 1;
        if (nonce != expectedNonce) {
            revert Errors.UnexpectedInboundNonce(expectedNonce, nonce);
        }
        inboundNonce[srcChainId][srcAddress] = nonce;
    }

}
