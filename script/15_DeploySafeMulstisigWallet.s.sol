pragma solidity ^0.8.13;

import {BaseScript} from "./BaseScript.sol";

import "@safe-contracts/GnosisSafeL2.sol";
import "@safe-contracts/proxies/GnosisSafeProxyFactory.sol";

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

contract CreateMultisigScript is BaseScript {

    using stdJson for string;

    function setUp() public override {
        super.setUp();

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, deployer.addr, 2 ether);
    }

    function run() public {
        vm.selectFork(imuachain);
        vm.startBroadcast(deployer.privateKey);

        // Read deployed Safe contracts from JSON file
        string memory json = vm.readFile("script/deployments/safe_contracts_on_imuachain.json");

        address proxyFactoryAddress = json.readAddress(".GnosisSafeProxyFactory");
        address safeSingletonAddress = json.readAddress(".GnosisSafeL2");
        address fallbackHandlerAddress = json.readAddress(".CompatibilityFallbackHandler");

        GnosisSafeProxyFactory proxyFactory = GnosisSafeProxyFactory(proxyFactoryAddress);
        GnosisSafeL2 safeSingleton = GnosisSafeL2(payable(safeSingletonAddress));

        // Set up owners
        address[] memory owners = new address[](3);
        owners[0] = deployer.addr;
        owners[1] = owner.addr;
        owners[2] = relayer.addr;

        // Set up Safe parameters
        uint256 threshold = 2;
        address to = address(0);
        bytes memory data = "";
        address fallbackHandler = fallbackHandlerAddress;
        address paymentToken = address(0);
        uint256 payment = 0;
        address payable paymentReceiver = payable(address(0));

        // Encode initialization data
        bytes memory initializer = abi.encodeWithSelector(
            GnosisSafe.setup.selector,
            owners,
            threshold,
            to,
            data,
            fallbackHandler,
            paymentToken,
            payment,
            paymentReceiver
        );

        // Create new Safe proxy
        GnosisSafeProxy safeProxy = proxyFactory.createProxy(address(safeSingleton), initializer);

        console.log("New Safe created at:", address(safeProxy));

        vm.stopBroadcast();
    }

}
