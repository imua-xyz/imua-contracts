pragma solidity ^0.8.19;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Bootstrap} from "../src/core/Bootstrap.sol";
import {ClientChainGateway} from "../src/core/ClientChainGateway.sol";

import {ImuaCapsule} from "../src/core/ImuaCapsule.sol";

import {RewardVault} from "../src/core/RewardVault.sol";
import {Vault} from "../src/core/Vault.sol";
import "../src/utils/BeaconProxyBytecode.sol";
import {CustomProxyAdmin} from "../src/utils/CustomProxyAdmin.sol";

import {BaseScript} from "./BaseScript.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

import {BootstrapStorage} from "../src/storage/BootstrapStorage.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";

import {CREATE3_FACTORY} from "../lib/create3-factory/src/ICREATE3Factory.sol";

contract DeployBootstrapOnly is BaseScript {

    address wstETH;
    bytes32 salt;

    function setUp() public virtual override {
        // load keys
        super.setUp();
        // load contracts
        string memory prerequisiteContracts = vm.readFile("script/deployments/prerequisiteContracts.json");
        clientChainLzEndpoint = ILayerZeroEndpointV2(
            stdJson.readAddress(prerequisiteContracts, string.concat(".", clientChainName, ".lzEndpoint"))
        );
        require(address(clientChainLzEndpoint) != address(0), "Client chain endpoint not found");
        restakeToken = ERC20PresetFixedSupply(
            stdJson.readAddress(prerequisiteContracts, string.concat(".", clientChainName, ".erc20Token"))
        );
        require(address(restakeToken) != address(0), "Restake token not found");
        // we should use the pre-requisite to save gas instead of deploying our own
        beaconOracle = EigenLayerBeaconOracle(
            stdJson.readAddress(prerequisiteContracts, string.concat(".", clientChainName, ".beaconOracle"))
        );
        require(address(beaconOracle) != address(0), "Beacon oracle not found");
        // same for BeaconProxyBytecode
        beaconProxyBytecode = BeaconProxyBytecode(
            stdJson.readAddress(prerequisiteContracts, string.concat(".", clientChainName, ".beaconProxyBytecode"))
        );
        require(address(beaconProxyBytecode) != address(0), "Beacon proxy bytecode not found");
        // wstETH on Sepolia
        // https://docs.lido.fi/deployed-contracts/sepolia/
        wstETH = stdJson.readAddress(prerequisiteContracts, string.concat(".", clientChainName, ".wstETH"));
        require(wstETH != address(0), "wstETH not found");
        // salt is automatically scoped to the deployer address
        salt = keccak256(abi.encodePacked("Bootstrap"));
        // check that the salt is not already taken
        address deployed = CREATE3_FACTORY.getDeployed(owner.addr, salt);
        console.log("deployed", deployed);
        // require(deployed.code.length == 0, "Salt already taken");
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(owner.privateKey);
        whitelistTokens.push(address(restakeToken));
        tvlLimits.push(restakeToken.totalSupply() / 20);
        whitelistTokens.push(wstETH);
        // doesn't matter if it's actually ERC20PresetFixedSupply, just need the total supply
        tvlLimits.push(ERC20PresetFixedSupply(wstETH).totalSupply() / 20);

        // proxy deployment
        clientChainProxyAdmin = new CustomProxyAdmin();

        // do not deploy beacon chain oracle, instead use the pre-requisite

        /// deploy vault implementation contract, capsule implementation contract, reward vault implementation contract
        /// that has logics called by proxy
        vaultImplementation = new Vault();
        capsuleImplementation = new ImuaCapsule(address(0));

        /// deploy the vault beacon, capsule beacon, reward vault beacon that store the implementation contract address
        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));

        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainEndpointId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        // bootstrap logic
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);

        // client chain constructor
        rewardVaultImplementation = new RewardVault();
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));
        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        // then the client chain initialization
        bytes memory initialization = abi.encodeWithSelector(clientGatewayLogic.initialize.selector, owner.addr);

        // bootstrap proxy, it should be deployed using CREATE3
        bytes memory bootstrapInit = abi.encodeCall(
            Bootstrap.initialize,
            (
                owner.addr,
                block.timestamp + 168 hours,
                2 seconds,
                whitelistTokens,
                tvlLimits,
                address(clientChainProxyAdmin),
                address(clientGatewayLogic),
                initialization
            )
        );
        bytes memory creationCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(address(bootstrapLogic), address(clientChainProxyAdmin), bootstrapInit)
        );
        Bootstrap bootstrap = Bootstrap(payable(CREATE3_FACTORY.deploy(salt, creationCode)));

        // initialize proxyAdmin with bootstrap address
        clientChainProxyAdmin.initialize(address(bootstrap));

        vm.stopBroadcast();

        string memory clientChainContracts = "clientChainContracts";
        vm.serializeAddress(clientChainContracts, "lzEndpoint", address(clientChainLzEndpoint));
        vm.serializeAddress(clientChainContracts, "erc20Token", address(restakeToken));
        vm.serializeAddress(clientChainContracts, "wstETH", wstETH);
        vm.serializeAddress(clientChainContracts, "proxyAdmin", address(clientChainProxyAdmin));
        vm.serializeAddress(clientChainContracts, "vaultImplementation", address(vaultImplementation));
        vm.serializeAddress(clientChainContracts, "vaultBeacon", address(vaultBeacon));
        vm.serializeAddress(clientChainContracts, "beaconProxyBytecode", address(beaconProxyBytecode));
        vm.serializeAddress(clientChainContracts, "bootstrapLogic", address(bootstrapLogic));
        vm.serializeAddress(clientChainContracts, "bootstrap", address(bootstrap));
        vm.serializeAddress(clientChainContracts, "beaconOracle", address(beaconOracle));
        vm.serializeAddress(clientChainContracts, "capsuleImplementation", address(capsuleImplementation));
        vm.serializeAddress(clientChainContracts, "capsuleBeacon", address(capsuleBeacon));
        vm.serializeAddress(clientChainContracts, "rewardVaultImplementation", address(rewardVaultImplementation));
        vm.serializeAddress(clientChainContracts, "rewardVaultBeacon", address(rewardVaultBeacon));
        string memory clientChainContractsOutput =
            vm.serializeAddress(clientChainContracts, "clientGatewayLogic", address(clientGatewayLogic));

        string memory deployedContracts = "deployedContracts";
        string memory finalJson = vm.serializeString(deployedContracts, clientChainName, clientChainContractsOutput);

        vm.writeJson(finalJson, "script/deployments/deployedBootstrapOnly.json");
    }

}
