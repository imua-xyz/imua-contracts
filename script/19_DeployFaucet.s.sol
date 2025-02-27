pragma solidity ^0.8.19;

import {CombinedFaucet} from "../src/core/CombinedFaucet.sol";
import {BaseScript} from "./BaseScript.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "forge-std/Script.sol";

contract DeployScript is BaseScript {

    address tokenAddr;
    bool imEthFaucet;
    address faucetOwner;

    function setUp() public virtual override {
        super.setUp();

        string memory prerequisites = vm.readFile("script/deployments/prerequisiteContracts.json");

        tokenAddr = stdJson.readAddress(prerequisites, ".clientChain.erc20Token");
        require(tokenAddr != address(0), "token address should not be empty");

        clientChain = vm.createSelectFork(clientChainRPCURL);
        imuachain = vm.createSelectFork(imuachainRPCURL);

        // boolean to decide which item is being deployed on which chain
        // true => client chain, imETH faucet
        // false => imuachain, native token faucet
        imEthFaucet = vm.envBool("IM_ETH_FAUCET");
        // for native token, using a different owner is better since the private key is exposed on the backend
        faucetOwner = vm.envAddress("FAUCET_OWNER");
    }

    function run() public {
        vm.selectFork(imEthFaucet ? clientChain : imuachain);
        vm.startBroadcast(owner.privateKey);
        address proxyAdmin = address(new ProxyAdmin());
        CombinedFaucet faucetLogic = new CombinedFaucet();
        CombinedFaucet faucet = CombinedFaucet(
            payable(address(new TransparentUpgradeableProxy(address(faucetLogic), address(proxyAdmin), "")))
        );
        faucet.initialize(owner.addr, imEthFaucet ? tokenAddr : address(0), 1 ether);
        vm.stopBroadcast();
        // do not store them as JSON since the address is intentionally kept private
        console.log("faucet", address(faucet));
        console.log("faucetLogic", address(faucetLogic));
        console.log("proxyAdmin", address(proxyAdmin));
    }

}
