pragma solidity ^0.8.19;

import {BaseScript} from "./BaseScript.sol";
import {NetworkConstants} from "../src/libraries/NetworkConstants.sol";
import {CREATE3_FACTORY} from "../lib/create3-factory/src/ICREATE3Factory.sol";

contract DeployNetworkConstants is BaseScript {

    bytes32 salt;

    function setUp() public virtual override {
        // load keys
        super.setUp();
        salt = keccak256(abi.encodePacked("NetworkConstants"));
        require(CREATE3_FACTORY.getDeployed(owner.addr, salt).code.length == 0, "Salt already taken");
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(owner.privateKey);

        bytes memory creationCode = type(NetworkConstants).creationCode;

        address libraryAddress = CREATE3_FACTORY.deploy(salt, creationCode);

        vm.stopBroadcast();

        string memory subkey = vm.serializeAddress(
            "sepolia",
            "networkConstants",
            libraryAddress
        );

        string memory finalJson = vm.serializeString("libraries", "sepolia", subkey);

        vm.writeJson(finalJson, "script/deployments/libraries.json");
    }

}
