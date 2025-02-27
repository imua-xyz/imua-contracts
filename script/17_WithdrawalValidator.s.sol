pragma solidity ^0.8.19;

import {ImuaCapsule} from "../src/core/ImuaCapsule.sol";
import {IClientChainGateway} from "../src/interfaces/IClientChainGateway.sol";

import {IImuaCapsule} from "../src/interfaces/IImuaCapsule.sol";
import {IImuachainGateway} from "../src/interfaces/IImuachainGateway.sol";
import {IVault} from "../src/interfaces/IVault.sol";

import "../src/storage/GatewayStorage.sol";
import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

import "src/libraries/Endian.sol";

import {BaseScript} from "./BaseScript.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "forge-std/StdJson.sol";
import "src/libraries/BeaconChainProofs.sol";

import {NetworkConstants} from "src/libraries/NetworkConstants.sol";

contract WithdrawalValidatorScript is BaseScript {

    using AddressCast for address;
    using Endian for bytes32;

    bytes32[] validatorContainer;
    BeaconChainProofs.ValidatorContainerProof validatorProof;
    bytes32[] withdrawalContainer;
    BeaconChainProofs.WithdrawalProof withdrawalProof;

    uint256 internal immutable GENESIS_BLOCK_TIMESTAMP = NetworkConstants.getBeaconGenesisTimestamp();
    uint256 internal constant SECONDS_PER_SLOT = 12;
    uint256 constant GWEI_TO_WEI = 1e9;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployments/deployedContracts.json");

        clientGateway =
            IClientChainGateway(payable(stdJson.readAddress(deployedContracts, ".clientChain.clientChainGateway")));
        require(address(clientGateway) != address(0), "clientGateway address should not be empty");

        beaconOracle = EigenLayerBeaconOracle(stdJson.readAddress(deployedContracts, ".clientChain.beaconOracle"));
        require(address(beaconOracle) != address(0), "beacon oracle address should not be empty");

        // load beacon chain validator container and proof from json file
        _loadValidatorContainer();
        _loadValidatorProof();

        _loadWithdrawalContainer();
        _loadWithdrawalProof();

        if (!useImuachainPrecompileMock) {
            _bindPrecompileMocks();
        }

        // transfer some gas fee to depositor, relayer and imuachain gateway
        clientChain = vm.createSelectFork(clientChainRPCURL);
        _topUpPlayer(clientChain, address(0), deployer, depositor.addr, 0.2 ether);

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, address(imuachainGateway), 1 ether);
    }

    function run() public {
        bytes memory root = abi.encodePacked(hex"c0fa1dc87438211f4f73fab438558794947572b771f68c905eee959dba104877");
        vm.mockCall(
            address(beaconOracle), abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector), abi.encode(root)
        );
        vm.selectFork(clientChain);

        console.log("block.timestamp", validatorProof.beaconBlockTimestamp);
        vm.startBroadcast(depositor.privateKey);
        (bool success,) = address(beaconOracle).call(
            abi.encodeWithSelector(beaconOracle.addTimestamp.selector, validatorProof.beaconBlockTimestamp)
        );
        vm.stopBroadcast();

        vm.startBroadcast(depositor.privateKey);
        bytes memory dummyInput = new bytes(97);
        uint256 nativeFee = clientGateway.quote(dummyInput);
        clientGateway.processBeaconChainWithdrawal{value: nativeFee}(
            validatorContainer, validatorProof, withdrawalContainer, withdrawalProof
        );

        vm.stopBroadcast();
    }

    function _loadValidatorContainer() internal {
        string memory validatorInfo = vm.readFile("script/data/withdrawalProof_fullwithdraw_2495260_2472449.json");

        validatorContainer = stdJson.readBytes32Array(validatorInfo, ".validatorContainer");
        require(validatorContainer.length > 0, "validator container should not be empty");
    }

    function _loadValidatorProof() internal {
        string memory validatorInfo = vm.readFile("script/data/withdrawalProof_fullwithdraw_2495260_2472449.json");

        uint256 slot = stdJson.readUint(validatorInfo, ".slot");
        validatorProof.beaconBlockTimestamp = GENESIS_BLOCK_TIMESTAMP + SECONDS_PER_SLOT * slot;

        validatorProof.stateRoot = stdJson.readBytes32(validatorInfo, ".stateRoot");
        require(validatorProof.stateRoot != bytes32(0), "state root should not be empty");
        validatorProof.stateRootProof = stdJson.readBytes32Array(validatorInfo, ".stateRootProof");
        require(validatorProof.stateRootProof.length == 3, "state root proof should have 3 nodes");
        validatorProof.validatorContainerRootProof = stdJson.readBytes32Array(validatorInfo, ".validatorContainerProof");
        require(validatorProof.validatorContainerRootProof.length == 46, "validator root proof should have 46 nodes");
        validatorProof.validatorIndex = stdJson.readUint(validatorInfo, ".validatorIndex");
        require(validatorProof.validatorIndex != 0, "validator root index should not be 0");
    }

    function _loadWithdrawalContainer() internal {
        string memory withdrawalInfo = vm.readFile("script/data/withdrawalProof_fullwithdraw_2495260_2472449.json");

        withdrawalContainer = stdJson.readBytes32Array(withdrawalInfo, ".withdrawalContainer");
        require(withdrawalContainer.length > 0, "withdrawal container should not be empty");
    }

    function _loadWithdrawalProof() internal {
        string memory withdrawalInfo = vm.readFile("script/data/withdrawalProof_fullwithdraw_2495260_2472449.json");

        withdrawalProof.withdrawalContainerRootProof =
            stdJson.readBytes32Array(withdrawalInfo, ".withdrawalContainerProof");

        console.log("withdrawalContainerProof");
        console.logBytes32(withdrawalProof.withdrawalContainerRootProof[0]);
        withdrawalProof.slotProof = stdJson.readBytes32Array(withdrawalInfo, ".slotRootProof");
        withdrawalProof.executionPayloadRootProof =
            stdJson.readBytes32Array(withdrawalInfo, ".executionPayloadRootProof");
        withdrawalProof.timestampProof = stdJson.readBytes32Array(withdrawalInfo, ".timestampRootProof");
        withdrawalProof.historicalSummaryBlockRootProof =
            stdJson.readBytes32Array(withdrawalInfo, ".historicalSummaryBlockRootProof");
        withdrawalProof.blockRootIndex = stdJson.readUint(withdrawalInfo, ".blockRootIndex");
        require(withdrawalProof.blockRootIndex != 0, "block root index should not be 0");
        withdrawalProof.historicalSummaryIndex = stdJson.readUint(withdrawalInfo, ".historicalSummaryIndex");
        withdrawalProof.withdrawalIndex = stdJson.readUint(withdrawalInfo, ".withdrawalIndexWithinBlock");
        withdrawalProof.blockRoot = stdJson.readBytes32(withdrawalInfo, ".historicalSummaryBlockRoot");
        require(withdrawalProof.blockRoot != bytes32(0), "block root should not be empty");
        withdrawalProof.slotRoot = stdJson.readBytes32(withdrawalInfo, ".slotRoot");
        withdrawalProof.timestampRoot = stdJson.readBytes32(withdrawalInfo, ".timestampRoot");
        withdrawalProof.executionPayloadRoot = stdJson.readBytes32(withdrawalInfo, ".executionPayloadRoot");
        withdrawalProof.stateRoot = stdJson.readBytes32(withdrawalInfo, ".stateRoot");
        // console.logBytes32("load withdrawal proof stateRoot", withdrawalProof.stateRoot);
    }

    function _getEffectiveBalance(bytes32[] storage vc) internal view returns (uint64) {
        return vc[2].fromLittleEndianUint64();
    }

}
