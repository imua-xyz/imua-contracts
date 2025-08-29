// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Endian} from "../libraries/Endian.sol";

/**
 * class Validator(Container):
 *     pubkeyHash: The validator's BLS12-381 public key hash.
 *     withdrawal_credentials: Bytes32  # Commitment to pubkey for withdrawals
 *     effective_balance: Gwei  # Balance at stake
 *     slashed: boolean
 *     # Status epochs
 *     activation_eligibility_epoch: Epoch  # When criteria for activation were met
 *     activation_epoch: Epoch
 *     exit_epoch: Epoch
 *     withdrawable_epoch: Epoch  # When validator can withdraw funds
 */
library ValidatorContainer {

    using Endian for bytes32;

    uint256 internal constant VALID_LENGTH = 8;
    uint256 internal constant MERKLE_TREE_HEIGHT = 3;

    /// @notice Computes EigenPod style pubkey hash (48 bytes)
    /// @dev EigenPod method: append 16 zero bytes and compute sha256
    /// @dev This matches the implementation in eigenpod-proofs-generation
    /// @param pubkey The 48-byte BLS public key
    /// @return The sha256 hash of the public key padded with 16 zeros
    function computePubkeyHash(bytes memory pubkey) internal pure returns (bytes32) {
        require(pubkey.length == 48, "ValidatorContainer: invalid pubkey length");

        // EigenPod computePubkeyHash: tack on 16 bytes of 0's and compute sha256
        // https://github.com/Layr-Labs/eigenpod-proofs-generation/blob/82ee04a15065fdedd58ed8d167688bb03f76dfb2/prove_validator.go#L154
        bytes memory paddedPubkey = abi.encodePacked(pubkey, bytes16(0));
        return sha256(paddedPubkey);
    }

    function verifyValidatorContainerBasic(bytes32[] calldata validatorContainer) internal pure returns (bool) {
        return validatorContainer.length == VALID_LENGTH;
    }

    function getPubkeyHash(bytes32[] calldata validatorContainer) internal pure returns (bytes32) {
        return validatorContainer[0];
    }

    function getWithdrawalCredentials(bytes32[] calldata validatorContainer) internal pure returns (bytes32) {
        return validatorContainer[1];
    }

    function getEffectiveBalance(bytes32[] calldata validatorContainer) internal pure returns (uint64) {
        return validatorContainer[2].fromLittleEndianUint64();
    }

    function getSlashed(bytes32[] calldata validatorContainer) internal pure returns (bool) {
        return uint8(bytes1(validatorContainer[3])) == 1;
    }

    function getActivationEpoch(bytes32[] calldata validatorContainer) internal pure returns (uint64) {
        return validatorContainer[5].fromLittleEndianUint64();
    }

    function getExitEpoch(bytes32[] calldata validatorContainer) internal pure returns (uint64) {
        return validatorContainer[6].fromLittleEndianUint64();
    }

    function getWithdrawableEpoch(bytes32[] calldata validatorContainer) internal pure returns (uint64) {
        return validatorContainer[7].fromLittleEndianUint64();
    }

    function merkleizeValidatorContainer(bytes32[] calldata validatorContainer) internal pure returns (bytes32) {
        bytes32[] memory leaves = validatorContainer;
        for (uint256 i = 0; i < MERKLE_TREE_HEIGHT; ++i) {
            bytes32[] memory roots = new bytes32[](leaves.length / 2);
            for (uint256 j = 0; j < leaves.length / 2; ++j) {
                roots[j] = sha256(abi.encodePacked(leaves[2 * j], leaves[2 * j + 1]));
            }
            leaves = roots;
        }

        return leaves[0];
    }

}
