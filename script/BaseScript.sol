pragma solidity ^0.8.19;

import "../src/interfaces/IClientChainGateway.sol";
import "../src/interfaces/IImuaCapsule.sol";
import "../src/interfaces/IImuachainGateway.sol";
import "../src/interfaces/IRewardVault.sol";
import "../src/interfaces/IVault.sol";
import "../src/utils/BeaconProxyBytecode.sol";
import "../src/utils/CustomProxyAdmin.sol";

import "../src/interfaces/precompiles/IAssets.sol";

import "../src/interfaces/precompiles/IDelegation.sol";
import "../src/interfaces/precompiles/IReward.sol";

import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ERC20PresetFixedSupply, IERC20} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import "../test/mocks/AssetsMock.sol";

import "../test/mocks/DelegationMock.sol";
import "../test/mocks/RewardMock.sol";

contract BaseScript is Script, StdCheats {

    struct Player {
        uint256 privateKey;
        address addr;
    }

    Player deployer;
    Player owner;
    Player imuachainGenesis;
    Player depositor;
    Player relayer;

    string sepoliaRPCURL;
    string holeskyRPCURL;
    string clientChainRPCURL;
    string clientChainName;
    uint16 clientChainEndpointId;
    address clientChainEndpointV2;
    string imuachainRPCURL;

    mapping(uint256 chainId => string chainName) chainIdToName;
    mapping(uint256 chainId => uint16 endpointId) chainIdToEndpointId;
    mapping(uint256 chainId => address endpointV2Address) chainIdToEndpointV2Address;

    address[] whitelistTokens;
    uint256[] tvlLimits;

    IClientChainGateway clientGateway;
    IVault vault;
    IRewardVault rewardVault;
    IImuachainGateway imuachainGateway;
    ILayerZeroEndpointV2 clientChainLzEndpoint;
    ILayerZeroEndpointV2 imuachainLzEndpoint;
    EigenLayerBeaconOracle beaconOracle;
    ERC20PresetFixedSupply restakeToken;
    IVault vaultImplementation;
    IRewardVault rewardVaultImplementation;
    IImuaCapsule capsuleImplementation;
    IBeacon vaultBeacon;
    IBeacon rewardVaultBeacon;
    IBeacon capsuleBeacon;
    BeaconProxyBytecode beaconProxyBytecode;
    CustomProxyAdmin clientChainProxyAdmin;

    address delegationMock;
    address assetsMock;
    address rewardMock;

    uint256 clientChain;
    uint256 imuachain;

    uint16 constant imuachainEndpointId = 40_259;
    address constant imuachainEndpointV2 = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address erc20TokenAddress = 0xF79F563571f7D8122611D0219A0d5449B5304F79;

    uint256 constant DEPOSIT_AMOUNT = 1 ether;
    uint256 constant WITHDRAW_AMOUNT = 1 ether;
    address internal constant VIRTUAL_STAKED_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 internal constant TOKEN_ADDRESS_BYTES_LENGTH = 32;

    bool useImuachainPrecompileMock;
    bool useEndpointMock;

    function setUp() public virtual {
        deployer.privateKey = vm.envUint("TEST_ACCOUNT_ONE_PRIVATE_KEY");
        deployer.addr = vm.addr(deployer.privateKey);

        owner.privateKey = vm.envUint("TEST_ACCOUNT_THREE_PRIVATE_KEY");
        owner.addr = vm.addr(owner.privateKey);

        imuachainGenesis.privateKey = vm.envUint("IMUACHAIN_GENESIS_PRIVATE_KEY");
        imuachainGenesis.addr = vm.addr(imuachainGenesis.privateKey);

        depositor.privateKey = vm.envUint("TEST_ACCOUNT_FOUR_PRIVATE_KEY");
        depositor.addr = vm.addr(depositor.privateKey);

        relayer.privateKey = vm.envUint("TEST_ACCOUNT_FOUR_PRIVATE_KEY");
        relayer.addr = vm.addr(relayer.privateKey);

        useEndpointMock = vm.envBool("USE_ENDPOINT_MOCK");
        console.log("NOTICE: using l0 endpoint mock", useEndpointMock);
        useImuachainPrecompileMock = vm.envBool("USE_IMUACHAIN_PRECOMPILE_MOCK");
        console.log("NOTICE: using imuachain precompiles mock", useImuachainPrecompileMock);

        chainIdToName[233] = "imuachain";
        chainIdToName[11_155_111] = "sepolia";
        chainIdToName[17_000] = "holesky";

        chainIdToEndpointId[233] = imuachainEndpointId;
        chainIdToEndpointId[11_155_111] = 40_161;
        chainIdToEndpointId[17_000] = 40_217;

        chainIdToEndpointV2Address[233] = imuachainEndpointV2;
        chainIdToEndpointV2Address[11_155_111] = 0x6EDCE65403992e310A62460808c4b910D972f10f;
        chainIdToEndpointV2Address[17_000] = 0x6EDCE65403992e310A62460808c4b910D972f10f;

        clientChainRPCURL = vm.envString("CLIENT_CHAIN_RPC");
        clientChain = vm.createSelectFork(clientChainRPCURL);
        clientChainName = chainIdToName[block.chainid];
        clientChainEndpointId = chainIdToEndpointId[block.chainid];
        clientChainEndpointV2 = chainIdToEndpointV2Address[block.chainid];
        require(bytes(clientChainName).length > 0, "not supported chain");
        require(clientChainEndpointId != 0, "not supported chain");
        require(clientChainEndpointV2 != address(0), "not supported chain");

        imuachainRPCURL = vm.envString("IMUACHAIN_TESTNET_RPC");
        imuachain = vm.createSelectFork(imuachainRPCURL);
    }

    function _bindPrecompileMocks() internal {
        uint256 previousFork = type(uint256).max;
        try vm.activeFork() returns (uint256 forkId) {
            previousFork = forkId;
        } catch {
            // ignore
        }
        // choose the fork to ensure no client chain simulation is impacted
        vm.selectFork(imuachain);
        // even with --skip-simulation, some transactions fail. this helps work around that limitation
        // but it isn't perfect. if you face too much trouble, try calling the function(s) directly
        // with cast or remix.
        deployCodeTo("AssetsMock.sol", abi.encode(clientChainEndpointId), ASSETS_PRECOMPILE_ADDRESS);
        deployCodeTo("DelegationMock.sol", DELEGATION_PRECOMPILE_ADDRESS);
        deployCodeTo("RewardMock.sol", REWARD_PRECOMPILE_ADDRESS);
        // go to the original fork, if one was selected
        if (previousFork != type(uint256).max) {
            vm.selectFork(previousFork);
        }
    }

    function _topUpPlayer(
        uint256 chain,
        address token,
        Player memory provider,
        address recipient,
        uint256 targetBalance
    ) internal {
        vm.selectFork(chain);
        vm.startBroadcast(provider.privateKey);

        if (token == address(0)) {
            if (recipient.balance < targetBalance) {
                (bool sent,) = recipient.call{value: targetBalance - recipient.balance}("");
                require(sent, "Failed to send Ether");
            }
        } else {
            uint256 currentBalance = IERC20(token).balanceOf(recipient);
            if (currentBalance < targetBalance) {
                IERC20(token).transfer(recipient, targetBalance - currentBalance);
            }
        }
        vm.stopBroadcast();
    }

}
