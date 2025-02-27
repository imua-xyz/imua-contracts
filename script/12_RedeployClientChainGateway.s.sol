pragma solidity ^0.8.19;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Bootstrap} from "../src/core/Bootstrap.sol";

import {ClientChainGateway} from "../src/core/ClientChainGateway.sol";
import {BootstrapStorage} from "../src/storage/BootstrapStorage.sol";

import {ImuaCapsule} from "../src/core/ImuaCapsule.sol";

import {RewardVault} from "../src/core/RewardVault.sol";
import {Vault} from "../src/core/Vault.sol";
import "../src/utils/BeaconProxyBytecode.sol";
import {CustomProxyAdmin} from "../src/utils/CustomProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {BaseScript} from "./BaseScript.sol";

import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

contract RedeployClientChainGateway is BaseScript {

    Bootstrap bootstrap;

    function setUp() public virtual override {
        // load keys
        super.setUp();
        // load contracts
        string memory prerequisiteContracts = vm.readFile("script/deployments/deployedBootstrapOnly.json");
        clientChainLzEndpoint =
            ILayerZeroEndpointV2(stdJson.readAddress(prerequisiteContracts, ".clientChain.lzEndpoint"));
        require(address(clientChainLzEndpoint) != address(0), "client chain l0 endpoint should not be empty");
        beaconOracle = EigenLayerBeaconOracle(stdJson.readAddress(prerequisiteContracts, ".clientChain.beaconOracle"));
        require(address(beaconOracle) != address(0), "beacon oracle should not be empty");
        vaultBeacon = UpgradeableBeacon(stdJson.readAddress(prerequisiteContracts, ".clientChain.vaultBeacon"));
        require(address(vaultBeacon) != address(0), "vault beacon should not be empty");
        rewardVaultBeacon =
            UpgradeableBeacon(stdJson.readAddress(prerequisiteContracts, ".clientChain.rewardVaultBeacon"));
        require(address(rewardVaultBeacon) != address(0), "reward vault beacon should not be empty");
        capsuleBeacon = UpgradeableBeacon(stdJson.readAddress(prerequisiteContracts, ".clientChain.capsuleBeacon"));
        require(address(capsuleBeacon) != address(0), "capsule beacon should not be empty");
        beaconProxyBytecode =
            BeaconProxyBytecode(stdJson.readAddress(prerequisiteContracts, ".clientChain.beaconProxyBytecode"));
        require(address(beaconProxyBytecode) != address(0), "beacon proxy bytecode should not be empty");
        bootstrap = Bootstrap(stdJson.readAddress(prerequisiteContracts, ".clientChain.bootstrap"));
        require(address(bootstrap) != address(0), "bootstrap should not be empty");
        clientChainProxyAdmin = CustomProxyAdmin(stdJson.readAddress(prerequisiteContracts, ".clientChain.proxyAdmin"));
        require(address(clientChainProxyAdmin) != address(0), "client chain proxy admin should not be empty");
        clientChain = vm.createSelectFork(clientChainRPCURL);
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(owner.privateKey);

        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        // Update ClientChainGateway constructor call
        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        // then the client chain initialization
        bytes memory initialization = abi.encodeWithSelector(clientGatewayLogic.initialize.selector, owner.addr);
        bootstrap.setClientChainGatewayLogic(address(clientGatewayLogic), initialization);
        vm.stopBroadcast();

        string memory clientChainContracts = "clientChainContracts";
        string memory clientChainContractsOutput =
            vm.serializeAddress(clientChainContracts, "clientGatewayLogic", address(clientGatewayLogic));

        string memory deployedContracts = "deployedContracts";
        string memory finalJson = vm.serializeString(deployedContracts, "clientChain", clientChainContractsOutput);

        vm.writeJson(finalJson, "script/deployments/redeployClientChainGateway.json");
    }

}
