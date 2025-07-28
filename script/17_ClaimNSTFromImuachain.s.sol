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

    uint256 internal immutable GENESIS_BLOCK_TIMESTAMP = NetworkConstants.getBeaconGenesisTimestamp();
    uint256 internal constant SECONDS_PER_SLOT = 12;
    uint256 constant GWEI_TO_WEI = 1e9;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployments/deployedContracts.json");

        clientGateway = IClientChainGateway(
            payable(stdJson.readAddress(deployedContracts, string.concat(".", clientChainName, ".clientChainGateway")))
        );
        require(address(clientGateway) != address(0), "clientGateway address should not be empty");

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
        vm.startBroadcast(depositor.privateKey);
        bytes memory dummyInput = new bytes(65);
        uint256 nativeFee = clientGateway.quote(dummyInput);
        clientGateway.claimNSTFromImuachain{value: nativeFee}(1 ether);

        vm.stopBroadcast();
    }

}
