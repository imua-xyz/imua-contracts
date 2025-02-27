pragma solidity ^0.8.19;

import "../src/core/ClientChainGateway.sol";
import "../src/core/ImuaCapsule.sol";
import "../src/core/ImuachainGateway.sol";

import {RewardVault} from "../src/core/RewardVault.sol";
import {Vault} from "../src/core/Vault.sol";
import {NetworkConstants} from "../src/libraries/NetworkConstants.sol";
import "../src/utils/BeaconProxyBytecode.sol";
import "../src/utils/CustomProxyAdmin.sol";
import {ImuachainGatewayMock} from "../test/mocks/ImuachainGatewayMock.sol";

import {BootstrapStorage} from "../src/storage/BootstrapStorage.sol";
import {BaseScript} from "./BaseScript.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

contract DeployScript is BaseScript {

    function setUp() public virtual override {
        super.setUp();

        string memory prerequisites = vm.readFile("script/deployments/prerequisiteContracts.json");

        clientChainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(prerequisites, ".clientChain.lzEndpoint"));
        require(address(clientChainLzEndpoint) != address(0), "client chain l0 endpoint should not be empty");

        restakeToken = ERC20PresetFixedSupply(stdJson.readAddress(prerequisites, ".clientChain.erc20Token"));
        require(address(restakeToken) != address(0), "restake token address should not be empty");

        imuachainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(prerequisites, ".imuachain.lzEndpoint"));
        require(address(imuachainLzEndpoint) != address(0), "imuachain l0 endpoint should not be empty");

        if (useImuachainPrecompileMock) {
            assetsMock = stdJson.readAddress(prerequisites, ".imuachain.assetsPrecompileMock");
            require(assetsMock != address(0), "assetsMock should not be empty");

            delegationMock = stdJson.readAddress(prerequisites, ".imuachain.delegationPrecompileMock");
            require(delegationMock != address(0), "delegationMock should not be empty");

            rewardMock = stdJson.readAddress(prerequisites, ".imuachain.rewardPrecompileMock");
            require(rewardMock != address(0), "rewardMock should not be empty");
        }

        clientChain = vm.createSelectFork(clientChainRPCURL);

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, deployer.addr, 1 ether);
    }

    function run() public {
        // deploy clientchaingateway on client chain via rpc
        vm.selectFork(clientChain);
        vm.startBroadcast(deployer.privateKey);

        // deploy beacon chain oracle
        beaconOracle = new EigenLayerBeaconOracle(NetworkConstants.getBeaconGenesisTimestamp());

        /// deploy implementations and beacons
        vaultImplementation = new Vault();
        capsuleImplementation = new ImuaCapsule(address(0));
        rewardVaultImplementation = new RewardVault();

        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));

        beaconProxyBytecode = new BeaconProxyBytecode();
        clientChainProxyAdmin = new CustomProxyAdmin();

        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        /// deploy client chain gateway
        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        clientGateway = ClientChainGateway(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(clientGatewayLogic),
                        address(clientChainProxyAdmin),
                        abi.encodeWithSelector(clientGatewayLogic.initialize.selector, payable(owner.addr))
                    )
                )
            )
        );

        // get the reward vault address since it would be deployed during initialization
        rewardVault = ClientChainGateway(payable(address(clientGateway))).rewardVault();
        require(address(rewardVault) != address(0), "reward vault should not be empty");

        // find vault according to uderlying token address
        vault = Vault(address(ClientChainGateway(payable(address(clientGateway))).tokenToVault(address(restakeToken))));
        require(address(vault) != address(0), "vault should not be empty");

        vm.stopBroadcast();

        // deploy on Imuachain via rpc
        vm.selectFork(imuachain);
        vm.startBroadcast(deployer.privateKey);

        // deploy Imuachain network contracts
        ProxyAdmin imuachainProxyAdmin = new ProxyAdmin();

        if (useImuachainPrecompileMock) {
            ImuachainGatewayMock imuachainGatewayLogic =
                new ImuachainGatewayMock(address(imuachainLzEndpoint), assetsMock, rewardMock, delegationMock);
            imuachainGateway = ImuachainGateway(
                payable(
                    address(
                        new TransparentUpgradeableProxy(
                            address(imuachainGatewayLogic),
                            address(imuachainProxyAdmin),
                            abi.encodeWithSelector(imuachainGatewayLogic.initialize.selector, payable(owner.addr))
                        )
                    )
                )
            );
        } else {
            ImuachainGateway imuachainGatewayLogic = new ImuachainGateway(address(imuachainLzEndpoint));
            imuachainGateway = ImuachainGateway(
                payable(
                    address(
                        new TransparentUpgradeableProxy(
                            address(imuachainGatewayLogic),
                            address(imuachainProxyAdmin),
                            abi.encodeWithSelector(imuachainGatewayLogic.initialize.selector, payable(owner.addr))
                        )
                    )
                )
            );
        }

        vm.stopBroadcast();

        string memory deployedContracts = "deployedContracts";
        string memory clientChainContracts = "clientChainContracts";
        string memory imuachainContracts = "imuachainContracts";
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

        vm.serializeAddress(imuachainContracts, "lzEndpoint", address(imuachainLzEndpoint));
        vm.serializeAddress(imuachainContracts, "imuachainGateway", address(imuachainGateway));

        if (useImuachainPrecompileMock) {
            vm.serializeAddress(imuachainContracts, "assetsPrecompileMock", assetsMock);
            vm.serializeAddress(imuachainContracts, "delegationPrecompileMock", delegationMock);
            vm.serializeAddress(imuachainContracts, "rewardPrecompileMock", rewardMock);
        }

        string memory imuachainContractsOutput =
            vm.serializeAddress(imuachainContracts, "proxyAdmin", address(imuachainProxyAdmin));

        vm.serializeString(deployedContracts, "clientChain", clientChainContractsOutput);
        string memory finalJson = vm.serializeString(deployedContracts, "imuachain", imuachainContractsOutput);

        vm.writeJson(finalJson, "script/deployments/deployedContracts.json");
    }

}
