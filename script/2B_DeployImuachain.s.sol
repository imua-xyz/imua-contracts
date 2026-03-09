pragma solidity ^0.8.19;

import "../src/core/ImuachainGateway.sol";
import {ImuachainGatewayMock} from "../test/mocks/ImuachainGatewayMock.sol";
import {BaseScript} from "./BaseScript.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Script.sol";

/// @dev Single-chain deployment helper to avoid Foundry multi-fork + library-link limitation.
/// Set only `IMUACHAIN_TESTNET_RPC` (do NOT set `CLIENT_CHAIN_RPC`) when running this script.
contract DeployImuachainScript is BaseScript {

    function setUp() public virtual override {
        super.setUp();
        require(imuachain != 0, "IMUACHAIN_TESTNET_RPC not set");

        string memory prerequisites = vm.readFile("script/deployments/prerequisiteContracts.json");
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
    }

    function run() public {
        vm.selectFork(imuachain);
        vm.startBroadcast(deployer.privateKey);

        ProxyAdmin imuachainProxyAdmin = new ProxyAdmin();

        if (useImuachainPrecompileMock) {
            ImuachainGatewayMock imuachainGatewayLogic =
                new ImuachainGatewayMock(address(imuachainLzEndpoint), assetsMock, rewardMock, delegationMock);
            imuachainGateway = ImuachainGateway(
                payable(address(
                        new TransparentUpgradeableProxy(
                            address(imuachainGatewayLogic),
                            address(imuachainProxyAdmin),
                            abi.encodeWithSelector(imuachainGatewayLogic.initialize.selector, payable(owner.addr))
                        )
                    ))
            );
        } else {
            ImuachainGateway imuachainGatewayLogic = new ImuachainGateway(address(imuachainLzEndpoint));
            imuachainGateway = ImuachainGateway(
                payable(address(
                        new TransparentUpgradeableProxy(
                            address(imuachainGatewayLogic),
                            address(imuachainProxyAdmin),
                            abi.encodeWithSelector(imuachainGatewayLogic.initialize.selector, payable(owner.addr))
                        )
                    ))
            );
        }

        vm.stopBroadcast();

        // Merge with existing client-chain section from 2A output
        string memory deployedContractsStr = vm.readFile("script/deployments/deployedContracts.json");
        // allow overriding in case local client chain isn't sepolia
        string memory clientName = vm.envOr("CLIENT_CHAIN_NAME", string("sepolia"));

        // re-read client section and re-serialize it (vm.writeJson does not merge)
        string memory deployedContracts = "deployedContracts";
        string memory clientChainContracts = "clientChainContracts";
        vm.serializeAddress(
            clientChainContracts,
            "lzEndpoint",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".lzEndpoint"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "beaconOracle",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".beaconOracle"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "clientChainGateway",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".clientChainGateway"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "resVault",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".resVault"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "rewardVault",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".rewardVault"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "erc20Token",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".erc20Token"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "vaultBeacon",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".vaultBeacon"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "rewardVaultBeacon",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".rewardVaultBeacon"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "capsuleBeacon",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".capsuleBeacon"))
        );
        vm.serializeAddress(
            clientChainContracts,
            "beaconProxyBytecode",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".beaconProxyBytecode"))
        );
        string memory clientChainContractsOutput = vm.serializeAddress(
            clientChainContracts,
            "proxyAdmin",
            stdJson.readAddress(deployedContractsStr, string.concat(".", clientName, ".proxyAdmin"))
        );

        // serialize imuachain section
        string memory imuachainContracts = "imuachainContracts";
        vm.serializeAddress(imuachainContracts, "lzEndpoint", address(imuachainLzEndpoint));
        vm.serializeAddress(imuachainContracts, "imuachainGateway", address(imuachainGateway));
        if (useImuachainPrecompileMock) {
            vm.serializeAddress(imuachainContracts, "assetsPrecompileMock", assetsMock);
            vm.serializeAddress(imuachainContracts, "delegationPrecompileMock", delegationMock);
            vm.serializeAddress(imuachainContracts, "rewardPrecompileMock", rewardMock);
        }
        string memory imuachainContractsOutput =
            vm.serializeAddress(imuachainContracts, "proxyAdmin", address(imuachainProxyAdmin));

        vm.serializeString(deployedContracts, clientName, clientChainContractsOutput);
        string memory finalJson = vm.serializeString(deployedContracts, "imuachain", imuachainContractsOutput);
        vm.writeJson(finalJson, "script/deployments/deployedContracts.json");
    }

}
