// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BeaconChainProofs} from "src/libraries/BeaconChainProofs.sol";

import "forge-std/Test.sol";

contract BeaconChainProofsTest is Test {

    function test_isValidVCRootAgainstStateRoot_isElectra_LengthMismatch() public {
        bytes32 validatorContainerRoot = bytes32(0);
        bytes32 stateRoot = bytes32(0);
        bytes32[] memory validatorContainerRootProof = new bytes32[](46); // Incorrect length
        uint256 validatorIndex = 0; // Valid index
        bool isElectra = true;

        vm.expectRevert("validator container root proof should have 47 nodes");
        BeaconChainProofs.isValidVCRootAgainstStateRoot(
            validatorContainerRoot, stateRoot, validatorContainerRootProof, validatorIndex, isElectra
        );
    }

    function test_isValidVCRootAgainstStateRoot_isNotElectra_LengthMismatch() public {
        bytes32 validatorContainerRoot = bytes32(0);
        bytes32 stateRoot = bytes32(0);
        bytes32[] memory validatorContainerRootProof = new bytes32[](45);
        uint256 validatorIndex = 0; // Valid index
        bool isElectra = false;

        vm.expectRevert("validator container root proof should have 46 nodes");
        BeaconChainProofs.isValidVCRootAgainstStateRoot(
            validatorContainerRoot, stateRoot, validatorContainerRootProof, validatorIndex, isElectra
        );
    }

    function test_isValidVCRootAgainstStateRoot_isElectra_IndexOutOfBounds() public {
        bytes32 validatorContainerRoot = bytes32(0);
        bytes32 stateRoot = bytes32(0);
        bytes32[] memory validatorContainerRootProof = new bytes32[](47);
        uint256 validatorIndex = (1 << 40) + 1;
        bool isElectra = true;

        vm.expectRevert("validator index out of bounds");
        BeaconChainProofs.isValidVCRootAgainstStateRoot(
            validatorContainerRoot, stateRoot, validatorContainerRootProof, validatorIndex, isElectra
        );
    }

}
