// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Merkle} from "./Merkle.sol";

// Utility library for parsing and PHASE0 beacon chain block headers
// SSZ
// Spec: https://github.com/ethereum/consensus-specs/blob/dev/ssz/simple-serialize.md#merkleization
// BeaconBlockHeader
// Spec: https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#beaconblockheader
// BeaconState
// Spec: https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#beaconstate

library BeaconChainProofs {

    // constants are the number of fields and the heights of the different merkle trees used in merkleizing
    // beacon chain containers
    uint256 internal constant BEACON_BLOCK_HEADER_FIELD_TREE_HEIGHT = 3;

    uint256 internal constant BEACON_BLOCK_BODY_FIELD_TREE_HEIGHT = 4;

    uint256 internal constant BEACON_STATE_FIELD_TREE_HEIGHT = 5;
    uint256 internal constant BEACON_STATE_FIELD_TREE_HEIGHT_ELECTRA = 6;

    uint256 internal constant EXECUTION_PAYLOAD_HEADER_FIELD_TREE_HEIGHT_CAPELLA = 4;
    // After deneb hard fork, it's increased from 4 to 5
    uint256 internal constant EXECUTION_PAYLOAD_HEADER_FIELD_TREE_HEIGHT_DENEB = 5;

    // SLOTS_PER_HISTORICAL_ROOT = 2**13, so tree height is 13
    uint256 internal constant BLOCK_ROOTS_TREE_HEIGHT = 13;

    // Index of block_summary_root in historical_summary container
    uint256 internal constant BLOCK_SUMMARY_ROOT_INDEX = 0;
    // HISTORICAL_ROOTS_LIMIT = 2**24, so tree height is 24
    uint256 internal constant HISTORICAL_SUMMARIES_TREE_HEIGHT = 24;
    // VALIDATOR_REGISTRY_LIMIT = 2 ** 40, so tree height is 40
    uint256 internal constant VALIDATOR_TREE_HEIGHT = 40;
    // MAX_VALIDATOR_INDEX = 2 ** 40 - 1
    uint256 internal constant MAX_VALIDATOR_INDEX = (1 << VALIDATOR_TREE_HEIGHT) - 1;
    // MAX_WITHDRAWALS_PER_PAYLOAD = 2**4, making tree height = 4
    uint256 internal constant WITHDRAWALS_TREE_HEIGHT = 4;

    // In beacon block body, these data points are indexed by the following numbers. The API does not change
    // without incrmenting the version number, so these constants are safe to use.
    // https://github.com/ethereum/consensus-specs/blob/dev/specs/capella/beacon-chain.md#beaconblockbody
    uint256 internal constant EXECUTION_PAYLOAD_INDEX = 9;
    uint256 internal constant SLOT_INDEX = 0;
    // in beacon block header, ... same as above.
    // https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#beaconblockheader
    uint256 internal constant STATE_ROOT_INDEX = 3;
    uint256 internal constant BODY_ROOT_INDEX = 4;
    // in beacon state, ... same as above
    // https://github.com/ethereum/consensus-specs/blob/dev/specs/capella/beacon-chain.md#beaconstate
    uint256 internal constant VALIDATOR_TREE_ROOT_INDEX = 11;
    uint256 internal constant HISTORICAL_SUMMARIES_INDEX = 27;
    // in execution payload header, ... same as above
    uint256 internal constant TIMESTAMP_INDEX = 9;
    // in execution payload, .... same as above
    uint256 internal constant WITHDRAWALS_INDEX = 14;

    /// @notice This struct contains the information needed for validator container validity verification
    struct ValidatorContainerProof {
        uint256 beaconBlockTimestamp;
        uint256 validatorIndex;
        bytes32 stateRoot;
        bytes32[] stateRootProof;
        bytes32[] validatorContainerRootProof;
    }

    /// @notice This struct contains the root and proof for verifying the state root against the oracle block root
    struct StateRootProof {
        bytes32 beaconStateRoot;
        bytes proof;
    }

    function isValidValidatorContainerRoot(
        bytes32 validatorContainerRoot,
        bytes32[] calldata validatorContainerRootProof,
        uint256 validatorIndex,
        bytes32 beaconBlockRoot,
        bytes32 stateRoot,
        bytes32[] calldata stateRootProof,
        bool isElectra
    ) public view returns (bool valid) {
        bool validStateRoot = isValidStateRoot(stateRoot, beaconBlockRoot, stateRootProof);
        bool validVCRootAgainstStateRoot = isValidVCRootAgainstStateRoot(
            validatorContainerRoot, stateRoot, validatorContainerRootProof, validatorIndex, isElectra
        );
        if (validStateRoot && validVCRootAgainstStateRoot) {
            valid = true;
        }
    }

    function isValidStateRoot(bytes32 stateRoot, bytes32 beaconBlockRoot, bytes32[] calldata stateRootProof)
        public
        view
        returns (bool)
    {
        require(stateRootProof.length == BEACON_BLOCK_HEADER_FIELD_TREE_HEIGHT, "state root proof should have 3 nodes");

        return Merkle.verifyInclusionSha256({
            proof: stateRootProof,
            root: beaconBlockRoot,
            leaf: stateRoot,
            index: STATE_ROOT_INDEX
        });
    }

    function isValidVCRootAgainstStateRoot(
        bytes32 validatorContainerRoot,
        bytes32 stateRoot,
        bytes32[] calldata validatorContainerRootProof,
        uint256 validatorIndex,
        bool isElectra
    ) public view returns (bool) {
        if (isElectra) {
            require(
                validatorContainerRootProof.length
                    == (VALIDATOR_TREE_HEIGHT + 1) + BEACON_STATE_FIELD_TREE_HEIGHT_ELECTRA,
                "validator container root proof should have 47 nodes"
            );
        } else {
            require(
                validatorContainerRootProof.length == (VALIDATOR_TREE_HEIGHT + 1) + BEACON_STATE_FIELD_TREE_HEIGHT,
                "validator container root proof should have 46 nodes"
            );
        }
        require(validatorIndex <= MAX_VALIDATOR_INDEX, "validator index out of bounds");

        uint256 leafIndex = (VALIDATOR_TREE_ROOT_INDEX << (VALIDATOR_TREE_HEIGHT + 1)) | uint256(validatorIndex);

        return Merkle.verifyInclusionSha256({
            proof: validatorContainerRootProof,
            root: stateRoot,
            leaf: validatorContainerRoot,
            index: leafIndex
        });
    }

}
