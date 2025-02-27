pragma solidity ^0.8.19;

import {Bootstrap} from "../src/core/Bootstrap.sol";
import {ImuachainGateway} from "../src/core/ImuachainGateway.sol";
import {Action, GatewayStorage} from "../src/storage/GatewayStorage.sol";

import {BaseScript} from "./BaseScript.sol";
import "forge-std/Script.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";

contract SetPeersAndUpgrade is BaseScript {

    using AddressCast for address;

    address bootstrapAddr;
    address imuachainGatewayAddr;

    function setUp() public virtual override {
        // load keys
        super.setUp();
        // load contracts
        string memory deployed = vm.readFile("script/deployments/deployedBootstrapOnly.json");
        bootstrapAddr = stdJson.readAddress(deployed, ".clientChain.bootstrap");
        require(address(bootstrapAddr) != address(0), "bootstrap address should not be empty");
        deployed = vm.readFile("script/deployments/deployedImuachainGatewayOnly.json");
        imuachainGatewayAddr = stdJson.readAddress(deployed, ".imuachain.imuachainGateway");
        require(address(imuachainGatewayAddr) != address(0), "imuachain gateway address should not be empty");
        // forks
        imuachain = vm.createSelectFork(imuachainRPCURL);
        clientChain = vm.createSelectFork(clientChainRPCURL);
    }

    function run() public {
        ImuachainGateway gateway = ImuachainGateway(payable(imuachainGatewayAddr));

        vm.selectFork(imuachain);
        if (!useImuachainPrecompileMock) {
            _bindPrecompileMocks();
        }
        vm.startBroadcast(owner.privateKey);
        gateway.setPeer(clientChainId, bootstrapAddr.toBytes32());
        vm.stopBroadcast();

        Bootstrap bootstrap = Bootstrap(payable(bootstrapAddr));

        vm.selectFork(clientChain);
        vm.startBroadcast(owner.privateKey);
        bootstrap.setPeer(imuachainChainId, address(imuachainGatewayAddr).toBytes32());
        vm.stopBroadcast();

        vm.selectFork(imuachain);
        vm.startBroadcast(owner.privateKey);
        uint256 nativeFee = imuachainGateway.quote(clientChainId, abi.encodePacked(Action.REQUEST_MARK_BOOTSTRAP, ""));
        imuachainGateway.markBootstrap{value: nativeFee}(clientChainId);
    }

}
