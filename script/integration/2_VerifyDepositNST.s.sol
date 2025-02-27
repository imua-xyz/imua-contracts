// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "forge-std/StdJson.sol";
import "forge-std/console.sol";

import {Bootstrap} from "../../src/core/Bootstrap.sol";

import {BeaconOracle} from "./BeaconOracle.sol";
import {ALLOWED_CHAIN_ID} from "./NetworkConfig.sol";

import {BeaconChainProofs} from "src/libraries/BeaconChainProofs.sol";
import {Endian} from "src/libraries/Endian.sol";

contract VerifyDepositNST is Script {

    using Endian for bytes32;
    using stdJson for string;

    BeaconChainProofs.ValidatorContainerProof validatorProof;
    bytes32 beaconBlockRoot;

    address bootstrapAddress;
    address beaconOracleAddress;
    uint256 nstDepositor;

    function setUp() public virtual {
        // obtain the address
        string memory deployments = vm.readFile("script/integration/deployments.json");
        bootstrapAddress = deployments.readAddress(".bootstrapAddress");
        require(bootstrapAddress != address(0), "Bootstrap address not found");
        beaconOracleAddress = deployments.readAddress(".beaconOracleAddress");
        require(beaconOracleAddress != address(0), "BeaconOracle address not found");
        nstDepositor = vm.envOr(
            "INTEGRATION_NST_DEPOSITOR", uint256(0x47c99abed3324a2707c28affff1267e45918ec8c3f20b8aa892e8b065d2942dd)
        );
        require(nstDepositor != 0, "INTEGRATION_NST_DEPOSITOR not set");
    }

    function run() external {
        bytes32[] memory validatorContainer;
        vm.startBroadcast(nstDepositor);
        Bootstrap bootstrap = Bootstrap(bootstrapAddress);
        require(vm.exists("script/integration/proof.json"), "Proof file not found");
        string memory data = vm.readFile("script/integration/proof.json");
        // load the validator container
        validatorContainer = data.readBytes32Array(".validatorContainer");
        // load the validator proof
        // we don't validate it; that task is left to the contract. it is a test, after all.
        validatorProof = BeaconChainProofs.ValidatorContainerProof({
            stateRoot: data.readBytes32(".stateRoot"),
            stateRootProof: data.readBytes32Array(".stateRootProof"),
            validatorContainerRootProof: data.readBytes32Array(".validatorContainerProof"),
            validatorIndex: data.readUint(".validatorIndex"),
            beaconBlockTimestamp: data.readUint(".timestamp")
        });
        // since the oracle is not necessarily active during integration testing, trigger it manually
        BeaconOracle oracle = BeaconOracle(beaconOracleAddress);
        oracle.addTimestamp(validatorProof.beaconBlockTimestamp);
        // now, the transactions
        bootstrap.verifyAndDepositNativeStake(validatorContainer, validatorProof);
        bootstrap.delegateTo(
            // a validator in 1_DeployBootstrap.s.sol
            "im1rtg0cgw94ep744epyvanc0wdd5kedwqlw008ex",
            // the native token address
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            // delegate only a small portion of the deposit for our test
            18 ether
        );
        vm.stopBroadcast();
    }

}
