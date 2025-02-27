pragma solidity ^0.8.19;

import {ImuaCapsule} from "../src/core/ImuaCapsule.sol";
import "./BaseScript.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "forge-std/Script.sol";

contract UpgradeImuaCapsuleScript is BaseScript {

    UpgradeableBeacon capsuleBeaconContract;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployments/deployedContracts.json");

        capsuleBeaconContract =
            UpgradeableBeacon((stdJson.readAddress(deployedContracts, ".clientChain.capsuleBeacon")));
        require(address(capsuleBeaconContract) != address(0), "capsuleBeacon address should not be empty");
        clientChain = vm.createSelectFork(clientChainRPCURL);
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(deployer.privateKey);
        console.log("owner", capsuleBeaconContract.owner());
        ImuaCapsule capsule = new ImuaCapsule(address(0));
        capsuleBeaconContract.upgradeTo(address(capsule));
        vm.stopBroadcast();

        console.log("new ImuaCapsule Implementation address: ", address(capsule));
    }

}
