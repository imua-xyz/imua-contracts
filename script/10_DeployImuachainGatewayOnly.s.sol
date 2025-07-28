pragma solidity ^0.8.19;

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ImuachainGateway} from "../src/core/ImuachainGateway.sol";

import {BaseScript} from "./BaseScript.sol";
import "forge-std/Script.sol";

import {CREATE3_FACTORY} from "../lib/create3-factory/src/ICREATE3Factory.sol";

contract DeployImuachainGatewayOnly is BaseScript {

    bytes32 salt;

    function setUp() public virtual override {
        // load keys
        super.setUp();
        // load contracts
        string memory prerequisites = vm.readFile("script/deployments/prerequisiteContracts.json");
        imuachainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(prerequisites, ".imuachain.lzEndpoint"));
        require(address(imuachainLzEndpoint) != address(0), "imuachain l0 endpoint should not be empty");
        salt = keccak256(abi.encodePacked("imuachaintestnet_233-8"));
    }

    function run() public {
        vm.selectFork(imuachain);
        // use the owner so that it owns the ProxyAdmin
        vm.startBroadcast(owner.privateKey);
        ProxyAdmin imuachainProxyAdmin = new ProxyAdmin();
        ImuachainGateway imuachainGatewayLogic = new ImuachainGateway(address(imuachainLzEndpoint));

        bytes memory initialization =
            abi.encodeWithSelector(imuachainGatewayLogic.initialize.selector, payable(owner.addr));

        bytes memory creationCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(address(imuachainGatewayLogic), address(imuachainProxyAdmin), initialization)
        );
        ImuachainGateway imuachainGateway = ImuachainGateway(payable(CREATE3_FACTORY.deploy(salt, creationCode)));

        vm.stopBroadcast();

        string memory imuachainContracts = "imuachainContracts";
        vm.serializeAddress(imuachainContracts, "lzEndpoint", address(imuachainLzEndpoint));
        vm.serializeAddress(imuachainContracts, "imuachainGatewayLogic", address(imuachainGatewayLogic));
        vm.serializeAddress(imuachainContracts, "imuachainProxyAdmin", address(imuachainProxyAdmin));
        string memory imuachainContractsOutput =
            vm.serializeAddress(imuachainContracts, "imuachainGateway", address(imuachainGateway));

        string memory deployedContracts = "deployedContracts";
        string memory finalJson = vm.serializeString(deployedContracts, "imuachain", imuachainContractsOutput);

        vm.writeJson(finalJson, "script/deployments/deployedImuachainGatewayOnly.json");
    }

}
