pragma solidity ^0.8.19;

import "../src/interfaces/IClientChainGateway.sol";

import "../src/interfaces/IImuachainGateway.sol";
import "../src/interfaces/IVault.sol";

import "../src/storage/GatewayStorage.sol";

import {BaseScript} from "./BaseScript.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

import "forge-std/StdJson.sol";

contract DepositScript is BaseScript {

    using AddressCast for address;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployments/deployedContracts.json");

        clientGateway =
            IClientChainGateway(payable(stdJson.readAddress(deployedContracts, ".clientChain.clientChainGateway")));
        require(address(clientGateway) != address(0), "clientGateway address should not be empty");

        if (!useImuachainPrecompileMock) {
            _bindPrecompileMocks();
        }

        // transfer some gas fee to depositor, relayer and imuachain gateway
        clientChain = vm.createSelectFork(clientChainRPCURL);
        _topUpPlayer(clientChain, address(0), deployer, depositor.addr, 0.2 ether);

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, address(imuachainGateway), 1 ether);
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(depositor.privateKey);

        address capsule = clientGateway.createImuaCapsule();

        vm.stopBroadcast();

        string memory capsulesJson = "capsule1";
        vm.serializeAddress(capsulesJson, "owner", depositor.addr);
        string memory capsulesOutput = vm.serializeAddress(capsulesJson, "capsule", capsule);

        vm.writeJson(capsulesOutput, "script/deployments/capsule.json");
    }

}
