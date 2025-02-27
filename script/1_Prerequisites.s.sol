pragma solidity ^0.8.19;

import "./BaseScript.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

import "test/mocks/AssetsMock.sol";

import "test/mocks/DelegationMock.sol";
import {NonShortCircuitEndpointV2Mock} from "test/mocks/NonShortCircuitEndpointV2Mock.sol";
import "test/mocks/RewardMock.sol";

contract PrerequisitesScript is BaseScript {

    function setUp() public virtual override {
        super.setUp();

        clientChain = vm.createSelectFork(clientChainRPCURL);

        // transfer some eth to deployer address
        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, deployer.addr, 1 ether);
    }

    function run() public {
        // deploy NonShortCircuitEndpointV2Mock first if USE_ENDPOINT_MOCK is true, otherwise use real endpoints.
        if (useEndpointMock) {
            vm.selectFork(clientChain);
            vm.startBroadcast(deployer.privateKey);
            clientChainLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, owner.addr);
            vm.stopBroadcast();

            vm.selectFork(imuachain);
            vm.startBroadcast(deployer.privateKey);
            imuachainLzEndpoint = new NonShortCircuitEndpointV2Mock(imuachainChainId, owner.addr);
            vm.stopBroadcast();
        } else {
            clientChainLzEndpoint = ILayerZeroEndpointV2(sepoliaEndpointV2);
            imuachainLzEndpoint = ILayerZeroEndpointV2(imuachainEndpointV2);
        }

        if (useImuachainPrecompileMock) {
            vm.selectFork(imuachain);
            vm.startBroadcast(deployer.privateKey);
            assetsMock = address(new AssetsMock(clientChainId));
            delegationMock = address(new DelegationMock());
            rewardMock = address(new RewardMock());
            vm.stopBroadcast();
        }

        // use deployed ERC20 token as restake token
        restakeToken = ERC20PresetFixedSupply(erc20TokenAddress);

        string memory deployedContracts = "deployedContracts";
        string memory clientChainContracts = "clientChainContracts";
        string memory imuachainContracts = "imuachainContracts";
        vm.serializeAddress(clientChainContracts, "lzEndpoint", address(clientChainLzEndpoint));
        vm.serializeAddress(clientChainContracts, "beaconOracle", address(beaconOracle));
        string memory clientChainContractsOutput =
            vm.serializeAddress(clientChainContracts, "erc20Token", address(restakeToken));

        if (useImuachainPrecompileMock) {
            vm.serializeAddress(imuachainContracts, "assetsPrecompileMock", assetsMock);
            vm.serializeAddress(imuachainContracts, "delegationPrecompileMock", delegationMock);
            vm.serializeAddress(imuachainContracts, "rewardPrecompileMock", rewardMock);
        }

        string memory imuachainContractsOutput =
            vm.serializeAddress(imuachainContracts, "lzEndpoint", address(imuachainLzEndpoint));

        vm.serializeString(deployedContracts, "clientChain", clientChainContractsOutput);
        string memory finalJson = vm.serializeString(deployedContracts, "imuachain", imuachainContractsOutput);

        vm.writeJson(finalJson, "script/deployments/prerequisiteContracts.json");
    }

}
