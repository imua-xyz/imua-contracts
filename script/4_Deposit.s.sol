pragma solidity ^0.8.19;

import "../src/interfaces/IClientChainGateway.sol";

import "../src/interfaces/IImuachainGateway.sol";
import "../src/interfaces/IVault.sol";
import {Action, GatewayStorage} from "../src/storage/GatewayStorage.sol";

import {BaseScript} from "./BaseScript.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

contract DepositScript is BaseScript {

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

        vault = IVault(stdJson.readAddress(deployedContracts, ".clientChain.resVault"));
        require(address(vault) != address(0), "vault address should not be empty");

        imuachainGateway =
            IImuachainGateway(payable(stdJson.readAddress(deployedContracts, ".imuachain.imuachainGateway")));
        require(address(imuachainGateway) != address(0), "imuachainGateway address should not be empty");

        imuachainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(deployedContracts, ".imuachain.lzEndpoint"));
        require(address(imuachainLzEndpoint) != address(0), "imuachainLzEndpoint address should not be empty");

        if (!useImuachainPrecompileMock) {
            _bindPrecompileMocks();
        }

        // transfer some gas fee to depositor, relayer and imuachain gateway
        clientChain = vm.createSelectFork(clientChainRPCURL);
        _topUpPlayer(clientChain, address(0), deployer, depositor.addr, 0.2 ether);
        _topUpPlayer(clientChain, address(restakeToken), owner, depositor.addr, 2 * DEPOSIT_AMOUNT);

        imuachain = vm.createSelectFork(imuachainRPCURL);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, relayer.addr, 0.2 ether);
        _topUpPlayer(imuachain, address(0), imuachainGenesis, address(imuachainGateway), 2 ether);
    }

    function run() public {
        bytes memory msg_ = abi.encodePacked(
            Action.REQUEST_DEPOSIT_LST,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(depositor.addr))),
            uint256(DEPOSIT_AMOUNT)
        );

        vm.selectFork(clientChain);
        vm.startBroadcast(depositor.privateKey);

        restakeToken.approve(address(vault), type(uint256).max);

        uint256 nativeFee = clientGateway.quote(msg_);
        console.log("l0 native fee:", nativeFee);

        clientGateway.deposit{value: nativeFee}(address(restakeToken), DEPOSIT_AMOUNT);

        vm.stopBroadcast();

        if (useEndpointMock) {
            vm.selectFork(imuachain);
            vm.startBroadcast(relayer.privateKey);
            uint64 nonce = imuachainGateway.nextNonce(clientChainId, address(clientGateway).toBytes32());
            imuachainLzEndpoint.lzReceive{gas: 500_000}(
                Origin(clientChainId, address(clientGateway).toBytes32(), nonce),
                address(imuachainGateway),
                GUID.generate(
                    nonce,
                    clientChainId,
                    address(clientGateway),
                    imuachainChainId,
                    address(imuachainGateway).toBytes32()
                ),
                msg_,
                bytes("")
            );
            vm.stopBroadcast();
        }
    }

}
