// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {UTXOGateway} from "../src/core/UTXOGateway.sol";
import {UTXOChainActivator} from "../src/libraries/UTXOChainActivator.sol";

import {CREATE3_FACTORY} from "../lib/create3-factory/src/ICREATE3Factory.sol";
import {BaseScript} from "./BaseScript.sol";
import "forge-std/Script.sol";

/**
 * @title DeployUTXOGateway
 * @notice Deploys or upgrades UTXOGateway on Imuachain. UTXOGateway uses the external
 *         UTXOChainActivator library, so deployment is two-step:
 *
 *   FRESH DEPLOY:
 *     1. Deploy library (no --libraries):
 *        forge script script/24_DeployUTXOGateway.s.sol:DeployUTXOGateway --sig "deployLibrary()" --broadcast --rpc-url
 * $IMUACHAIN_TESTNET_RPC
 *     2. Deploy gateway (pass library from step 1):
 *        forge script script/24_DeployUTXOGateway.s.sol:DeployUTXOGateway --sig "run(address,uint256)" --broadcast \
 *          --libraries src/libraries/UTXOChainActivator.sol:UTXOChainActivator:<LIBRARY_ADDRESS> \
 *          --rpc-url $IMUACHAIN_TESTNET_RPC -- 0xFirstWitness 3
 *
 *   UPGRADE (same library address; new implementation):
 *        forge script script/24_DeployUTXOGateway.s.sol:DeployUTXOGateway --sig "runUpgrade(address)" --broadcast \
 *          --libraries src/libraries/UTXOChainActivator.sol:UTXOChainActivator:<LIBRARY_ADDRESS> \
 *          --rpc-url $IMUACHAIN_TESTNET_RPC -- 0xProxyAddress
 *     Or with proxy admin: runUpgrade(address proxy, address proxyAdmin).
 */
contract DeployUTXOGateway is BaseScript {

    bytes32 constant SALT_LIBRARY = keccak256("UTXOChainActivator");
    bytes32 constant SALT_PROXY = keccak256("UTXOGateway");

    string constant DEPLOYMENT_JSON = "script/deployments/utxo-gateway-imuachain_testnet.json";

    function setUp() public virtual override {
        super.setUp();
    }

    /**
     * @notice Deploy UTXOChainActivator library only. Run this first, then use the
     *         deployed address with --libraries when calling run() or runUpgrade().
     * @dev No --libraries flag needed. Writes address to deployments/utxo-gateway-libraries.json.
     */
    function deployLibrary() public returns (address libraryAddress) {
        vm.selectFork(imuachain);
        vm.startBroadcast(owner.privateKey);

        bytes memory creationCode = type(UTXOChainActivator).creationCode;
        libraryAddress = CREATE3_FACTORY.getDeployed(owner.addr, SALT_LIBRARY);
        if (libraryAddress.code.length == 0) {
            libraryAddress = CREATE3_FACTORY.deploy(SALT_LIBRARY, creationCode);
        }

        vm.stopBroadcast();

        string memory libJson = vm.serializeAddress("libraries", "UTXOChainActivator", libraryAddress);
        vm.writeJson(libJson, "script/deployments/utxo-gateway-libraries.json");

        console.log("UTXOChainActivator library:", libraryAddress);
        return libraryAddress;
    }

    /**
     * @notice Deploy UTXOGateway (ProxyAdmin + implementation + proxy) and initialize.
     * @param initialWitness First witness address; more can be added later via addWitnesses().
     * @param requiredProofs Number of proofs required for consensus (e.g. 3).
     * @dev Must run with:
     *      --libraries "src/libraries/UTXOChainActivator.sol:UTXOChainActivator:<LIBRARY_ADDRESS>"
     *      Example:
     *      forge script script/24_DeployUTXOGateway.s.sol:DeployUTXOGateway \
     *        --sig "run(address,uint256)" --broadcast \
     *        --libraries src/libraries/UTXOChainActivator.sol:UTXOChainActivator:0x... \
     *        -- 0xYourWitness 3
     */
    function run(address initialWitness, uint256 requiredProofs) public {
        vm.selectFork(imuachain);
        vm.startBroadcast(owner.privateKey);

        ProxyAdmin proxyAdmin = new ProxyAdmin();
        UTXOGateway implementation = new UTXOGateway();

        address[] memory witnesses = new address[](1);
        witnesses[0] = initialWitness;

        bytes memory initData =
            abi.encodeWithSelector(UTXOGateway.initialize.selector, owner.addr, witnesses, requiredProofs);

        bytes memory creationCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(address(implementation), address(proxyAdmin), initData)
        );

        address proxyAddress = CREATE3_FACTORY.deploy(SALT_PROXY, creationCode);
        UTXOGateway gateway = UTXOGateway(payable(proxyAddress));

        vm.stopBroadcast();

        _writeDeploymentJson(address(gateway), address(implementation), address(proxyAdmin));

        console.log("UTXOGateway proxy (use this address):", proxyAddress);
        console.log("UTXOGateway implementation:", address(implementation));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Owner:", gateway.owner());
        console.log("Required proofs:", gateway.requiredProofs());
    }

    /**
     * @notice Upgrade existing UTXOGateway proxy to a new implementation.
     * @param proxyAddress Address of the existing UTXOGateway proxy.
     * @param proxyAdminAddress Address of the ProxyAdmin that owns the proxy.
     * @dev Must run with:
     *      --libraries "src/libraries/UTXOChainActivator.sol:UTXOChainActivator:<LIBRARY_ADDRESS>"
     *      If proxyAdmin is unknown, read from script/deployments/utxo-gateway-imuachain_testnet.json.
     */
    function runUpgrade(address proxyAddress, address proxyAdminAddress) public {
        vm.selectFork(imuachain);
        require(proxyAddress != address(0), "proxy zero");
        require(proxyAdminAddress != address(0), "proxyAdmin zero");

        vm.startBroadcast(owner.privateKey);

        UTXOGateway newImplementation = new UTXOGateway();
        ProxyAdmin admin = ProxyAdmin(proxyAdminAddress);
        admin.upgrade(ITransparentUpgradeableProxy(proxyAddress), address(newImplementation));

        vm.stopBroadcast();

        console.log("UTXOGateway upgraded. New implementation:", address(newImplementation));
    }

    /**
     * @notice Same as runUpgrade but reads ProxyAdmin from deployment JSON.
     * @param proxyAddress Address of the existing UTXOGateway proxy.
     */
    function runUpgrade(address proxyAddress) public {
        string memory json = vm.readFile(DEPLOYMENT_JSON);
        address proxyAdminAddress = stdJson.readAddress(json, ".utxoGateway.proxyAdmin");
        runUpgrade(proxyAddress, proxyAdminAddress);
    }

    function _writeDeploymentJson(address proxy, address implementation, address proxyAdmin) internal {
        string memory key = "utxoGateway";
        vm.serializeAddress(key, "utxoGatewayProxy", proxy);
        vm.serializeAddress(key, "utxoGatewayLogic", implementation);
        string memory output = vm.serializeAddress(key, "proxyAdmin", proxyAdmin);
        vm.writeJson(output, DEPLOYMENT_JSON);
    }

}
