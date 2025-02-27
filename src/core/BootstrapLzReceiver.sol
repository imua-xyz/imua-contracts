// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Errors} from "../libraries/Errors.sol";

import {OAppReceiverUpgradeable, Origin} from "../lzApp/OAppReceiverUpgradeable.sol";
import {BootstrapStorage} from "../storage/BootstrapStorage.sol";
import {Action} from "../storage/GatewayStorage.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title BootstrapLzReceiver
/// @author imua-xyz
/// @notice The base contract for the BootstrapLzReceiver. It only receives messages from Imuachain and does not
/// send any.
/// @dev This contract is abstract because it does not call the base contract's constructor.
abstract contract BootstrapLzReceiver is PausableUpgradeable, OAppReceiverUpgradeable, BootstrapStorage {

    /// @dev Allows only this contract to call the function via low level call.
    modifier onlyCalledFromThis() {
        if (msg.sender != address(this)) {
            revert Errors.BootstrapLzReceiverOnlyCalledFromThis();
        }
        _;
    }

    /// @inheritdoc OAppReceiverUpgradeable
    function _lzReceive(Origin calldata _origin, bytes calldata payload) internal virtual override {
        if (_origin.srcEid != IMUACHAIN_CHAIN_ID) {
            revert Errors.UnexpectedSourceChain(_origin.srcEid);
        }
        _verifyAndUpdateNonce(_origin.srcEid, _origin.sender, _origin.nonce);
        Action act = Action(uint8(payload[0]));
        if (act == Action.RESPOND) {
            revert Errors.BootstrapLzReceiverInvalidAction();
        }
        bytes4 selector_ = _whiteListFunctionSelectors[act];
        if (selector_ == bytes4(0)) {
            revert Errors.UnsupportedRequest(act);
        }
        (bool success, bytes memory reason) = address(this).call(abi.encodePacked(selector_, abi.encode(payload[1:])));
        if (!success) {
            revert Errors.RequestOrResponseExecuteFailed(act, _origin.nonce, reason);
        }
    }

    /// @inheritdoc OAppReceiverUpgradeable
    function nextNonce(uint32 srcEid, bytes32 sender)
        public
        view
        virtual
        override(OAppReceiverUpgradeable)
        returns (uint64)
    {
        return inboundNonce[srcEid][sender] + 1;
    }

}
