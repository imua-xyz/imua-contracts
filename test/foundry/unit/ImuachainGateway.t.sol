// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {NonShortCircuitEndpointV2Mock} from "../../mocks/NonShortCircuitEndpointV2Mock.sol";
import "src/interfaces/precompiles/IAssets.sol";

import "src/interfaces/precompiles/IDelegation.sol";
import "src/interfaces/precompiles/IReward.sol";

import "src/libraries/Errors.sol";
import "test/mocks/AssetsMock.sol";

import "test/mocks/DelegationMock.sol";
import "test/mocks/RewardMock.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Test.sol";
import "src/core/ClientChainGateway.sol";

import "src/core/ClientChainGateway.sol";
import "src/core/ImuachainGateway.sol";
import {Vault} from "src/core/Vault.sol";

import {Action, GatewayStorage} from "src/storage/GatewayStorage.sol";
import {ImuachainGatewayStorage} from "src/storage/ImuachainGatewayStorage.sol";

contract SetUp is Test {

    using AddressCast for address;

    Player[] players;
    Player owner;
    Player deployer;
    Player withdrawer;

    ImuachainGateway imuachainGateway;
    ClientChainGateway clientGateway;
    ClientChainGateway solanaClientGateway;

    NonShortCircuitEndpointV2Mock imuachainLzEndpoint;
    NonShortCircuitEndpointV2Mock clientLzEndpoint;
    NonShortCircuitEndpointV2Mock solanaClientLzEndpoint;

    ERC20 restakeToken;

    uint16 imuachainChainId = 1;
    uint16 clientChainId = 2;
    uint16 solanaClientChainId = 40_168;

    struct Player {
        uint256 privateKey;
        address addr;
    }

    event Paused(address account);
    event Unpaused(address account);
    event ImuachainPrecompileError(address indexed precompile, uint64 nonce);
    event MessageSent(Action indexed act, bytes32 packetId, uint64 nonce, uint256 nativeFee);

    function setUp() public virtual {
        players.push(Player({privateKey: uint256(0x1), addr: vm.addr(uint256(0x1))}));
        players.push(Player({privateKey: uint256(0x2), addr: vm.addr(uint256(0x2))}));
        players.push(Player({privateKey: uint256(0x3), addr: vm.addr(uint256(0x3))}));
        owner = Player({privateKey: uint256(0xa), addr: vm.addr(uint256(0xa))});
        deployer = Player({privateKey: uint256(0xb), addr: vm.addr(uint256(0xb))});
        withdrawer = Player({privateKey: uint256(0xc), addr: vm.addr(uint256(0xb))});
        clientGateway = ClientChainGateway(payable(address(0xd)));
        solanaClientGateway = ClientChainGateway(payable(address(0xe)));

        // bind precompile mock contracts code to constant precompile address
        bytes memory AssetsMockCode = vm.getDeployedCode("AssetsMock.sol");
        vm.etch(ASSETS_PRECOMPILE_ADDRESS, AssetsMockCode);

        bytes memory DelegationMockCode = vm.getDeployedCode("DelegationMock.sol");
        vm.etch(DELEGATION_PRECOMPILE_ADDRESS, DelegationMockCode);

        bytes memory WithdrawRewardMockCode = vm.getDeployedCode("RewardMock.sol");
        vm.etch(REWARD_PRECOMPILE_ADDRESS, WithdrawRewardMockCode);

        _deploy();

        vm.deal(owner.addr, 100 ether);
        vm.deal(deployer.addr, 100 ether);
    }

    function _deploy() internal {
        vm.startPrank(deployer.addr);

        restakeToken = new ERC20PresetFixedSupply("rest", "rest", 1e34, owner.addr);

        imuachainLzEndpoint = new NonShortCircuitEndpointV2Mock(imuachainChainId, owner.addr);
        clientLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, owner.addr);
        solanaClientLzEndpoint = new NonShortCircuitEndpointV2Mock(solanaClientChainId, owner.addr);

        ProxyAdmin proxyAdmin = new ProxyAdmin();
        ImuachainGateway imuachainGatewayLogic = new ImuachainGateway(address(imuachainLzEndpoint));
        imuachainGateway = ImuachainGateway(
            payable(address(new TransparentUpgradeableProxy(address(imuachainGatewayLogic), address(proxyAdmin), "")))
        );

        imuachainGateway.initialize(payable(owner.addr));
        vm.stopPrank();

        vm.startPrank(owner.addr);
        imuachainLzEndpoint.setDestLzEndpoint(address(clientGateway), address(clientLzEndpoint));
        imuachainGateway.registerOrUpdateClientChain(
            clientChainId,
            address(clientGateway).toBytes32(),
            20,
            "clientChain",
            "EVM compatible client chain",
            "secp256k1"
        );

        imuachainLzEndpoint.setDestLzEndpoint(address(solanaClientGateway), address(solanaClientLzEndpoint));
        imuachainGateway.registerOrUpdateClientChain(
            solanaClientChainId,
            address(solanaClientGateway).toBytes32(),
            20,
            "solanaClientChain",
            "Non-EVM compatible client chain",
            "ed25519"
        );

        vm.stopPrank();

        // transfer some gas fee to imuachain gateway as it has to pay for the relay fee to layerzero endpoint when
        // sending back response
        deal(address(imuachainGateway), 1e22);
    }

    function generateUID(uint64 nonce, bool fromClientChainToImuachain) internal view returns (bytes32 uid) {
        uid = generateUID(nonce, fromClientChainToImuachain, false);
    }

    function generateUID(uint64 nonce, bool fromClientChainToImuachain, bool isSolanaClient)
        internal
        view
        returns (bytes32 uid)
    {
        if (fromClientChainToImuachain) {
            uid = GUID.generate(
                nonce, clientChainId, address(clientGateway), imuachainChainId, address(imuachainGateway).toBytes32()
            );
        } else {
            uint16 targetChainId = isSolanaClient ? solanaClientChainId : clientChainId;
            bytes32 targetGateway =
                isSolanaClient ? address(solanaClientGateway).toBytes32() : address(clientGateway).toBytes32();

            return GUID.generate(nonce, imuachainChainId, address(imuachainGateway), targetChainId, targetGateway);
        }
    }

}

contract Pausable is SetUp {

    using AddressCast for address;

    function test_PauseImuachainGateway() public {
        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit Paused(owner.addr);
        vm.prank(owner.addr);
        imuachainGateway.pause();
        assertEq(imuachainGateway.paused(), true);
    }

    function test_UnpauseImuachainGateway() public {
        vm.startPrank(owner.addr);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit Paused(owner.addr);
        imuachainGateway.pause();
        assertEq(imuachainGateway.paused(), true);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit Unpaused(owner.addr);
        imuachainGateway.unpause();
        assertEq(imuachainGateway.paused(), false);
    }

    function test_RevertWhen_UnauthorizedPauser() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.startPrank(deployer.addr);
        imuachainGateway.pause();
    }

    function test_RevertWhen_CallDisabledFunctionsWhenPaused() public {
        vm.prank(owner.addr);
        imuachainGateway.pause();

        vm.prank(address(imuachainLzEndpoint));
        vm.expectRevert("Pausable: paused");
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            bytes(""),
            address(0x2),
            bytes("")
        );
    }

}

contract LzReceive is SetUp {

    using AddressCast for address;

    uint256 constant WITHDRAWAL_AMOUNT = 123;
    string operator = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";

    event AssociationResult(bool indexed success, bool indexed isAssociate, bytes32 indexed staker);

    function setUp() public override {
        super.setUp();

        // bind precompile mock contracts code to constant precompile address
        bytes memory AssetsMockCode = vm.getDeployedCode("AssetsMock.sol");
        vm.etch(ASSETS_PRECOMPILE_ADDRESS, AssetsMockCode);

        bytes memory DelegationMockCode = vm.getDeployedCode("DelegationMock.sol");
        vm.etch(DELEGATION_PRECOMPILE_ADDRESS, DelegationMockCode);

        bytes memory RewardMockCode = vm.getDeployedCode("RewardMock.sol");
        vm.etch(REWARD_PRECOMPILE_ADDRESS, RewardMockCode);
    }

    function test_NotRevert_WithdrawalAmountOverflow() public {
        bytes memory payload = abi.encodePacked(
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(withdrawer.addr))),
            uint256(WITHDRAWAL_AMOUNT)
        );
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_WITHDRAW_LST, payload);

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );
    }

    function test_Success_AssociateOperatorWithStaker() public {
        Player memory staker = players[0];

        bytes memory payload = abi.encodePacked(abi.encodePacked(bytes32(bytes20(staker.addr))), bytes(operator));
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_ASSOCIATE_OPERATOR, payload);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit AssociationResult(true, true, bytes32(bytes20(staker.addr)));

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );
    }

    function test_EmitResultAsFailed_StakerAlreadyBeenAssociated() public {
        test_Success_AssociateOperatorWithStaker();

        Player memory staker = players[0];
        string memory anotherOperator = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";

        bytes memory payload = abi.encodePacked(abi.encodePacked(bytes32(bytes20(staker.addr))), bytes(anotherOperator));
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_ASSOCIATE_OPERATOR, payload);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit AssociationResult(false, true, bytes32(bytes20(staker.addr)));

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(2)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );

        bytes memory associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            clientChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(keccak256(associatedOperator), keccak256(bytes(operator)));
    }

    function test_EmitResultAsSuccess_AssociateStakerOnAnotherChain() public {
        test_Success_AssociateOperatorWithStaker();

        Player memory staker = players[0];
        string memory anotherOperator = "im13hasr43vvq8v44xpzh0l6yuym4kca98q5zpluj";
        uint32 anotherChainId = 123;

        bytes memory payload = abi.encodePacked(abi.encodePacked(bytes32(bytes20(staker.addr))), bytes(anotherOperator));
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_ASSOCIATE_OPERATOR, payload);

        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherChainId,
            address(clientGateway).toBytes32(),
            20,
            "clientChain",
            "EVM compatible client chain",
            "secp256k1"
        );
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit AssociationResult(true, true, bytes32(bytes20(staker.addr)));

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(anotherChainId, address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );

        bytes memory associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            anotherChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(keccak256(associatedOperator), keccak256(bytes(anotherOperator)));
    }

    function test_Success_DissociateOperatorFromStaker() public {
        test_Success_AssociateOperatorWithStaker();

        Player memory staker = players[0];

        bytes memory payload = abi.encodePacked(abi.encodePacked(bytes32(bytes20(staker.addr))));
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_DISSOCIATE_OPERATOR, payload);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit AssociationResult(true, false, bytes32(bytes20(staker.addr)));

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(2)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );
    }

    function test_EmitResultAsFailed_DissociateFreshStaker() public {
        Player memory staker = players[0];

        bytes memory payload = abi.encodePacked(abi.encodePacked(bytes32(bytes20(staker.addr))));
        bytes memory msg_ = abi.encodePacked(Action.REQUEST_DISSOCIATE_OPERATOR, payload);

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit AssociationResult(false, false, bytes32(bytes20(staker.addr)));

        vm.prank(address(imuachainLzEndpoint));
        imuachainGateway.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), uint64(1)),
            bytes32(0),
            msg_,
            address(0x2),
            bytes("")
        );
    }

}

contract RegisterOrUpdateClientChain is SetUp {

    using AddressCast for address;

    event ClientChainRegistered(uint32 clientChainId);
    event ClientChainUpdated(uint32 clientChainId);

    uint32 anotherClientChain;
    bytes32 peer;
    uint8 addressLength;
    string name;
    string metaInfo;
    string signatureType;

    function test_Success_RegisterClientChain() public {
        _prepareClientChainData();

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit ClientChainRegistered(anotherClientChain);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_Success_UpdateClientChain() public {
        test_Success_RegisterClientChain();

        peer = bytes32(uint256(321));
        metaInfo = "Testnet";

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit ClientChainUpdated(anotherClientChain);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_CallerNotOwner() public {
        _prepareClientChainData();

        vm.startPrank(deployer.addr);
        vm.expectRevert("Ownable: caller is not the owner");
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_Paused() public {
        vm.startPrank(owner.addr);
        imuachainGateway.pause();

        _prepareClientChainData();

        vm.expectRevert("Pausable: paused");
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_ZeroOrEmptyClientChain() public {
        _prepareClientChainData();
        anotherClientChain = 0;

        vm.expectRevert(Errors.ZeroValue.selector);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_ZeroOrEmptyPeer() public {
        _prepareClientChainData();
        peer = bytes32(0);

        vm.expectRevert(Errors.ZeroValue.selector);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_ZeroOrEmptyAddressLength() public {
        _prepareClientChainData();
        addressLength = 0;

        vm.expectRevert(Errors.ZeroValue.selector);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_EmptyName() public {
        _prepareClientChainData();
        name = "";

        vm.expectRevert(Errors.ZeroValue.selector);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function test_RevertWhen_EmptyMetaInfo() public {
        _prepareClientChainData();
        metaInfo = "";

        vm.expectRevert(Errors.ZeroValue.selector);
        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, peer, addressLength, name, metaInfo, signatureType
        );
    }

    function _prepareClientChainData() internal {
        anotherClientChain = clientChainId + 1;
        peer = bytes32(uint256(123));
        addressLength = 20;
        name = "AnotherClientChain";
        metaInfo = "EVM compatible client chain";
        signatureType = "secp256k1";
    }

}

contract SetPeer is SetUp {

    ImuachainGateway gateway;

    uint32 anotherClientChain = clientChainId + 1;
    bytes32 anotherPeer = bytes32("0xabcdef");
    bytes32 newPeer = bytes32("0x123");

    event PeerSet(uint32 eid, bytes32 peer);

    function test_Success_SetPeer() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit PeerSet(anotherClientChain, anotherPeer);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, anotherPeer, 20, "Test Chain", "Test Meta", "ECDSA"
        );

        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit PeerSet(anotherClientChain, newPeer);
        imuachainGateway.setPeer(anotherClientChain, newPeer);
    }

    function test_RevertWhen_CallerNotOwner() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(true, true, true, true, address(imuachainGateway));
        emit PeerSet(anotherClientChain, anotherPeer);
        imuachainGateway.registerOrUpdateClientChain(
            anotherClientChain, anotherPeer, 20, "Test Chain", "Test Meta", "ECDSA"
        );
        vm.stopPrank();

        vm.startPrank(deployer.addr);
        vm.expectRevert("Ownable: caller is not the owner");
        imuachainGateway.setPeer(anotherClientChain, newPeer);
    }

    function test_RevertWhen_ClientChainNotRegistered() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(Errors.ImuachainGatewayNotRegisteredClientChainId.selector);
        imuachainGateway.setPeer(anotherClientChain, newPeer);
    }

}

contract AddWhitelistTokens is SetUp {

    using stdStorage for StdStorage;
    using AddressCast for address;

    uint256 MESSAGE_LENGTH = 1 + 32 + 16; // action + token address as bytes32 + uint128 tvl limit
    uint256 nativeFee;
    uint256 nativeFeeForSolana;

    error IncorrectNativeFee(uint256 amount);

    event WhitelistTokenAdded(uint32 clientChainId, bytes32 token);

    function setUp() public virtual override {
        super.setUp();
        nativeFee = imuachainGateway.quote(clientChainId, new bytes(MESSAGE_LENGTH));
        bytes memory message = new bytes(MESSAGE_LENGTH);
        message[0] = bytes1(abi.encodePacked(Action.REQUEST_ADD_WHITELIST_TOKEN));
        nativeFeeForSolana = imuachainGateway.quote(solanaClientChainId, message);
    }

    function test_RevertWhen_CallerNotOwner() public {
        vm.startPrank(deployer.addr);
        vm.expectRevert("Ownable: caller is not the owner");
        imuachainGateway.addWhitelistToken{value: nativeFee}(
            clientChainId, bytes32(0), 18, "name", "metadata", "oracleInfo", 0
        );
    }

    function test_RevertWhen_Paused() public {
        vm.startPrank(owner.addr);
        imuachainGateway.pause();
        vm.expectRevert("Pausable: paused");
        imuachainGateway.addWhitelistToken{value: nativeFee}(
            clientChainId, bytes32(0), 18, "name", "metadata", "oracleInfo", 0
        );
    }

    function test_RevertWhen_ZeroValue() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(IncorrectNativeFee.selector, uint256(0)));
        imuachainGateway.addWhitelistToken{value: 0}(
            clientChainId, bytes32(bytes20(address(restakeToken))), 18, "name", "metadata", "oracleInfo", 0
        );
    }

    function test_RevertWhen_HasZeroAddressToken() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        imuachainGateway.addWhitelistToken{value: nativeFee}(
            clientChainId, bytes32(0), 18, "name", "metadata", "oracleInfo", 0
        );
    }

    function test_Success_AddWhiteListToken() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(address(imuachainGateway));
        emit WhitelistTokenAdded(clientChainId, bytes32(bytes20(address(restakeToken))));
        vm.expectEmit(address(imuachainGateway));
        emit MessageSent(Action.REQUEST_ADD_WHITELIST_TOKEN, generateUID(1, false), 1, nativeFee);
        imuachainGateway.addWhitelistToken{value: nativeFee}(
            clientChainId,
            bytes32(bytes20(address(restakeToken))),
            18,
            "RestakeToken",
            "ERC20 LST token",
            "oracleInfo",
            5000 * 1e18
        );
        vm.stopPrank();
    }

    function test_Success_AddWhiteListTokenOnSolana() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(address(imuachainGateway));
        emit WhitelistTokenAdded(solanaClientChainId, bytes32(bytes20(address(restakeToken))));
        vm.expectEmit(address(imuachainGateway));
        emit MessageSent(Action.REQUEST_ADD_WHITELIST_TOKEN, generateUID(1, false, true), 1, nativeFeeForSolana);
        imuachainGateway.addWhitelistToken{value: nativeFeeForSolana}(
            solanaClientChainId,
            bytes32(bytes20(address(restakeToken))),
            9,
            "RestakeToken",
            "Spl LST token",
            "oracleInfo",
            5000 * 1e9
        );
        vm.stopPrank();
    }

}

contract UpdateWhitelistTokens is SetUp {

    struct TokenDetails {
        bytes32 tokenAddress;
        uint8 decimals;
        string name;
        string metaData;
        string oracleInfo;
    }

    TokenDetails tokenDetails;

    event WhitelistTokenAdded(uint32 clientChainId, bytes32 token);
    event WhitelistTokenUpdated(uint32 clientChainId, bytes32 token);

    function setUp() public virtual override {
        super.setUp();
        // the below code is intentionally repeated here, instead of inheriting it from AddWhitelistTokens
        // this is done to not conflate the tests of AddWhitelistTokens with UpdateWhitelistTokens
        uint256 MESSAGE_LENGTH = 1 + 32 + 16; // action + token address as bytes32 + uint128
        uint256 nativeFee = imuachainGateway.quote(clientChainId, new bytes(MESSAGE_LENGTH));
        vm.startPrank(owner.addr);
        vm.expectEmit(address(imuachainGateway));
        emit WhitelistTokenAdded(clientChainId, bytes32(bytes20(address(restakeToken))));
        vm.expectEmit(address(imuachainGateway));
        emit MessageSent(Action.REQUEST_ADD_WHITELIST_TOKEN, generateUID(1, false), 1, nativeFee);
        imuachainGateway.addWhitelistToken{value: nativeFee}(
            clientChainId,
            bytes32(bytes20(address(restakeToken))),
            18,
            "RestakeToken",
            "ERC20 LST token",
            "oracleInfo",
            5000 * 1e18
        );
        vm.stopPrank();
        tokenDetails = TokenDetails({
            tokenAddress: bytes32(bytes20(address(restakeToken))),
            decimals: 18,
            name: "RestakeToken",
            metaData: "ERC20 LST token",
            oracleInfo: "oracleInfo"
        });
    }

    function test_RevertUpdateWhen_CallerNotOwner() public {
        vm.startPrank(deployer.addr);
        vm.expectRevert("Ownable: caller is not the owner");
        imuachainGateway.updateWhitelistToken(clientChainId, tokenDetails.tokenAddress, tokenDetails.metaData);
    }

    function test_RevertUpdateWhen_Paused() public {
        vm.startPrank(owner.addr);
        imuachainGateway.pause();
        vm.expectRevert("Pausable: paused");
        imuachainGateway.updateWhitelistToken(clientChainId, tokenDetails.tokenAddress, tokenDetails.metaData);
    }

    function test_RevertUpdateWhen_HasZeroAddress() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        imuachainGateway.updateWhitelistToken(clientChainId, bytes32(0), tokenDetails.metaData);
    }

    function test_RevertUpdateWhen_HasZeroChainId() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroValue.selector));
        imuachainGateway.updateWhitelistToken(0, tokenDetails.tokenAddress, tokenDetails.metaData);
    }

    function test_Success_UpdateWhitelistToken() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(address(imuachainGateway));
        emit WhitelistTokenUpdated(clientChainId, tokenDetails.tokenAddress);
        imuachainGateway.updateWhitelistToken(clientChainId, tokenDetails.tokenAddress, "new metadata");
    }

}

contract AssociateOperatorWithEVMStaker is SetUp {

    using AddressCast for address;

    string operator = "im13hasr43vvq8v44xpzh0l6yuym4kca98q5zpluj";
    string anotherOperator = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
    uint32 anotherChainId = 123;

    function test_Success_AssociateEVMStaker() public {
        Player memory staker = players[0];
        vm.startPrank(staker.addr);
        imuachainGateway.associateOperatorWithEVMStaker(clientChainId, operator);

        bytes memory associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            clientChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(keccak256(associatedOperator), keccak256(bytes(operator)));
    }

    function test_RevertWhen_ClientChainNotRegistered() public {
        Player memory staker = players[0];
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AssociateOperatorFailed.selector, anotherChainId, staker.addr, operator)
        );
        vm.startPrank(staker.addr);
        imuachainGateway.associateOperatorWithEVMStaker(anotherChainId, operator);
    }

    function test_RevertWhen_AssociateMarkedStaker() public {
        test_Success_AssociateEVMStaker();

        Player memory staker = players[0];
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AssociateOperatorFailed.selector, clientChainId, staker.addr, anotherOperator)
        );
        vm.startPrank(staker.addr);
        imuachainGateway.associateOperatorWithEVMStaker(clientChainId, anotherOperator);
    }

    function test_Success_AssociateSameStakerButAnotherChain() public {
        test_Success_AssociateEVMStaker();

        vm.startPrank(owner.addr);
        imuachainGateway.registerOrUpdateClientChain(
            anotherChainId,
            address(clientGateway).toBytes32(),
            20,
            "clientChain",
            "EVM compatible client chain",
            "secp256k1"
        );
        vm.stopPrank();

        Player memory staker = players[0];
        vm.startPrank(staker.addr);
        imuachainGateway.associateOperatorWithEVMStaker(anotherChainId, anotherOperator);

        bytes memory associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            clientChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(keccak256(associatedOperator), keccak256(bytes(operator)));
        associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            anotherChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(keccak256(associatedOperator), keccak256(bytes(anotherOperator)));
    }

    function test_Success_DissociateEVMStaker() public {
        test_Success_AssociateEVMStaker();

        Player memory staker = players[0];
        vm.startPrank(staker.addr);
        imuachainGateway.dissociateOperatorFromEVMStaker(clientChainId);

        bytes memory associatedOperator = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getAssociatedOperator(
            clientChainId, abi.encodePacked(bytes32(bytes20(staker.addr)))
        );
        assertEq(associatedOperator.length, 0);
    }

    function test_RevertWhen_DissociateClientChainNotRegistered() public {
        Player memory staker = players[0];
        vm.expectRevert(abi.encodeWithSelector(Errors.DissociateOperatorFailed.selector, anotherChainId, staker.addr));
        vm.startPrank(staker.addr);
        imuachainGateway.dissociateOperatorFromEVMStaker(anotherChainId);
    }

    function test_RevertWhen_DissociatePureStaker() public {
        Player memory staker = players[0];
        vm.expectRevert(abi.encodeWithSelector(Errors.DissociateOperatorFailed.selector, clientChainId, staker.addr));
        vm.startPrank(staker.addr);
        imuachainGateway.dissociateOperatorFromEVMStaker(clientChainId);
    }

}

contract MarkBootstrap is SetUp {

    uint256 nativeFee;

    error NoPeer(uint32 chainId);

    function setUp() public virtual override {
        super.setUp();
        nativeFee = imuachainGateway.quote(clientChainId, abi.encodePacked(Action.REQUEST_MARK_BOOTSTRAP, ""));
    }

    function test_Success() public {
        vm.startPrank(owner.addr);
        vm.expectEmit(address(imuachainGateway));
        emit ImuachainGatewayStorage.BootstrapRequestSent(clientChainId);
        imuachainGateway.markBootstrap{value: nativeFee}(clientChainId);
    }

    function test_Fail() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(NoPeer.selector, clientChainId + 1));
        imuachainGateway.markBootstrap{value: nativeFee}(clientChainId + 1);
    }

}
