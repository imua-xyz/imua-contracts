pragma solidity ^0.8.19;

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "forge-std/Script.sol";

import {ImuachainGateway} from "../src/core/ImuachainGateway.sol";

import {BaseScript} from "./BaseScript.sol";
import "forge-std/Script.sol";

import {Action} from "../src/storage/GatewayStorage.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeImuachainGatewayScript is BaseScript {

    address proxy;
    address proxyAdmin;
    address restoreLogic;

    function setUp() public virtual override {
        super.setUp();
        string memory prerequisites = vm.readFile("script/deployedContracts.json");
        imuachainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(prerequisites, ".imuachain.lzEndpoint"));
        require(address(imuachainLzEndpoint) != address(0), "imuachain l0 endpoint should not be empty");
        proxy = stdJson.readAddress(prerequisites, ".imuachain.imuachainGateway");
        require(proxy != address(0), "imuachain gateway should not be empty");
        proxyAdmin = stdJson.readAddress(prerequisites, ".imuachain.imuachainProxyAdmin");
        require(proxyAdmin != address(0), "imuachain proxy admin should not be empty");
        restoreLogic = stdJson.readAddress(prerequisites, ".imuachain.imuachainGatewayLogic");
        require(restoreLogic != address(0), "imuachain gateway logic should not be empty");
        imuachain = vm.createSelectFork(imuachainRPCURL);
    }

    function run() public {
        vm.startBroadcast(owner.privateKey);
        // new deployment
        ImuachainGateway imuachainGatewayLogic = new ImuachainGateway(address(imuachainLzEndpoint));
        // upgrade to new deployment such that the onlyCalledFromThis is removed
        ProxyAdmin(proxyAdmin).upgrade(ITransparentUpgradeableProxy(proxy), address(imuachainGatewayLogic));
        // then do the edit
        ImuachainGateway gateway = ImuachainGateway(payable(proxy));
        // gateway.fixReentrance();
        // gateway.fixNonce();
        // validate the result
        bytes32 slotValue = vm.load(address(gateway), bytes32(uint256(151)));
        require(uint256(slotValue) == 1, "Slot value is not 1");
        // validate the nonce
        // uint256 nextNonce = gateway.nextNonce(40168,
        // bytes32(0xe57dcdb0740d281469f5be39b44bf495f8ade7a1af889bae16252e7b9875dc92));
        // require(nextNonce == 21, "Next nonce is not 21");
        // then upgrade back to the old deployment
        ProxyAdmin(proxyAdmin).upgrade(ITransparentUpgradeableProxy(proxy), restoreLogic);
        vm.stopBroadcast();

        console.log(
            "next nonce",
            gateway.nextNonce(40_168, bytes32(0xe57dcdb0740d281469f5be39b44bf495f8ade7a1af889bae16252e7b9875dc92))
        );
    }

}
