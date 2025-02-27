// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Action} from "../storage/GatewayStorage.sol";

library ActionAttributes {

    // Message length constants
    uint256 internal constant ASSET_OPERATION_LENGTH = 97;
    uint256 internal constant DELEGATION_OPERATION_LENGTH = 138;
    uint256 internal constant ASSOCIATE_OPERATOR_LENGTH = 74;
    uint256 internal constant DISSOCIATE_OPERATOR_LENGTH = 33;

    // Bitmaps for operation types
    uint256 internal constant LST = 1 << 0;
    uint256 internal constant NST = 1 << 1;
    uint256 internal constant WITHDRAWAL = 1 << 2;
    uint256 internal constant PRINCIPAL = 1 << 3;
    uint256 internal constant REWARD = 1 << 4;

    uint256 internal constant MESSAGE_LENGTH_MASK = 0xFF; // 8 bits for message length
    uint256 internal constant MESSAGE_LENGTH_SHIFT = 8;
    uint256 internal constant MIN_LENGTH_FLAG = 1 << 16; // Flag at the 16th bit

    function getAttributes(Action action) internal pure returns (uint256) {
        uint256 attributes = 0;
        uint256 messageLength = 0;

        if (action == Action.REQUEST_DEPOSIT_LST) {
            attributes = LST | PRINCIPAL;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_DEPOSIT_NST) {
            // we assume that a validatorID is at least 32 bytes, however, it is up for review.
            attributes = NST | PRINCIPAL | MIN_LENGTH_FLAG;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_WITHDRAW_LST) {
            attributes = LST | PRINCIPAL | WITHDRAWAL;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_WITHDRAW_NST) {
            // we assume that a validatorID is at least 32 bytes, however, it is up for review.
            attributes = NST | PRINCIPAL | WITHDRAWAL | MIN_LENGTH_FLAG;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_CLAIM_REWARD) {
            attributes = REWARD | WITHDRAWAL;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_SUBMIT_REWARD) {
            // New action
            attributes = REWARD;
            messageLength = ASSET_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_DELEGATE_TO || action == Action.REQUEST_UNDELEGATE_FROM) {
            messageLength = DELEGATION_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO) {
            attributes = LST | PRINCIPAL;
            messageLength = DELEGATION_OPERATION_LENGTH;
        } else if (action == Action.REQUEST_ASSOCIATE_OPERATOR) {
            messageLength = ASSOCIATE_OPERATOR_LENGTH;
        } else if (action == Action.REQUEST_DISSOCIATE_OPERATOR) {
            messageLength = DISSOCIATE_OPERATOR_LENGTH;
        } else {
            return 0;
        }

        return attributes | (messageLength << MESSAGE_LENGTH_SHIFT);
    }

    function isLST(Action action) internal pure returns (bool) {
        return (getAttributes(action) & LST) != 0;
    }

    function isNST(Action action) internal pure returns (bool) {
        return (getAttributes(action) & NST) != 0;
    }

    function isWithdrawal(Action action) internal pure returns (bool) {
        return (getAttributes(action) & WITHDRAWAL) != 0;
    }

    function isPrincipal(Action action) internal pure returns (bool) {
        return (getAttributes(action) & PRINCIPAL) != 0;
    }

    function isReward(Action action) internal pure returns (bool) {
        return (getAttributes(action) & REWARD) != 0;
    }

    function getMessageLength(Action action) internal pure returns (bool, uint256) {
        uint256 attributes = getAttributes(action);
        uint256 length = (attributes >> MESSAGE_LENGTH_SHIFT) & MESSAGE_LENGTH_MASK;
        bool isMinLength = (attributes & MIN_LENGTH_FLAG) != 0;
        return (isMinLength, length);
    }

}
