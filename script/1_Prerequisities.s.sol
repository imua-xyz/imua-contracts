pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin-contracts/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {NonShortCircuitEndpointV2Mock} from "test/mocks/NonShortCircuitEndpointV2Mock.sol";
import "@layerzero-v2/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "test/mocks/ClaimRewardMock.sol";
import "test/mocks/DelegationMock.sol";
import "test/mocks/DepositWithdrawMock.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "./BaseScript.sol";

contract PrerequisitiesScript is BaseScript {
    function setUp() public virtual override {
        super.setUp();

        clientChain = vm.createSelectFork(clientChainRPCURL);

        // transfer some eth to deployer address
        exocore = vm.createSelectFork(exocoreRPCURL);
        vm.startBroadcast(exocoreGenesis.privateKey);
        if (deployer.addr.balance < 1 ether) {
            (bool sent,) = deployer.addr.call{value: 1 ether}("");
            require(sent, "Failed to send Ether");
        }
        vm.stopBroadcast();
    }

    function run() public {
        // deploy NonShortCircuitEndpointV2Mock first if USE_ENDPOINT_MOCK is true, otherwise use real endpoints.
        if (useEndpointMock) {
            vm.selectFork(clientChain);
            vm.startBroadcast(deployer.privateKey);
            clientChainLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, exocoreValidatorSet.addr);
            vm.stopBroadcast();

            vm.selectFork(exocore);
            vm.startBroadcast(deployer.privateKey);
            exocoreLzEndpoint = new NonShortCircuitEndpointV2Mock(exocoreChainId, exocoreValidatorSet.addr);
            vm.stopBroadcast();
        } else {
            clientChainLzEndpoint = ILayerZeroEndpointV2(sepoliaEndpointV2);
            exocoreLzEndpoint = ILayerZeroEndpointV2(exocoreEndpointV2);
        }

        if (useExocorePrecompileMock) {
            vm.selectFork(exocore);
            vm.startBroadcast(deployer.privateKey);
            depositMock = address(new DepositWithdrawMock());
            withdrawMock = depositMock;
            delegationMock = address(new DelegationMock());
            claimRewardMock = address(new ClaimRewardMock());
            vm.stopBroadcast();
        }

        // use deployed ERC20 token as restake token
        restakeToken = ERC20PresetFixedSupply(erc20TokenAddress);

        // deploy beacon chain oracle
        beaconOracle = IBeaconChainOracle(_deployBeaconOracle());

        string memory deployedContracts = "deployedContracts";
        string memory clientChainContracts = "clientChainContracts";
        string memory exocoreContracts = "exocoreContracts";
        vm.serializeAddress(clientChainContracts, "lzEndpoint", address(clientChainLzEndpoint));
        vm.serializeAddress(clientChainContracts, "beaconOracle", address(beaconOracle));
        string memory clientChainContractsOutput =
            vm.serializeAddress(clientChainContracts, "erc20Token", address(restakeToken));

        if (useExocorePrecompileMock) {
            vm.serializeAddress(exocoreContracts, "depositPrecompileMock", depositMock);
            vm.serializeAddress(exocoreContracts, "withdrawPrecompileMock", withdrawMock);
            vm.serializeAddress(exocoreContracts, "delegationPrecompileMock", delegationMock);
            vm.serializeAddress(exocoreContracts, "claimRewardPrecompileMock", claimRewardMock);
        }

        string memory exocoreContractsOutput =
            vm.serializeAddress(exocoreContracts, "lzEndpoint", address(exocoreLzEndpoint));

        vm.serializeString(deployedContracts, "clientChain", clientChainContractsOutput);
        string memory finalJson = vm.serializeString(deployedContracts, "exocore", exocoreContractsOutput);

        vm.writeJson(finalJson, "script/prerequisitContracts.json");
    }

    function _deployBeaconOracle() internal returns (address) {
        uint256 GENESIS_BLOCK_TIMESTAMP;

        if (block.chainid == 1) {
            GENESIS_BLOCK_TIMESTAMP = 1606824023;
        } else if (block.chainid == 5) {
            GENESIS_BLOCK_TIMESTAMP = 1616508000;
        } else if (block.chainid == 11155111) {
            GENESIS_BLOCK_TIMESTAMP = 1655733600;
        } else if (block.chainid == 17000) {
            GENESIS_BLOCK_TIMESTAMP = 1695902400;
        } else {
            revert("Unsupported chainId.");
        }

        EigenLayerBeaconOracle oracle = new EigenLayerBeaconOracle(GENESIS_BLOCK_TIMESTAMP);
        return address(oracle);
    }
}
