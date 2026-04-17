// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {BridgeVerifier, IBridgeGateway} from "../../../src/core/BridgeVerifier.sol";

/// @dev Mock gateway that records delivered messages for testing.
contract MockGateway is IBridgeGateway {
    bytes[] public deliveredMessages;
    bool public shouldRevert;

    function oracleDeliver(bytes calldata message) external override {
        if (shouldRevert) {
            revert("mock revert");
        }
        deliveredMessages.push(message);
    }

    function getDeliveredCount() external view returns (uint256) {
        return deliveredMessages.length;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}

contract BridgeVerifierTest is Test {
    BridgeVerifier verifier;
    MockGateway gateway;

    // Sorted by address ascending (determined by vm.addr output).
    // We compute and sort in setUp.
    uint256[3] pks;
    address[3] vals; // vals[0] < vals[1] < vals[2]
    uint256[3] powers;

    function setUp() public {
        uint256[3] memory rawPks = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA1)];
        address[3] memory rawVals;
        for (uint i = 0; i < 3; i++) {
            rawVals[i] = vm.addr(rawPks[i]);
        }
        // Bubble sort by address
        for (uint i = 0; i < 3; i++) {
            for (uint j = i + 1; j < 3; j++) {
                if (rawVals[i] > rawVals[j]) {
                    (rawVals[i], rawVals[j]) = (rawVals[j], rawVals[i]);
                    (rawPks[i], rawPks[j]) = (rawPks[j], rawPks[i]);
                }
            }
        }
        for (uint i = 0; i < 3; i++) {
            pks[i] = rawPks[i];
            vals[i] = rawVals[i];
        }
        powers = [uint256(40), uint256(40), uint256(20)];

        gateway = new MockGateway();
        verifier = new BridgeVerifier();

        address[] memory valsArr = new address[](3);
        uint256[] memory powersArr = new uint256[](3);
        for (uint i = 0; i < 3; i++) {
            valsArr[i] = vals[i];
            powersArr[i] = powers[i];
        }
        verifier.initialize(address(this), address(gateway), 101, valsArr, powersArr);
    }

    function _signCheckpoint(
        uint256 privKey,
        uint256 checkpointNonce,
        uint256 dstChainID,
        bytes32 messagesHash
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 checkpoint = keccak256(abi.encode(uint256(1), checkpointNonce, dstChainID, messagesHash));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", checkpoint));
        (v, r, s) = vm.sign(privKey, ethSignedHash);
    }

    // Helper: build sorted signer arrays from indices into vals/pks
    function _buildSorted(uint[] memory indices, bytes32 messagesHash, uint256 nonce, uint256 chain)
        internal view returns (
            address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss
        )
    {
        uint n = indices.length;
        signers = new address[](n);
        vs = new uint8[](n);
        rs = new bytes32[](n);
        ss = new bytes32[](n);
        for (uint i = 0; i < n; i++) {
            uint idx = indices[i];
            signers[i] = vals[idx];
            (vs[i], rs[i], ss[i]) = _signCheckpoint(pks[idx], nonce, chain, messagesHash);
        }
    }

    function test_VerifyAndDeliver_Success() public {
        bytes[] memory messages = new bytes[](2);
        messages[0] = hex"000102";
        messages[1] = hex"030405";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        // Use first two validators (sorted), power = 40+40 = 80 > 66 required
        uint[] memory idx = new uint[](2);
        idx[0] = 0; idx[1] = 1;
        (address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss)
            = _buildSorted(idx, messagesHash, 1, 101);

        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);

        assertEq(verifier.lastCheckpointNonce(101), 1);
        assertEq(gateway.getDeliveredCount(), 2);
    }

    function test_VerifyAndDeliver_InsufficientPower() public {
        bytes[] memory messages = new bytes[](1);
        messages[0] = hex"000102";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        // Only val[2] with power=20, need 67
        uint[] memory idx = new uint[](1);
        idx[0] = 2;
        (address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss)
            = _buildSorted(idx, messagesHash, 1, 101);

        vm.expectRevert(abi.encodeWithSelector(BridgeVerifier.InsufficientSigningPower.selector, 20, 67));
        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);
    }

    function test_VerifyAndDeliver_InvalidNonce() public {
        bytes[] memory messages = new bytes[](1);
        messages[0] = hex"00";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        uint[] memory idx = new uint[](2);
        idx[0] = 0; idx[1] = 1;
        (address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss)
            = _buildSorted(idx, messagesHash, 2, 101); // nonce=2 but expected=1

        vm.expectRevert(abi.encodeWithSelector(BridgeVerifier.InvalidCheckpointNonce.selector, 1, 2));
        verifier.verifyAndDeliver(2, 101, messagesHash, messages, signers, vs, rs, ss);
    }

    function test_VerifyAndDeliver_UnsortedSigners() public {
        bytes[] memory messages = new bytes[](1);
        messages[0] = hex"00";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        // Deliberately reverse the order (descending instead of ascending)
        (uint8 v0, bytes32 r0, bytes32 s0) = _signCheckpoint(pks[1], 1, 101, messagesHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = _signCheckpoint(pks[0], 1, 101, messagesHash);

        address[] memory signers = new address[](2);
        uint8[] memory vs = new uint8[](2);
        bytes32[] memory rs = new bytes32[](2);
        bytes32[] memory ss = new bytes32[](2);
        signers[0] = vals[1]; vs[0] = v0; rs[0] = r0; ss[0] = s0; // higher addr first
        signers[1] = vals[0]; vs[1] = v1; rs[1] = r1; ss[1] = s1; // lower addr second

        vm.expectRevert(abi.encodeWithSelector(BridgeVerifier.DuplicateSigner.selector, vals[0]));
        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);
    }

    function test_VerifyAndDeliver_SignatureMismatch() public {
        bytes[] memory messages = new bytes[](1);
        messages[0] = hex"00";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        // Sign with pks[0] but claim it's vals[1]
        (uint8 v0, bytes32 r0, bytes32 s0) = _signCheckpoint(pks[0], 1, 101, messagesHash);

        address[] memory signers = new address[](1);
        uint8[] memory vs = new uint8[](1);
        bytes32[] memory rs = new bytes32[](1);
        bytes32[] memory ss = new bytes32[](1);
        signers[0] = vals[1]; vs[0] = v0; rs[0] = r0; ss[0] = s0;

        vm.expectRevert(abi.encodeWithSelector(BridgeVerifier.SignatureMismatch.selector, vals[1], vals[0]));
        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);
    }

    function test_UpdateValidatorSet() public {
        address val4 = vm.addr(0xDE4D);

        address[] memory newVals = new address[](2);
        uint256[] memory newPowers = new uint256[](2);
        // Must be sorted ascending
        if (vals[0] < val4) {
            newVals[0] = vals[0]; newPowers[0] = 50;
            newVals[1] = val4;    newPowers[1] = 30;
        } else {
            newVals[0] = val4;    newPowers[0] = 30;
            newVals[1] = vals[0]; newPowers[1] = 50;
        }

        // Hash the new validator set
        bytes memory valsetData = abi.encode(uint256(1), uint256(2));
        for (uint i = 0; i < newVals.length; i++) {
            valsetData = abi.encodePacked(valsetData, newVals[i], newPowers[i]);
        }
        bytes32 valsetHash = keccak256(valsetData);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valsetHash));

        // Sign with 2/3+ of current set (sorted)
        uint[] memory idx = new uint[](2);
        idx[0] = 0; idx[1] = 1;
        address[] memory signers = new address[](2);
        uint8[] memory vs = new uint8[](2);
        bytes32[] memory rs = new bytes32[](2);
        bytes32[] memory ss = new bytes32[](2);
        for (uint i = 0; i < 2; i++) {
            signers[i] = vals[idx[i]];
            (vs[i], rs[i], ss[i]) = vm.sign(pks[idx[i]], ethHash);
        }

        verifier.updateValidatorSet(2, newVals, newPowers, signers, vs, rs, ss);

        assertEq(verifier.currentValsetNonce(), 2);
        assertEq(verifier.totalPower(), 80);
    }

    function test_MessageDeliveryFailure_DoesNotBlock() public {
        gateway.setRevert(true);

        bytes[] memory messages = new bytes[](2);
        messages[0] = hex"000102";
        messages[1] = hex"030405";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        uint[] memory idx = new uint[](2);
        idx[0] = 0; idx[1] = 1;
        (address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss)
            = _buildSorted(idx, messagesHash, 1, 101);

        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);
        assertEq(verifier.lastCheckpointNonce(101), 1);
        assertEq(gateway.getDeliveredCount(), 0);
    }

    function test_Pause() public {
        verifier.pause();

        bytes[] memory messages = new bytes[](1);
        messages[0] = hex"00";
        bytes32 messagesHash = keccak256(abi.encode(messages));

        uint[] memory idx = new uint[](2);
        idx[0] = 0; idx[1] = 1;
        (address[] memory signers, uint8[] memory vs, bytes32[] memory rs, bytes32[] memory ss)
            = _buildSorted(idx, messagesHash, 1, 101);

        vm.expectRevert("Pausable: paused");
        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);

        verifier.unpause();
        verifier.verifyAndDeliver(1, 101, messagesHash, messages, signers, vs, rs, ss);
        assertEq(verifier.lastCheckpointNonce(101), 1);
    }
}
