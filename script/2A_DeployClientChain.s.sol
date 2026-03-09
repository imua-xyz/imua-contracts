// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/core/ClientChainGateway.sol";
import "../src/core/ImuaCapsule.sol";
import "../src/core/ImuaCapsuleBSC.sol";
import {RewardVault} from "../src/core/RewardVault.sol";
import {Vault} from "../src/core/Vault.sol";
import {NetworkConstants} from "../src/libraries/NetworkConstants.sol";
import "../src/utils/BeaconProxyBytecode.sol";
import "../src/utils/CustomProxyAdmin.sol";

import {BootstrapStorage} from "../src/storage/BootstrapStorage.sol";
import {BaseScript} from "./BaseScript.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

/// @dev Single-chain deployment helper to avoid Foundry multi-fork + library-link limitation.
/// Set only `CLIENT_CHAIN_RPC` (do NOT set `IMUACHAIN_TESTNET_RPC`) when running this script.
contract DeployClientChainScript is BaseScript {

    function setUp() public virtual override {
        super.setUp();
        require(clientChain != 0, "CLIENT_CHAIN_RPC not set");

        string memory prerequisites = vm.readFile("script/deployments/prerequisiteContracts.json");
        clientChainLzEndpoint = ILayerZeroEndpointV2(
            stdJson.readAddress(prerequisites, string.concat(".", clientChainName, ".lzEndpoint"))
        );
        require(address(clientChainLzEndpoint) != address(0), "client chain l0 endpoint should not be empty");

        restakeToken = ERC20PresetFixedSupply(
            stdJson.readAddress(prerequisites, string.concat(".", clientChainName, ".erc20Token"))
        );
        require(address(restakeToken) != address(0), "restake token address should not be empty");
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(deployer.privateKey);

        // deploy beacon chain oracle (needs NetworkConstants library linking)
        beaconOracle = new EigenLayerBeaconOracle(NetworkConstants.getBeaconGenesisTimestamp());

        // deploy implementations and beacons
        vaultImplementation = new Vault();
        if (vm.envOr("USE_BNB_CAPSULE", false)) {
            capsuleImplementation = new ImuaCapsuleBSC();
        } else {
            capsuleImplementation = new ImuaCapsule(address(0));
        }
        rewardVaultImplementation = new RewardVault();

        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));

        beaconProxyBytecode = new BeaconProxyBytecode();
        clientChainProxyAdmin = new CustomProxyAdmin();

        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainEndpointId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        clientGateway = ClientChainGateway(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(clientGatewayLogic),
                        address(clientChainProxyAdmin),
                        abi.encodeWithSelector(clientGatewayLogic.initialize.selector, payable(owner.addr))
                    )
                ))
        );

        // deploy reward vault (requires owner)
        vm.stopBroadcast();
        vm.startBroadcast(owner.privateKey);
        ClientChainGateway(payable(address(clientGateway))).deployRewardVault();
        vm.stopBroadcast();

        // read back created addresses
        rewardVault = ClientChainGateway(payable(address(clientGateway))).rewardVault();
        require(address(rewardVault) != address(0), "reward vault should not be empty");

        // NOTE: LST vaults are deployed only after the whitelist-token message is received from Imuachain
        // (see ClientGatewayLzReceiver.afterReceiveAddWhitelistTokenRequest). So at deploy time this is empty.
        vault = Vault(address(0));

        // Write a partial deployedContracts.json (client section only). 2B will merge in imuachain section.
        string memory deployedContracts = "deployedContracts";
        string memory clientChainContracts = "clientChainContracts";
        vm.serializeAddress(clientChainContracts, "lzEndpoint", address(clientChainLzEndpoint));
        vm.serializeAddress(clientChainContracts, "beaconOracle", address(beaconOracle));
        vm.serializeAddress(clientChainContracts, "clientChainGateway", address(clientGateway));
        vm.serializeAddress(clientChainContracts, "resVault", address(vault));
        vm.serializeAddress(clientChainContracts, "rewardVault", address(rewardVault));
        vm.serializeAddress(clientChainContracts, "erc20Token", address(restakeToken));
        vm.serializeAddress(clientChainContracts, "vaultBeacon", address(vaultBeacon));
        vm.serializeAddress(clientChainContracts, "rewardVaultBeacon", address(rewardVaultBeacon));
        vm.serializeAddress(clientChainContracts, "capsuleBeacon", address(capsuleBeacon));
        vm.serializeAddress(clientChainContracts, "beaconProxyBytecode", address(beaconProxyBytecode));
        string memory clientChainContractsOutput =
            vm.serializeAddress(clientChainContracts, "proxyAdmin", address(clientChainProxyAdmin));

        string memory finalJson = vm.serializeString(deployedContracts, clientChainName, clientChainContractsOutput);
        vm.writeJson(finalJson, "script/deployments/deployedContracts.json");
    }

}
