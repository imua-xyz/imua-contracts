pragma solidity ^0.8.19;

import {Action, GatewayStorage} from "../src/storage/GatewayStorage.sol";

import "../src/interfaces/IClientChainGateway.sol";
import "../src/interfaces/IImuachainGateway.sol";
import "../src/interfaces/IVault.sol";

import {NonShortCircuitEndpointV2Mock} from "../test/mocks/NonShortCircuitEndpointV2Mock.sol";

import {BaseScript} from "./BaseScript.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

contract SetupScript is BaseScript {

    using AddressCast for address;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployments/deployedContracts.json");

        clientGateway =
            IClientChainGateway(payable(stdJson.readAddress(deployedContracts, ".clientChain.clientChainGateway")));
        require(address(clientGateway) != address(0), "clientGateway address should not be empty");

        clientChainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(deployedContracts, ".clientChain.lzEndpoint"));
        require(address(clientChainLzEndpoint) != address(0), "clientChainLzEndpoint address should not be empty");

        restakeToken = ERC20PresetFixedSupply(stdJson.readAddress(deployedContracts, ".clientChain.erc20Token"));
        require(address(restakeToken) != address(0), "restakeToken address should not be empty");

        imuachainGateway =
            IImuachainGateway(payable(stdJson.readAddress(deployedContracts, ".imuachain.imuachainGateway")));
        require(address(imuachainGateway) != address(0), "imuachainGateway address should not be empty");

        imuachainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(deployedContracts, ".imuachain.lzEndpoint"));
        require(address(imuachainLzEndpoint) != address(0), "imuachainLzEndpoint address should not be empty");

        // transfer some gas fee to contract owner
        clientChain = vm.createSelectFork(clientChainRPCURL);
        _topUpPlayer(clientChain, address(0), deployer, owner.addr, 0.2 ether);

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, owner.addr, 0.2 ether);

        if (!useImuachainPrecompileMock) {
            _bindPrecompileMocks();
        }
    }

    function run() public {
        // 1. setup client chain contracts to make them ready for sending and receiving messages from imuachain gateway

        vm.selectFork(clientChain);
        // Set owner of these contracts and only owner could setup contracts state
        vm.startBroadcast(owner.privateKey);
        // set the destination endpoint for corresponding destinations in endpoint mock if USE_ENDPOINT_MOCK is true
        if (useEndpointMock) {
            NonShortCircuitEndpointV2Mock(address(clientChainLzEndpoint)).setDestLzEndpoint(
                address(imuachainGateway), address(imuachainLzEndpoint)
            );
        }

        // as LzReceivers, client chain gateway should set imuachainGateway as trusted remote to receive messages from
        // it
        clientGateway.setPeer(imuachainChainId, address(imuachainGateway).toBytes32());
        vm.stopBroadcast();

        // 2. setup imuachain contracts to make them ready for sending and receiving messages from client chain
        // gateway, and register client chain meta data to imuachain native module

        vm.selectFork(imuachain);
        // Set the owner of these contracts and only owner could setup contracts state
        vm.startBroadcast(owner.privateKey);
        // set the destination endpoint for corresponding destinations in endpoint mock if USE_ENDPOINT_MOCK is true
        if (useEndpointMock) {
            NonShortCircuitEndpointV2Mock(address(imuachainLzEndpoint)).setDestLzEndpoint(
                address(clientGateway), address(clientChainLzEndpoint)
            );
        }
        // register clientChainId to imuachain native module and set peer for client chain gateway to be ready for
        // messaging
        imuachainGateway.registerOrUpdateClientChain(
            clientChainId, address(clientGateway).toBytes32(), 20, "ClientChain", "EVM compatible network", "secp256k1"
        );
        vm.stopBroadcast();

        // 3. adding tokens to the whtielist of both imuachain and client chain gateway to enable restaking
        vm.selectFork(clientChain);
        // first we read decimals from client chain ERC20 token contract to prepare for token data
        bytes32[] memory whitelistTokensBytes32 = new bytes32[](2);
        uint8[] memory decimals = new uint8[](2);
        string[] memory names = new string[](2);
        string[] memory metaDatas = new string[](2);
        string[] memory oracleInfos = new string[](2);
        uint128[] memory tvlLimits = new uint128[](2);

        // this stands for LST restaking for restakeToken
        whitelistTokensBytes32[0] = bytes32(bytes20(address(restakeToken)));
        decimals[0] = restakeToken.decimals();
        names[0] = "RestakeToken";
        metaDatas[0] = "ERC20 LST token";
        oracleInfos[0] = "ETH,Ethereum,8";
        tvlLimits[0] = uint128(restakeToken.totalSupply() / 5); // in phases of 20%

        // this stands for Native Restaking for ETH
        whitelistTokensBytes32[1] = bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS));
        decimals[1] = 18;
        names[1] = "StakedETH";
        metaDatas[1] = "natively staked ETH on Ethereum";
        oracleInfos[1] = "ETH,Ethereum,8"; //[tokenName],[chainName],[tokenDecimal](,[interval],[contract](,[ChainDesc:{...}],[TokenDesc:{...}]))
        tvlLimits[1] = 0; // irrelevant for native restaking

        // second add whitelist tokens and their meta data on imuachain side to enable LST Restaking and Native
        // Restaking,
        // and this would also add token addresses to client chain gateway's whitelist
        vm.selectFork(imuachain);
        vm.startBroadcast(owner.privateKey);
        uint256 nativeFee;
        for (uint256 i = 0; i < whitelistTokensBytes32.length; i++) {
            nativeFee = imuachainGateway.quote(
                clientChainId,
                abi.encodePacked(
                    Action.REQUEST_ADD_WHITELIST_TOKEN, abi.encodePacked(whitelistTokensBytes32[i], tvlLimits[i])
                )
            );
            imuachainGateway.addWhitelistToken{value: nativeFee}(
                clientChainId,
                whitelistTokensBytes32[i],
                decimals[i],
                names[i],
                metaDatas[i],
                oracleInfos[i],
                tvlLimits[i]
            );
        }
        vm.stopBroadcast();
    }

}
