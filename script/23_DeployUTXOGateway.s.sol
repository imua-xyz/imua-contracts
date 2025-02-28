// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Script.sol";
import {UTXOGateway} from "src/core/UTXOGateway.sol";
import {UTXOGatewayStorage} from "src/storage/UTXOGatewayStorage.sol";
/**
 * @title Deploy script for UTXOGateway
 * @notice This script deploys and initializes the UTXOGateway contract with a transparent proxy
 */

contract DeployUTXOGateway is Script {

    // Initial deployment parameters
    address public constant INITIAL_WITNESS = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 public constant INITIAL_REQUIRED_PROOFS = 3;

    function run() external {
        // Get deployer's private key from environment (will be proxy admin)
        // 0x90F79bf6EB2c4f870365E785982E1f101E93b906
        uint256 deployerPrivateKey = vm.envUint("TEST_ACCOUNT_FOUR_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get owner's private key from environment (will be contract owner)
        // 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(ownerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy logic contract
        UTXOGateway gatewayLogic = new UTXOGateway();

        // 2. Set proxy admin (using deployer address)
        address proxyAdmin = deployer;

        // 3. Prepare initialization data
        // Note: Set owner instead of deployer as the contract owner
        address[] memory initialWitnesses = new address[](1);
        initialWitnesses[0] = INITIAL_WITNESS;
        bytes memory initData = abi.encodeWithSelector(
            UTXOGateway.initialize.selector,
            owner, // Set owner as the contract owner
            initialWitnesses,
            INITIAL_REQUIRED_PROOFS
        );

        // 4. Deploy transparent proxy contract
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(gatewayLogic),
            proxyAdmin, // deployer as proxy admin
            initData
        );

        // 5. Get the proxied UTXOGateway instance
        UTXOGateway gateway = UTXOGateway(address(proxy));
        vm.stopBroadcast();
        // 6. Activate staking for Bitcoin client chain
        vm.startBroadcast(ownerPrivateKey);
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);

        vm.stopBroadcast();

        // 6. Log deployment information
        console.log("=== Deployment Summary ===");
        console.log("Logic contract:", address(gatewayLogic));
        console.log("Proxy contract:", address(proxy));
        console.log("Proxy admin:", proxyAdmin);
        console.log("Gateway (proxy):", address(gateway));
        console.log("=== Contract State ===");
        console.log("Owner:", gateway.owner());
        console.log("Required proofs:", gateway.requiredProofs());
        console.log("Initial witness:", INITIAL_WITNESS);
    }

}
