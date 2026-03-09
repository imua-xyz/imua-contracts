// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {EigenLayerBeaconOracle} from "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import {IBeaconChainOracle} from "@beacon-oracle/contracts/src/IBeaconChainOracle.sol";
import {
    ILayerZeroEndpointV2,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {AddressCast} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ClientChainGateway} from "src/core/ClientChainGateway.sol";
import {ImuaCapsuleBSC} from "src/core/ImuaCapsuleBSC.sol";
import {ImuachainGateway} from "src/core/ImuachainGateway.sol";
import {RewardVault} from "src/core/RewardVault.sol";
import {Vault} from "src/core/Vault.sol";

import {IBSCValidatorCredit} from "src/interfaces/IBSCValidatorCredit.sol";
import {IImuaCapsule} from "src/interfaces/IImuaCapsule.sol";
import {IStakeHub} from "src/interfaces/IStakeHub.sol";
import "src/interfaces/precompiles/IAssets.sol";
import "src/interfaces/precompiles/IDelegation.sol";
import "src/interfaces/precompiles/IReward.sol";
import {BootstrapStorage} from "src/storage/BootstrapStorage.sol";

import {NetworkConstants} from "src/libraries/NetworkConstants.sol";
import {Action} from "src/storage/GatewayStorage.sol";
import {BeaconProxyBytecode} from "src/utils/BeaconProxyBytecode.sol";

import "test/mocks/AssetsMock.sol";
import "test/mocks/DelegationMock.sol";
import {NonShortCircuitEndpointV2Mock} from "test/mocks/NonShortCircuitEndpointV2Mock.sol";
import "test/mocks/RewardMock.sol";

contract StakeHubMock is IStakeHub {

    address public lastDelegator;
    address public lastValidator;
    bool public lastDelegateVotePower;
    uint256 public lastDelegatedAmount;

    mapping(address => address) public credit;

    function setCredit(address validator, address creditContract) external {
        credit[validator] = creditContract;
    }

    function delegate(address operatorAddress, bool delegateVotePower) external payable {
        lastDelegator = msg.sender;
        lastValidator = operatorAddress;
        lastDelegateVotePower = delegateVotePower;
        lastDelegatedAmount = msg.value;

        address creditContract = credit[operatorAddress];
        if (creditContract != address(0)) {
            // best-effort notification for tests
            (bool ok,) =
                creditContract.call(abi.encodeWithSignature("onDelegate(address,uint256)", msg.sender, msg.value));
            ok;
        }
    }

    function undelegate(address, uint256) external {}

    function getValidatorCreditContract(address operatorAddress) external view returns (address) {
        return credit[operatorAddress];
    }

    function claim(address, uint256) external {}

}

contract ValidatorCreditMock is IBSCValidatorCredit {

    mapping(address delegator => uint256 pooled) public pooledBNB;
    mapping(address delegator => uint256 lockedTotal) public lockedTotalBNB;

    function onDelegate(address delegator, uint256 amount) external {
        pooledBNB[delegator] += amount;
    }

    function claimableUnbondRequest(address) external pure returns (uint256) {
        return 0;
    }

    function lockedBNBs(address delegator, uint256 number) external view returns (uint256) {
        if (number == 0) {
            return lockedTotalBNB[delegator];
        }
        // for unit test simplicity, we don't model per-request queue here.
        return lockedTotalBNB[delegator];
    }

    function getPooledBNB(address delegator) external view returns (uint256) {
        return pooledBNB[delegator];
    }

}

contract BNBNST_Unit is Test {

    using AddressCast for address;
    using stdStorage for StdStorage;

    struct Player {
        uint256 privateKey;
        address addr;
    }

    Player internal owner;
    Player internal deployer;
    Player internal staker;

    uint32 internal constant IMUACHAIN_EID = 2;
    uint32 internal constant CLIENT_EID = 1;

    ClientChainGateway internal clientGateway;
    ILayerZeroEndpointV2 internal clientEndpoint;
    ILayerZeroEndpointV2 internal imuachainEndpoint;
    ImuachainGateway internal imuachainGateway;

    function _deliverToImuachainAndAssertAssets(bytes memory actionArgs, address capsuleAddr, address stakerAddr)
        internal
    {
        // Deliver the message on Imuachain and verify AssetsMock state updates.
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_DEPOSIT_NST, actionArgs);
        vm.prank(address(imuachainEndpoint));
        imuachainGateway.lzReceive(
            Origin(uint32(CLIENT_EID), address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );

        address VIRTUAL_NST_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        bytes memory nstToken = abi.encodePacked(bytes32(bytes20(VIRTUAL_NST_ADDRESS)));
        bytes memory stakerBytes = abi.encodePacked(bytes32(bytes20(stakerAddr)));
        bytes memory validatorId = abi.encodePacked(bytes32(bytes20(capsuleAddr)));

        assertEq(
            AssetsMock(ASSETS_PRECOMPILE_ADDRESS).getPrincipalBalance(uint32(CLIENT_EID), nstToken, stakerBytes),
            1 ether
        );
        assertTrue(AssetsMock(ASSETS_PRECOMPILE_ADDRESS).inValidatorSet(stakerBytes, validatorId));
    }

    function setUp() public {
        owner = Player({privateKey: 0xA, addr: vm.addr(0xA)});
        deployer = Player({privateKey: 0xB, addr: vm.addr(0xB)});
        staker = Player({privateKey: 0xC, addr: vm.addr(0xC)});

        vm.deal(owner.addr, 100 ether);
        vm.deal(deployer.addr, 100 ether);
        vm.deal(staker.addr, 100 ether);

        vm.chainId(CLIENT_EID);

        // bind precompile mock contracts code to constant precompile address
        vm.etch(ASSETS_PRECOMPILE_ADDRESS, vm.getDeployedCode("AssetsMock.sol"));
        vm.etch(DELEGATION_PRECOMPILE_ADDRESS, vm.getDeployedCode("DelegationMock.sol"));
        vm.etch(REWARD_PRECOMPILE_ADDRESS, vm.getDeployedCode("RewardMock.sol"));

        // endpoints
        clientEndpoint = ILayerZeroEndpointV2(address(new NonShortCircuitEndpointV2Mock(CLIENT_EID, deployer.addr)));
        imuachainEndpoint =
            ILayerZeroEndpointV2(address(new NonShortCircuitEndpointV2Mock(IMUACHAIN_EID, deployer.addr)));

        // deploy logic + proxy
        IBeaconChainOracle beaconOracle =
            IBeaconChainOracle(new EigenLayerBeaconOracle(NetworkConstants.getBeaconGenesisTimestamp()));
        Vault vaultImpl = new Vault();
        RewardVault rewardVaultImpl = new RewardVault();
        IImuaCapsule capsuleImpl = new ImuaCapsuleBSC();

        IBeacon vaultBeacon = new UpgradeableBeacon(address(vaultImpl));
        IBeacon rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImpl));
        IBeacon capsuleBeacon = new UpgradeableBeacon(address(capsuleImpl));

        BeaconProxyBytecode beaconProxyBytecode = new BeaconProxyBytecode();

        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: IMUACHAIN_EID,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        ClientChainGateway logic = new ClientChainGateway(address(clientEndpoint), config, address(rewardVaultBeacon));
        ProxyAdmin admin = new ProxyAdmin();

        clientGateway = ClientChainGateway(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(logic),
                        address(admin),
                        abi.encodeWithSelector(ClientChainGateway.initialize.selector, owner.addr)
                    )
                ))
        );

        // deploy imuachain gateway (proxy) and register client chain peer
        ProxyAdmin imuachainAdmin = new ProxyAdmin();
        ImuachainGateway imuachainLogic = new ImuachainGateway(address(imuachainEndpoint));
        imuachainGateway = ImuachainGateway(
            payable(address(new TransparentUpgradeableProxy(address(imuachainLogic), address(imuachainAdmin), "")))
        );
        vm.prank(deployer.addr);
        imuachainGateway.initialize(payable(owner.addr));

        vm.prank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            CLIENT_EID, address(clientGateway).toBytes32(), 20, "client", "unit test client", "secp256k1"
        );

        // endpoint routing (for completeness)
        NonShortCircuitEndpointV2Mock(address(clientEndpoint))
            .setDestLzEndpoint(address(imuachainGateway), address(imuachainEndpoint));
        NonShortCircuitEndpointV2Mock(address(imuachainEndpoint))
            .setDestLzEndpoint(address(clientGateway), address(clientEndpoint));

        vm.prank(owner.addr);
        clientGateway.setPeer(IMUACHAIN_EID, address(imuachainGateway).toBytes32());
    }

    function test_depositBNBNST_delegates_and_sends_request() public {
        // enable native restaking (whitelist virtual NST token)
        address VIRTUAL_NST_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        stdstore.target(address(clientGateway)).sig("isWhitelistedToken(address)").with_key(VIRTUAL_NST_ADDRESS)
            .checked_write(true);

        // create capsule
        vm.prank(staker.addr);
        address capsuleAddr = clientGateway.createImuaCapsule();

        // configure StakeHub on capsule
        StakeHubMock stakeHub = new StakeHubMock();
        ValidatorCreditMock creditMock = new ValidatorCreditMock();
        address validator = address(0xBEEF);
        stakeHub.setCredit(validator, address(creditMock));

        vm.prank(staker.addr);
        ImuaCapsuleBSC(payable(capsuleAddr)).setStakeHub(address(stakeHub));

        bytes memory actionArgs =
            abi.encodePacked(bytes32(bytes20(staker.addr)), uint256(1 ether), bytes32(bytes20(capsuleAddr)));
        bytes memory payload = abi.encodePacked(Action.REQUEST_DEPOSIT_NST, actionArgs);
        uint256 nativeFee = clientGateway.quote(payload);

        // deposit + delegate (caller pays L0 fee)
        vm.prank(staker.addr);
        clientGateway.depositBNBNST{value: 1 ether + nativeFee}(validator, 1 ether, nativeFee);

        // StakeHub.delegate called from capsule with correct amount
        assertEq(stakeHub.lastDelegator(), capsuleAddr);
        assertEq(stakeHub.lastValidator(), validator);
        assertEq(stakeHub.lastDelegatedAmount(), 1 ether);
        assertEq(stakeHub.lastDelegateVotePower(), false);

        // Capsule bound to validator + credit contract
        assertEq(ImuaCapsuleBSC(payable(capsuleAddr)).validator(), validator);
        assertEq(ImuaCapsuleBSC(payable(capsuleAddr)).validatorCreditContract(), address(creditMock));

        // Oracle/feeder view: capsule returns (pooled, locked)
        (uint256 pooled, uint256 locked) = ImuaCapsuleBSC(payable(capsuleAddr)).getPooledAndLockedBNBs();
        assertEq(pooled, 1 ether);
        assertEq(locked, 0);
        assertEq(pooled + locked, 1 ether);

        // Outbound message nonce incremented (message sent)
        uint64 outbound = NonShortCircuitEndpointV2Mock(address(clientEndpoint))
            .outboundNonce(address(clientGateway), IMUACHAIN_EID, address(imuachainGateway).toBytes32());
        assertEq(outbound, 1);

        _deliverToImuachainAndAssertAssets(actionArgs, capsuleAddr, staker.addr);

        // Gateway shouldn't keep funds
        assertEq(address(clientGateway).balance, 0);
    }

}
