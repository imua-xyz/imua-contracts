// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {UTXOGateway} from "src/core/UTXOGateway.sol";

import "src/interfaces/precompiles/IAssets.sol";
import "src/interfaces/precompiles/IDelegation.sol";
import "src/interfaces/precompiles/IReward.sol";
import {Errors} from "src/libraries/Errors.sol";

import {ImuachainBytes} from "src/libraries/ImuachainBytes.sol";
import {SignatureVerifier} from "src/libraries/SignatureVerifier.sol";
import {UTXOGatewayStorage} from "src/storage/UTXOGatewayStorage.sol";
import "test/mocks/AssetsMock.sol";
import "test/mocks/DelegationMock.sol";
import "test/mocks/RewardMock.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UTXOGatewayTest is Test {

    using stdStorage for StdStorage;
    using SignatureVerifier for bytes32;
    using ImuachainBytes for address;

    struct Player {
        uint256 privateKey;
        address addr;
    }

    UTXOGateway gateway;
    UTXOGateway gatewayLogic;
    address owner;
    address user;
    address relayer;
    Player[3] witnesses;
    bytes btcAddress;
    string operator;

    address public constant IMUACHAIN_WITNESS = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);

    // chain id from layerzero, virtual for bitcoin since it's not yet a layerzero chain
    string public constant BITCOIN_NAME = "Bitcoin";
    string public constant BITCOIN_METADATA = "Bitcoin";
    string public constant BITCOIN_SIGNATURE_SCHEME = "ECDSA";
    uint8 public constant STAKER_ACCOUNT_LENGTH = 20;

    // virtual token address and token, shared for tokens supported by the gateway
    address public constant VIRTUAL_TOKEN_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    bytes public constant VIRTUAL_TOKEN = abi.encodePacked(bytes32(bytes20(VIRTUAL_TOKEN_ADDRESS)));

    uint8 public constant BTC_DECIMALS = 8;
    string public constant BTC_NAME = "BTC";
    string public constant BTC_METADATA = "BTC";
    string public constant BTC_ORACLE_INFO = "BTC,BITCOIN,8";

    uint256 public initialRequiredProofs = 3;
    uint256 public constant PROOF_TIMEOUT = 1 days;

    event WitnessAdded(address indexed witness);
    event WitnessRemoved(address indexed witness);
    event AddressRegistered(
        UTXOGatewayStorage.ClientChainID indexed chainId, bytes depositor, address indexed imuachainAddress
    );
    event DepositCompleted(
        UTXOGatewayStorage.ClientChainID indexed chainId,
        bytes32 indexed clientTxId,
        address indexed imuachainAddress,
        bytes srcAddress,
        uint256 amount,
        uint256 updatedBalance
    );
    event DelegationCompleted(
        UTXOGatewayStorage.ClientChainID indexed chainId, address indexed delegator, string operator, uint256 amount
    );
    event UndelegationCompleted(
        UTXOGatewayStorage.ClientChainID indexed clientChainId,
        address indexed imDelegator,
        string operator,
        uint256 amount
    );
    event ProofSubmitted(bytes32 indexed messageHash, address indexed witness);
    event BridgeFeeRateUpdated(uint256 newRate);

    event ClientChainRegistered(UTXOGatewayStorage.ClientChainID indexed clientChainId);
    event ClientChainUpdated(UTXOGatewayStorage.ClientChainID indexed clientChainId);
    event WhitelistTokenAdded(UTXOGatewayStorage.ClientChainID indexed clientChainId, address indexed token);
    event WhitelistTokenUpdated(UTXOGatewayStorage.ClientChainID indexed clientChainId, address indexed token);
    event DelegationFailedForStake(
        UTXOGatewayStorage.ClientChainID indexed clientChainId,
        address indexed imDelegator,
        string operator,
        uint256 amount
    );
    event StakeMsgExecuted(
        UTXOGatewayStorage.ClientChainID indexed chainId,
        uint64 indexed nonce,
        address indexed imuachainAddress,
        uint256 amount
    );
    event TransactionProcessed(bytes32 indexed txId);

    event WithdrawPrincipalRequested(
        UTXOGatewayStorage.ClientChainID indexed srcChainId,
        uint64 indexed requestId,
        address indexed withdrawerImAddr,
        bytes withdrawerClientChainAddr,
        uint256 amount,
        uint256 updatedBalance
    );
    event WithdrawRewardRequested(
        UTXOGatewayStorage.ClientChainID indexed srcChainId,
        uint64 indexed requestId,
        address indexed withdrawerImAddr,
        bytes withdrawerClientChainAddr,
        uint256 amount,
        uint256 updatedBalance
    );
    event PegOutRequestProcessing(
        uint8 withdrawType,
        UTXOGatewayStorage.ClientChainID indexed clientChainId,
        uint64 indexed requestNonce,
        address indexed requester,
        bytes clientAddress,
        uint256 amount
    );
    event PegOutRequestProcessed(
        UTXOGatewayStorage.ClientChainID indexed clientChainId, uint64 indexed requestNonce, bytes32 indexed pegOutTxId
    );

    event ConsensusActivated(uint256 requiredProofs, uint256 authorizedWitnessCount);
    event ConsensusDeactivated(uint256 requiredProofs, uint256 authorizedWitnessCount);
    event MinProofsUpdated(uint256 indexed oldNumber, uint256 indexed newNumber);

    function setUp() public {
        owner = address(1);
        user = address(2);
        relayer = address(3);
        witnesses[0] = Player({privateKey: 0xa, addr: vm.addr(0xa)});
        witnesses[1] = Player({privateKey: 0xb, addr: vm.addr(0xb)});
        witnesses[2] = Player({privateKey: 0xc, addr: vm.addr(0xc)});

        btcAddress = bytes("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa");
        operator = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";

        // Deploy and initialize gateway
        gatewayLogic = new UTXOGateway();
        gateway = UTXOGateway(address(new TransparentUpgradeableProxy(address(gatewayLogic), address(0xab), "")));
        address[] memory initialWitnesses = new address[](1);
        initialWitnesses[0] = witnesses[0].addr;
        gateway.initialize(owner, initialWitnesses, initialRequiredProofs);
    }

    function test_initialize() public {
        assertEq(gateway.owner(), owner);
        assertTrue(gateway.authorizedWitnesses(witnesses[0].addr));
        assertEq(gateway.authorizedWitnessCount(), 1);
        assertEq(gateway.requiredProofs(), initialRequiredProofs);
        assertFalse(gateway.isConsensusRequired());
    }

    function test_UpdateRequiredProofs_Success() public {
        uint256 oldRequiredProofs = gateway.requiredProofs();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MinProofsUpdated(oldRequiredProofs, 2);
        gateway.updateRequiredProofs(2);

        assertEq(gateway.requiredProofs(), 2);
    }

    function test_UpdateRequiredProofs_ConsensusStateChange() public {
        // Initially consensus should be inactive (1 witnesses < 3 required)
        assertFalse(gateway.isConsensusRequired());
        uint256 oldRequiredProofs = gateway.requiredProofs();
        uint256 witnessCount = gateway.authorizedWitnessCount();

        // Lower required proofs to 1, should activate consensus
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MinProofsUpdated(oldRequiredProofs, witnessCount);
        vm.expectEmit(true, true, true, true);
        emit ConsensusActivated(witnessCount, witnessCount);
        gateway.updateRequiredProofs(witnessCount);

        assertTrue(gateway.isConsensusRequired());
    }

    function test_UpdateRequiredProofs_RevertInvalidValue() public {
        vm.startPrank(owner);
        vm.expectRevert(Errors.InvalidRequiredProofs.selector);
        gateway.updateRequiredProofs(0); // Below minimum

        vm.expectRevert(Errors.InvalidRequiredProofs.selector);
        gateway.updateRequiredProofs(11); // Above maximum
        vm.stopPrank();
    }

    function test_UpdateRequiredProofs_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.updateRequiredProofs(2);
    }

    function test_UpdateRequiredProofs_RevertWhenPaused() public {
        vm.startPrank(owner);
        gateway.pause();

        vm.expectRevert("Pausable: paused");
        gateway.updateRequiredProofs(2);
        vm.stopPrank();
    }

    function test_AddWitnesses_Success() public {
        vm.prank(owner);

        vm.expectEmit(true, false, false, false);
        emit WitnessAdded(witnesses[1].addr);

        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = witnesses[1].addr;
        gateway.addWitnesses(witnessesToAdd);
        assertTrue(gateway.authorizedWitnesses(witnesses[1].addr));
        assertEq(gateway.authorizedWitnessCount(), 2);
    }

    function test_AddWitnesses_RevertNotOwner() public {
        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = witnesses[1].addr;

        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.addWitnesses(witnessesToAdd);
    }

    function test_AddWitnesses_RevertZeroAddress() public {
        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = address(0);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.addWitnesses(witnessesToAdd);
    }

    function test_AddWitnesses_RevertAlreadyAuthorized() public {
        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = witnesses[1].addr;

        vm.startPrank(owner);
        gateway.addWitnesses(witnessesToAdd);

        // Try to add the same witness again
        vm.expectRevert(abi.encodeWithSelector(Errors.WitnessAlreadyAuthorized.selector, witnesses[1].addr));
        gateway.addWitnesses(witnessesToAdd);
        vm.stopPrank();
    }

    function test_AddWitnesses_RevertWhenPaused() public {
        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = witnesses[1].addr;

        vm.startPrank(owner);
        gateway.pause();

        vm.expectRevert("Pausable: paused");
        gateway.addWitnesses(witnessesToAdd);
        vm.stopPrank();
    }

    function test_AddWitnesses_ConsensusActivation() public {
        // initially we have 1 witness, and required proofs is 3
        assertEq(gateway.authorizedWitnessCount(), 1);
        assertEq(gateway.requiredProofs(), 3);
        assertFalse(gateway.isConsensusRequired());

        address[] memory witnessesToAdd = new address[](1);

        vm.startPrank(owner);
        // Add second witness - no consensus event
        witnessesToAdd[0] = witnesses[1].addr;
        gateway.addWitnesses(witnessesToAdd);

        // Add third witness - should emit ConsensusActivated
        witnessesToAdd[0] = witnesses[2].addr;
        vm.expectEmit(true, true, true, true);
        emit ConsensusActivated(gateway.requiredProofs(), gateway.authorizedWitnessCount() + 1);
        gateway.addWitnesses(witnessesToAdd);

        // Add fourth witness - no consensus event
        witnessesToAdd[0] = address(0xaa);
        gateway.addWitnesses(witnessesToAdd);

        vm.stopPrank();
    }

    function test_RemoveWitnesses() public {
        vm.startPrank(owner);
        address[] memory witnessesToAdd = new address[](1);

        // we need to add a witness before removing the first witness, since we cannot remove the last witness
        witnessesToAdd[0] = witnesses[1].addr;
        gateway.addWitnesses(witnessesToAdd);
        assertTrue(gateway.authorizedWitnesses(witnesses[1].addr));
        assertEq(gateway.authorizedWitnessCount(), 2);

        vm.expectEmit(true, false, false, false);
        emit WitnessRemoved(witnesses[0].addr);

        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[0].addr;
        gateway.removeWitnesses(witnessesToRemove);
        assertFalse(gateway.authorizedWitnesses(witnesses[0].addr));
        assertEq(gateway.authorizedWitnessCount(), 1);
    }

    function test_RemoveWitnesses_RevertNotOwner() public {
        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[0].addr;

        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.removeWitnesses(witnessesToRemove);
    }

    function test_RemoveWitnesses_RevertWitnessNotAuthorized() public {
        // first add another witness to make total witnesses count 2
        address[] memory witnessesToAdd = new address[](1);
        witnessesToAdd[0] = witnesses[1].addr;
        vm.startPrank(owner);
        gateway.addWitnesses(witnessesToAdd);

        // try to remove the unauthorized one
        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[2].addr;
        vm.expectRevert(abi.encodeWithSelector(Errors.WitnessNotAuthorized.selector, witnesses[2].addr));
        gateway.removeWitnesses(witnessesToRemove);
        vm.stopPrank();
    }

    function test_RemoveWitnesses_RevertWhenPaused() public {
        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[0].addr;

        vm.startPrank(owner);
        gateway.pause();

        vm.expectRevert("Pausable: paused");
        gateway.removeWitnesses(witnessesToRemove);
        vm.stopPrank();
    }

    function test_RemoveWitnesses_CannotRemoveLastWitness() public {
        // there should be only one witness added
        assertEq(gateway.authorizedWitnessCount(), 1);

        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[0].addr;

        vm.startPrank(owner);
        // Try to remove the hardcoded witness
        vm.expectRevert(Errors.CannotRemoveLastWitness.selector);
        gateway.removeWitnesses(witnessesToRemove);
        vm.stopPrank();
    }

    function test_RemoveWitnesses_MultipleRemovals() public {
        vm.startPrank(owner);

        // First add another 2 witnesses
        address[] memory witnessesToAdd = new address[](2);
        witnessesToAdd[0] = witnesses[1].addr;
        witnessesToAdd[1] = witnesses[2].addr;
        gateway.addWitnesses(witnessesToAdd);
        assertTrue(gateway.authorizedWitnesses(witnesses[1].addr));
        assertTrue(gateway.authorizedWitnesses(witnesses[2].addr));
        assertEq(gateway.authorizedWitnessCount(), 3);

        // Remove first witness
        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[0].addr;
        gateway.removeWitnesses(witnessesToRemove);
        assertFalse(gateway.authorizedWitnesses(witnesses[0].addr));
        assertTrue(gateway.authorizedWitnesses(witnesses[1].addr));
        assertEq(gateway.authorizedWitnessCount(), 2);

        // Remove second witness
        witnessesToRemove[0] = witnesses[1].addr;
        gateway.removeWitnesses(witnessesToRemove);
        assertFalse(gateway.authorizedWitnesses(witnesses[1].addr));
        assertEq(gateway.authorizedWitnessCount(), 1);

        vm.stopPrank();
    }

    function test_RemoveWitnesses_ConsensusDeactivation() public {
        // add total 3 witnesses
        _addAllWitnesses();

        // set required proofs to 2
        vm.startPrank(owner);
        gateway.updateRequiredProofs(2);

        // Remove one witness - no consensus event
        address[] memory witnessesToRemove = new address[](1);
        witnessesToRemove[0] = witnesses[2].addr;
        gateway.removeWitnesses(witnessesToRemove);

        // Remove another witness - should emit ConsensusDeactivated
        vm.expectEmit(true, true, true, true);
        emit ConsensusDeactivated(gateway.requiredProofs(), gateway.authorizedWitnessCount() - 1);
        witnessesToRemove[0] = witnesses[1].addr;
        gateway.removeWitnesses(witnessesToRemove);
        vm.stopPrank();
    }

    function test_UpdateBridgeFee() public {
        uint256 newFee = 500; // 5%

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BridgeFeeRateUpdated(newFee);

        gateway.updateBridgeFeeRate(newFee);
        assertEq(gateway.bridgeFeeRate(), newFee);
    }

    function test_UpdateBridgeFee_Zero() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BridgeFeeRateUpdated(0);

        gateway.updateBridgeFeeRate(0);
        assertEq(gateway.bridgeFeeRate(), 0);
    }

    function test_UpdateBridgeFee_MaxFee() public {
        uint256 maxFee = 1000; // 10%

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BridgeFeeRateUpdated(maxFee);

        gateway.updateBridgeFeeRate(maxFee);
        assertEq(gateway.bridgeFeeRate(), maxFee);
    }

    function test_UpdateBridgeFee_RevertExceedMax() public {
        vm.prank(owner);
        vm.expectRevert("Fee cannot exceed max bridge fee rate");
        gateway.updateBridgeFeeRate(1001); // 10.01%
    }

    function test_UpdateBridgeFee_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.updateBridgeFeeRate(500);
    }

    function test_UpdateBridgeFee_RevertWhenPaused() public {
        vm.startPrank(owner);
        gateway.pause();

        vm.expectRevert("Pausable: paused");
        gateway.updateBridgeFeeRate(500);
        vm.stopPrank();
    }

    function test_UpdateBridgeFee_MultipleFeeUpdates() public {
        vm.startPrank(owner);

        // First update
        uint256 firstFee = 300;
        vm.expectEmit(true, false, false, true);
        emit BridgeFeeRateUpdated(firstFee);
        gateway.updateBridgeFeeRate(firstFee);
        assertEq(gateway.bridgeFeeRate(), firstFee);

        // Second update
        uint256 secondFee = 700;
        vm.expectEmit(true, false, false, true);
        emit BridgeFeeRateUpdated(secondFee);
        gateway.updateBridgeFeeRate(secondFee);
        assertEq(gateway.bridgeFeeRate(), secondFee);

        vm.stopPrank();
    }

    function test_ActivateStakingForClientChain_Success() public {
        vm.startPrank(owner);

        // Mock successful chain registration
        bytes memory chainRegisterCall = abi.encodeWithSelector(
            IAssets.registerOrUpdateClientChain.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            STAKER_ACCOUNT_LENGTH,
            BITCOIN_NAME,
            BITCOIN_METADATA,
            BITCOIN_SIGNATURE_SCHEME
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            chainRegisterCall,
            abi.encode(true, false) // success = true, updated = false (new registration)
        );

        // Mock successful token registration
        bytes memory tokenRegisterCall = abi.encodeWithSelector(
            IAssets.registerToken.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            BTC_DECIMALS,
            BTC_NAME,
            BTC_METADATA,
            BTC_ORACLE_INFO
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            tokenRegisterCall,
            abi.encode(true) // success = true
        );

        vm.expectEmit(true, false, false, false);
        emit ClientChainRegistered(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.expectEmit(true, false, false, false);
        emit WhitelistTokenAdded(UTXOGatewayStorage.ClientChainID.BITCOIN, VIRTUAL_TOKEN_ADDRESS);

        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.stopPrank();
    }

    function test_ActivateStakingForClientChain_UpdateExisting() public {
        vm.startPrank(owner);

        // Mock chain update
        bytes memory chainRegisterCall = abi.encodeWithSelector(
            IAssets.registerOrUpdateClientChain.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            STAKER_ACCOUNT_LENGTH,
            BITCOIN_NAME,
            BITCOIN_METADATA,
            BITCOIN_SIGNATURE_SCHEME
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            chainRegisterCall,
            abi.encode(true, true) // success = true, updated = true (updating existing)
        );

        // Mock token update
        bytes memory tokenRegisterCall = abi.encodeWithSelector(
            IAssets.registerToken.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            BTC_DECIMALS,
            BTC_NAME,
            BTC_METADATA,
            BTC_ORACLE_INFO
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            tokenRegisterCall,
            abi.encode(false) // registration fails, indicating existing token
        );

        // Mock token update call
        bytes memory tokenUpdateCall = abi.encodeWithSelector(
            IAssets.updateToken.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            BTC_METADATA
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            tokenUpdateCall,
            abi.encode(true) // update succeeds
        );

        vm.expectEmit(true, false, false, false);
        emit ClientChainUpdated(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.expectEmit(true, false, false, false);
        emit WhitelistTokenUpdated(UTXOGatewayStorage.ClientChainID.BITCOIN, VIRTUAL_TOKEN_ADDRESS);

        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.stopPrank();
    }

    function test_ActivateStakingForClientChain_RevertChainRegistrationFailed() public {
        vm.startPrank(owner);

        // Mock failed chain registration
        bytes memory chainRegisterCall = abi.encodeWithSelector(
            IAssets.registerOrUpdateClientChain.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            STAKER_ACCOUNT_LENGTH,
            BITCOIN_NAME,
            BITCOIN_METADATA,
            BITCOIN_SIGNATURE_SCHEME
        );
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            chainRegisterCall,
            abi.encode(false, false) // registration failed
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.RegisterClientChainToImuachainFailed.selector,
                uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN))
            )
        );
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.stopPrank();
    }

    function test_ActivateStakingForClientChain_RevertTokenRegistrationAndUpdateFailed() public {
        vm.startPrank(owner);

        // Mock successful chain registration
        bytes memory chainRegisterCall = abi.encodeWithSelector(
            IAssets.registerOrUpdateClientChain.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            STAKER_ACCOUNT_LENGTH,
            BITCOIN_NAME,
            BITCOIN_METADATA,
            BITCOIN_SIGNATURE_SCHEME
        );
        vm.mockCall(ASSETS_PRECOMPILE_ADDRESS, chainRegisterCall, abi.encode(true, false));

        // Mock failed token registration
        bytes memory tokenRegisterCall = abi.encodeWithSelector(
            IAssets.registerToken.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            BTC_DECIMALS,
            BTC_NAME,
            BTC_METADATA,
            BTC_ORACLE_INFO
        );
        vm.mockCall(ASSETS_PRECOMPILE_ADDRESS, tokenRegisterCall, abi.encode(false));

        // Mock failed token update
        bytes memory tokenUpdateCall = abi.encodeWithSelector(
            IAssets.updateToken.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            BTC_METADATA
        );
        vm.mockCall(ASSETS_PRECOMPILE_ADDRESS, tokenUpdateCall, abi.encode(false));

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AddWhitelistTokenFailed.selector,
                uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
                bytes32(VIRTUAL_TOKEN)
            )
        );
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.stopPrank();
    }

    function test_ActivateStakingForClientChain_RevertInvalidChain() public {
        vm.prank(owner);
        vm.expectRevert(Errors.InvalidClientChain.selector);
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.NONE);
    }

    function test_ActivateStakingForClientChain_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
    }

    function test_ActivateStakingForClientChain_RevertWhenPaused() public {
        vm.startPrank(owner);
        gateway.pause();

        vm.expectRevert("Pausable: paused");
        gateway.activateStakingForClientChain(UTXOGatewayStorage.ClientChainID.BITCOIN);
        vm.stopPrank();
    }

    function test_SubmitProofForStakeMsg_Success() public {
        _addAllWitnesses();
        _activateConsensus();

        // Create stake message
        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        bytes32 txId = _getMessageHash(stakeMsg);
        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        // Submit proof from first witness
        vm.prank(relayer);
        vm.expectEmit(true, true, false, true);
        emit ProofSubmitted(txId, witnesses[0].addr);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature);

        // Submit proof from second witness
        signature = _generateSignature(stakeMsg, witnesses[1].privateKey);
        vm.prank(relayer);
        vm.expectEmit(true, true, false, true);
        emit ProofSubmitted(txId, witnesses[1].addr);
        gateway.submitProofForStakeMsg(witnesses[1].addr, stakeMsg, signature);

        // Submit proof from thrid witness and trigger message execution as we have enough proofs
        // mock Assets precompile deposit success and Delegation precompile delegate success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, stakeMsg.amount)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        signature = _generateSignature(stakeMsg, witnesses[2].privateKey);
        vm.prank(relayer);
        vm.expectEmit(true, false, false, false);
        emit StakeMsgExecuted(stakeMsg.clientChainId, stakeMsg.nonce, stakeMsg.imuachainAddress, stakeMsg.amount);
        vm.expectEmit(true, false, false, false);
        emit TransactionProcessed(txId);
        gateway.submitProofForStakeMsg(witnesses[2].addr, stakeMsg, signature);

        // Verify message was processed
        assertTrue(gateway.clientTxIdToNonce(stakeMsg.clientChainId, stakeMsg.clientTxId) == stakeMsg.nonce);
        assertTrue(gateway.nonceToClientTxId(stakeMsg.clientChainId, stakeMsg.nonce) == stakeMsg.clientTxId);
    }

    function test_SubmitProofForStakeMsg_RevertConsensusDeactivated() public {
        _addAllWitnesses();

        // deactivate consensus for stake message by updating the value of requiredProofs
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // First witness submits proof
        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Errors.ConsensusNotRequired.selector));
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature);
    }

    function test_SubmitProofForStakeMsg_RevertInvalidSignature() public {
        _addAllWitnesses();
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        bytes memory invalidSignature = bytes("invalid");

        vm.prank(relayer);
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, invalidSignature);
    }

    function test_SubmitProofForStakeMsg_RevertUnauthorizedWitness() public {
        _addAllWitnesses();
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        Player memory unauthorizedWitness = Player({privateKey: 99, addr: vm.addr(99)});
        bytes memory signature = _generateSignature(stakeMsg, unauthorizedWitness.privateKey);

        vm.prank(unauthorizedWitness.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.WitnessNotAuthorized.selector, unauthorizedWitness.addr));
        gateway.submitProofForStakeMsg(unauthorizedWitness.addr, stakeMsg, signature);
    }

    function test_SubmitProofForStakeMsg_ExpiredBeforeConsensus() public {
        _addAllWitnesses();
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // Submit proofs from requiredProofs - 1 witnesses
        for (uint256 i = 0; i < gateway.requiredProofs() - 1; i++) {
            bytes memory signature = _generateSignature(stakeMsg, witnesses[i].privateKey);
            vm.prank(relayer);
            gateway.submitProofForStakeMsg(witnesses[i].addr, stakeMsg, signature);
        }

        // Move time forward past expiry
        vm.warp(block.timestamp + PROOF_TIMEOUT + 1);

        // Submit the last proof
        bytes memory lastSignature = _generateSignature(stakeMsg, witnesses[gateway.requiredProofs() - 1].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[gateway.requiredProofs() - 1].addr, stakeMsg, lastSignature);

        // Verify transaction is restarted owing to expired and not processed
        bytes32 messageHash = _getMessageHash(stakeMsg);
        assertEq(uint8(gateway.getTransactionStatus(messageHash)), uint8(UTXOGatewayStorage.TxStatus.PENDING));
        assertEq(gateway.getTransactionProofCount(messageHash), 1);
        assertEq(gateway.clientTxIdToNonce(stakeMsg.clientChainId, stakeMsg.clientTxId), 0);
    }

    function test_SubmitProofForStakeMsg_RestartExpiredTransaction() public {
        _addAllWitnesses();
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // First witness submits proof
        bytes memory signature0 = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature0);

        // Move time forward past expiry
        vm.warp(block.timestamp + PROOF_TIMEOUT + 1);

        // Same witness submits proof again to restart transaction
        bytes memory signature0Restart = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature0Restart);

        bytes32 messageHash = _getMessageHash(stakeMsg);

        // Verify transaction is restarted
        assertEq(uint8(gateway.getTransactionStatus(messageHash)), uint8(UTXOGatewayStorage.TxStatus.PENDING));
        assertEq(gateway.getTransactionProofCount(messageHash), 1);
        assertTrue(gateway.getTransactionWitnessTime(messageHash, witnesses[0].addr) > 0);
        assertEq(gateway.clientTxIdToNonce(stakeMsg.clientChainId, stakeMsg.clientTxId), 0);
    }

    function test_SubmitProofForStakeMsg_JoinRestartedTransaction() public {
        _addAllWitnesses();
        _activateConsensus();
        // afater activating consensus, required proofs should be set as 3
        assertEq(gateway.requiredProofs(), 3);

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // First witness submits proof
        bytes memory signature0 = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature0);

        // Move time forward past expiry
        vm.warp(block.timestamp + PROOF_TIMEOUT + 1);

        // Second witness restarts transaction
        bytes memory signature1 = _generateSignature(stakeMsg, witnesses[1].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[1].addr, stakeMsg, signature1);

        // First witness can submit proof again in new round
        // as requiredProofs is 3, the transaction should not be processed even if the first witness submits proof
        bytes memory signature0New = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature0New);

        bytes32 messageHash = _getMessageHash(stakeMsg);

        // Verify both witnesses' proofs are counted
        assertEq(uint8(gateway.getTransactionStatus(messageHash)), uint8(UTXOGatewayStorage.TxStatus.PENDING));
        assertEq(gateway.getTransactionProofCount(messageHash), 2);
        assertEq(gateway.clientTxIdToNonce(stakeMsg.clientChainId, stakeMsg.clientTxId), 0);
        assertTrue(gateway.getTransactionWitnessTime(messageHash, witnesses[0].addr) > 0);
        assertTrue(gateway.getTransactionWitnessTime(messageHash, witnesses[1].addr) > 0);
    }

    function test_SubmitProofForStakeMsg_RevertDuplicateProofInSameRound() public {
        _addAllWitnesses();
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // First submission
        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signature);

        // Try to submit again in same round
        bytes memory signatureSecond = _generateSignature(stakeMsg, witnesses[0].privateKey);
        vm.prank(relayer);
        vm.expectRevert(Errors.WitnessAlreadySubmittedProof.selector);
        gateway.submitProofForStakeMsg(witnesses[0].addr, stakeMsg, signatureSecond);
    }

    function test_ProcessStakeMessage_RevertConsensusActivated() public {
        _activateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(Errors.ConsensusRequired.selector);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RegisterNewAddress() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: "",
            amount: 1 ether
        });

        // mock Assets precompile deposit success and Delegation precompile delegate success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, stakeMsg.amount)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit AddressRegistered(UTXOGatewayStorage.ClientChainID.BITCOIN, btcAddress, user);
        vm.expectEmit(true, true, true, true);
        emit StakeMsgExecuted(UTXOGatewayStorage.ClientChainID.BITCOIN, stakeMsg.nonce, user, stakeMsg.amount);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);

        // Verify address registration
        assertEq(gateway.getClientAddress(UTXOGatewayStorage.ClientChainID.BITCOIN, user), btcAddress);
        assertEq(gateway.getImuachainAddress(UTXOGatewayStorage.ClientChainID.BITCOIN, btcAddress), user);
    }

    function test_ProcessStakeMessage_WithBridgeFee() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // first owner updates bridge fee
        vm.prank(owner);
        gateway.updateBridgeFeeRate(100);

        // then relayer submits proof and we should see the bridge fee deducted from the amount
        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);
        uint256 amountAfterFee = 1 ether - 1 ether * 100 / 10_000;

        // mock Assets precompile deposit success and Delegation precompile delegate success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, amountAfterFee)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        vm.expectEmit(true, true, true, true, address(gateway));
        emit DepositCompleted(
            UTXOGatewayStorage.ClientChainID.BITCOIN,
            stakeMsg.clientTxId,
            user,
            stakeMsg.clientAddress,
            amountAfterFee,
            amountAfterFee
        );

        vm.expectEmit(true, true, true, true, address(gateway));
        emit DelegationCompleted(UTXOGatewayStorage.ClientChainID.BITCOIN, user, operator, amountAfterFee);

        vm.prank(relayer);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_WithDelegation() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // mock Assets precompile deposit success and Delegation precompile delegate success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, stakeMsg.amount)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit DelegationCompleted(UTXOGatewayStorage.ClientChainID.BITCOIN, user, operator, 1 ether);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_DelegationFailureNotRevert() public {
        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: operator,
            amount: 1 ether
        });

        // mock Assets precompile deposit success and Delegation precompile delegate failure
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, stakeMsg.amount)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(false)
        );

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        // deposit should be successful
        vm.expectEmit(true, true, true, true);
        emit DepositCompleted(
            UTXOGatewayStorage.ClientChainID.BITCOIN,
            stakeMsg.clientTxId,
            user,
            stakeMsg.clientAddress,
            1 ether,
            stakeMsg.amount
        );

        // delegation should fail
        vm.expectEmit(true, true, true, true);
        emit DelegationFailedForStake(UTXOGatewayStorage.ClientChainID.BITCOIN, user, operator, 1 ether);

        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertOnDepositFailure() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: "",
            amount: 1 ether
        });

        // mock Assets precompile deposit failure
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IAssets.depositLST.selector), abi.encode(false, 0)
        );

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFailed.selector, bytes32(uint256(123))));
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertWhenPaused() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: "",
            amount: 1 ether
        });

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(owner);
        gateway.pause();

        vm.prank(relayer);
        vm.expectRevert("Pausable: paused");
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertUnauthorizedWitness() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: "",
            amount: 1 ether
        });

        Player memory unauthorizedWitness = Player({addr: vm.addr(0x999), privateKey: 0x999});
        bytes memory signature = _generateSignature(stakeMsg, unauthorizedWitness.privateKey);

        vm.prank(unauthorizedWitness.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.WitnessNotAuthorized.selector, unauthorizedWitness.addr));
        gateway.processStakeMessage(unauthorizedWitness.addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertInvalidStakeMessage() public {
        _deactivateConsensus();

        // Create invalid message with all zero values
        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.NONE,
            nonce: 0,
            clientTxId: bytes32(uint256(123)),
            clientAddress: bytes(""),
            imuachainAddress: address(0),
            operator: "",
            amount: 0
        });

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidStakeMessage.selector);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertZeroImuachainAddressBeforeRegistration() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: address(0), // Zero address
            operator: "",
            amount: 1 ether
        });

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_ProcessStakeMessage_RevertInvalidNonce() public {
        _deactivateConsensus();

        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: gateway.nextInboundNonce(UTXOGatewayStorage.ClientChainID.BITCOIN) + 1,
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddress,
            imuachainAddress: user,
            operator: "",
            amount: 1 ether
        });

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.UnexpectedInboundNonce.selector, gateway.nextInboundNonce(stakeMsg.clientChainId), stakeMsg.nonce
            )
        );
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);
    }

    function test_DelegateTo_Success() public {
        // Setup: Register user's client chain address first
        _mockRegisterAddress(user, btcAddress);

        // mock delegation precompile delegate success
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit DelegationCompleted(UTXOGatewayStorage.ClientChainID.BITCOIN, user, operator, 1 ether);

        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, operator, 1 ether);

        // Verify nonce increment
        assertEq(gateway.delegationNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 1);
    }

    function test_DelegateTo_RevertZeroAmount() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, operator, 0);
    }

    function test_DelegateTo_RevertWhenPaused() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_DelegateTo_RevertNotRegistered() public {
        // Don't register user's address

        vm.prank(user);
        vm.expectRevert(Errors.AddressNotRegistered.selector);
        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_DelegateTo_RevertInvalidOperator() public {
        _mockRegisterAddress(user, btcAddress);

        string memory invalidOperator = "not-a-bech32-address";

        vm.prank(user);
        vm.expectRevert(Errors.InvalidOperator.selector);
        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, invalidOperator, 1 ether);
    }

    function test_DelegateTo_RevertDelegationFailed() public {
        _mockRegisterAddress(user, btcAddress);

        // Mock delegation failure
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(false)
        );

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.DelegationFailed.selector));
        gateway.delegateTo(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_UndelegateFrom_Success() public {
        // Setup: Register user's client chain address first
        _mockRegisterAddress(user, btcAddress);

        // mock delegation precompile undelegate success
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.undelegate.selector), abi.encode(true)
        );

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit UndelegationCompleted(UTXOGatewayStorage.ClientChainID.BITCOIN, user, operator, 1 ether);

        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, operator, 1 ether);

        // Verify nonce increment
        assertEq(gateway.delegationNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 1);
    }

    function test_UndelegateFrom_RevertZeroAmount() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, operator, 0);
    }

    function test_UndelegateFrom_RevertWhenPaused() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_UndelegateFrom_RevertNotRegistered() public {
        // Don't register user's address

        vm.prank(user);
        vm.expectRevert(Errors.AddressNotRegistered.selector);
        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_UndelegateFrom_RevertInvalidOperator() public {
        _mockRegisterAddress(user, btcAddress);

        string memory invalidOperator = "not-a-bech32-address";

        vm.prank(user);
        vm.expectRevert(Errors.InvalidOperator.selector);
        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, invalidOperator, 1 ether);
    }

    function test_UndelegateFrom_RevertUndelegationFailed() public {
        _mockRegisterAddress(user, btcAddress);

        // mock delegation precompile undelegate failure
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.undelegate.selector), abi.encode(false)
        );

        vm.prank(user);
        vm.expectRevert(Errors.UndelegationFailed.selector);
        gateway.undelegateFrom(UTXOGatewayStorage.Token.BTC, operator, 1 ether);
    }

    function test_WithdrawPrincipal_Success() public {
        // Setup: Register user's client chain address first
        _mockRegisterAddress(user, btcAddress);

        // mock assets precompile withdrawLST success and return updated balance
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IAssets.withdrawLST.selector), abi.encode(true, 2 ether)
        );

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit WithdrawPrincipalRequested(
            UTXOGatewayStorage.ClientChainID.BITCOIN,
            1, // first request ID
            user,
            btcAddress,
            1 ether,
            2 ether
        );

        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);

        // Verify pegOutNonce increment
        assertEq(gateway.pegOutNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 1);
    }

    function test_WithdrawPrincipal_RevertWhenPaused() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawPrincipal_RevertZeroAmount() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 0);
    }

    function test_WithdrawPrincipal_RevertWithdrawFailed() public {
        _mockRegisterAddress(user, btcAddress);

        // mock assets precompile withdrawLST failure
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IAssets.withdrawLST.selector), abi.encode(false, 0)
        );

        vm.prank(user);
        vm.expectRevert(Errors.WithdrawPrincipalFailed.selector);
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawPrincipal_RevertNotRegistered() public {
        // Don't register user's address

        vm.prank(user);
        vm.expectRevert(Errors.AddressNotRegistered.selector);
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawPrincipal_VerifyPegOutRequest() public {
        _mockRegisterAddress(user, btcAddress);

        // mock Assets precompile withdrawLST success and return updated balance
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IAssets.withdrawLST.selector), abi.encode(true, 2 ether)
        );

        vm.prank(user);
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);

        // Verify peg-out request details
        UTXOGatewayStorage.PegOutRequest memory request =
            gateway.getPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN, 1);
        assertEq(uint8(request.clientChainId), uint8(UTXOGatewayStorage.ClientChainID.BITCOIN));
        assertEq(request.nonce, 1);
        assertEq(request.requester, user);
        assertEq(request.clientAddress, btcAddress);
        assertEq(request.amount, 1 ether);
        assertEq(uint8(request.withdrawType), uint8(UTXOGatewayStorage.WithdrawType.WITHDRAW_PRINCIPAL));
    }

    function test_WithdrawReward_Success() public {
        // Setup: Register user's client chain address first
        _mockRegisterAddress(user, btcAddress);

        // mock Reward precompile claimReward success and return updated balance
        vm.mockCall(
            REWARD_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IReward.claimReward.selector), abi.encode(true, 2 ether)
        );

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit WithdrawRewardRequested(
            UTXOGatewayStorage.ClientChainID.BITCOIN,
            1, // first request ID
            user,
            btcAddress,
            1 ether,
            2 ether
        );

        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);

        // Verify pegOutNonce increment
        assertEq(gateway.pegOutNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 1);
    }

    function test_WithdrawReward_RevertWhenPaused() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawReward_RevertZeroAmount() public {
        _mockRegisterAddress(user, btcAddress);

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 0);
    }

    function test_WithdrawReward_RevertClaimFailed() public {
        _mockRegisterAddress(user, btcAddress);

        // mock claimReward failure
        vm.mockCall(
            REWARD_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IReward.claimReward.selector), abi.encode(false, 0)
        );

        vm.prank(user);
        vm.expectRevert(Errors.WithdrawRewardFailed.selector);
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawReward_RevertAddressNotRegistered() public {
        // Don't register user's address - try to withdraw without registration

        vm.prank(user);
        vm.expectRevert(Errors.AddressNotRegistered.selector);
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);
    }

    function test_WithdrawReward_VerifyPegOutRequest() public {
        _mockRegisterAddress(user, btcAddress);

        // mock Reward precompile claimReward success and return updated balance
        vm.mockCall(
            REWARD_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IReward.claimReward.selector), abi.encode(true, 2 ether)
        );

        vm.prank(user);
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);

        // Verify peg-out request details
        UTXOGatewayStorage.PegOutRequest memory request =
            gateway.getPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN, 1);
        assertEq(uint8(request.clientChainId), uint8(UTXOGatewayStorage.ClientChainID.BITCOIN));
        assertEq(request.nonce, 1);
        assertEq(request.requester, user);
        assertEq(request.clientAddress, btcAddress);
        assertEq(request.amount, 1 ether);
        assertEq(uint8(request.withdrawType), uint8(UTXOGatewayStorage.WithdrawType.WITHDRAW_REWARD));
    }

    function test_WithdrawReward_MultipleRequests() public {
        _mockRegisterAddress(user, btcAddress);

        // Mock successful claimReward
        bytes memory claimCall1 = abi.encodeWithSelector(
            IReward.claimReward.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            user.toImuachainBytes(),
            1 ether
        );
        vm.mockCall(REWARD_PRECOMPILE_ADDRESS, claimCall1, abi.encode(true, 2 ether));

        bytes memory claimCall2 = abi.encodeWithSelector(
            IReward.claimReward.selector,
            uint32(uint8(UTXOGatewayStorage.ClientChainID.BITCOIN)),
            VIRTUAL_TOKEN,
            user.toImuachainBytes(),
            0.5 ether
        );
        vm.mockCall(REWARD_PRECOMPILE_ADDRESS, claimCall2, abi.encode(true, 1.5 ether));

        vm.startPrank(user);

        // First withdrawal
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 1 ether);

        // Second withdrawal
        gateway.withdrawReward(UTXOGatewayStorage.Token.BTC, 0.5 ether);

        vm.stopPrank();

        // Verify both requests exist with correct details
        UTXOGatewayStorage.PegOutRequest memory request1 =
            gateway.getPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN, 1);
        assertEq(request1.amount, 1 ether);

        UTXOGatewayStorage.PegOutRequest memory request2 =
            gateway.getPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN, 2);
        assertEq(request2.amount, 0.5 ether);

        // Verify nonce increment
        assertEq(gateway.pegOutNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 2);
    }

    function test_ProcessNextPegOutRequest_Success() public {
        // Setup: Create a peg-out request first
        _setupPegOutRequest();

        // Now consume the peg-out request
        vm.prank(witnesses[0].addr);
        vm.expectEmit(true, true, true, true);
        emit PegOutRequestProcessing(
            uint8(UTXOGatewayStorage.WithdrawType.WITHDRAW_PRINCIPAL),
            UTXOGatewayStorage.ClientChainID.BITCOIN,
            1, // requestId
            user,
            btcAddress,
            1 ether
        );

        UTXOGatewayStorage.PegOutRequest memory request =
            gateway.processNextPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN);

        // Verify returned request contents
        assertEq(uint8(request.clientChainId), uint8(UTXOGatewayStorage.ClientChainID.BITCOIN));
        assertEq(request.nonce, 1);
        assertEq(request.requester, user);
        assertEq(request.clientAddress, btcAddress);
        assertEq(request.amount, 1 ether);
        assertEq(uint8(request.withdrawType), uint8(UTXOGatewayStorage.WithdrawType.WITHDRAW_PRINCIPAL));

        // Verify outbound nonce increment
        assertEq(gateway.outboundNonce(UTXOGatewayStorage.ClientChainID.BITCOIN), 1);
    }

    function test_ProcessNextPegOutRequest_RevertUnauthorizedWitness() public {
        // Setup a peg-out request
        _setupPegOutRequest();

        address unauthorizedWitness = address(0x9999);
        vm.prank(unauthorizedWitness);
        vm.expectRevert(Errors.UnauthorizedWitness.selector);
        gateway.processNextPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN);
    }

    function test_ProcessNextPegOutRequest_RevertWhenPaused() public {
        // Setup a peg-out request
        _setupPegOutRequest();

        vm.prank(owner);
        gateway.pause();

        vm.prank(witnesses[0].addr);
        vm.expectRevert("Pausable: paused");
        gateway.processNextPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN);
    }

    function test_ProcessNextPegOutRequest_RevertRequestNotFound() public {
        // Don't create any peg-out request
        vm.prank(witnesses[0].addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.RequestNotFound.selector, 1));
        gateway.processNextPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN);
    }

    // Helper function to setup a peg-out request
    function _setupPegOutRequest() internal {
        if (gateway.getClientAddress(UTXOGatewayStorage.ClientChainID.BITCOIN, user).length == 0) {
            _mockRegisterAddress(user, btcAddress);
        }

        // mock withdrawLST success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IAssets.withdrawLST.selector), abi.encode(true, 2 ether)
        );

        vm.prank(user);
        gateway.withdrawPrincipal(UTXOGatewayStorage.Token.BTC, 1 ether);
        assertEq(gateway.getPegOutRequest(UTXOGatewayStorage.ClientChainID.BITCOIN, 1).amount, 1 ether);
    }

    // Helper functions
    function _mockRegisterAddress(address imuachainAddr, bytes memory btcAddr) internal {
        UTXOGatewayStorage.StakeMsg memory stakeMsg = UTXOGatewayStorage.StakeMsg({
            clientChainId: UTXOGatewayStorage.ClientChainID.BITCOIN,
            nonce: gateway.nextInboundNonce(UTXOGatewayStorage.ClientChainID.BITCOIN),
            clientTxId: bytes32(uint256(123)),
            clientAddress: btcAddr,
            imuachainAddress: imuachainAddr,
            operator: "",
            amount: 1 ether
        });

        // mock Assets precompile deposit success and Delegation precompile delegate success
        vm.mockCall(
            ASSETS_PRECOMPILE_ADDRESS,
            abi.encodeWithSelector(IAssets.depositLST.selector),
            abi.encode(true, stakeMsg.amount)
        );
        vm.mockCall(
            DELEGATION_PRECOMPILE_ADDRESS, abi.encodeWithSelector(IDelegation.delegate.selector), abi.encode(true)
        );

        bytes memory signature = _generateSignature(stakeMsg, witnesses[0].privateKey);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit AddressRegistered(UTXOGatewayStorage.ClientChainID.BITCOIN, btcAddr, imuachainAddr);

        vm.prank(relayer);
        gateway.processStakeMessage(witnesses[0].addr, stakeMsg, signature);

        // Verify address registration
        assertEq(gateway.getClientAddress(UTXOGatewayStorage.ClientChainID.BITCOIN, imuachainAddr), btcAddr);
        assertEq(gateway.getImuachainAddress(UTXOGatewayStorage.ClientChainID.BITCOIN, btcAddr), imuachainAddr);
    }

    function _addAllWitnesses() internal {
        address[] memory witnessesToAdd = new address[](1);
        for (uint256 i = 0; i < witnesses.length; i++) {
            if (!gateway.authorizedWitnesses(witnesses[i].addr)) {
                witnessesToAdd[0] = witnesses[i].addr;
                vm.prank(owner);
                gateway.addWitnesses(witnessesToAdd);
            }
        }
    }

    function _getMessageHash(UTXOGatewayStorage.StakeMsg memory msg_) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                msg_.clientChainId, // ClientChainID
                msg_.nonce, // uint64
                msg_.clientTxId, // bytes32
                msg_.clientAddress, // bytes - Bitcoin address
                msg_.imuachainAddress, // address
                msg_.operator, // string
                msg_.amount // uint256
            )
        );
    }

    function _generateSignature(UTXOGatewayStorage.StakeMsg memory msg_, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        // Encode all fields of StakeMsg in order
        bytes32 messageHash = _getMessageHash(msg_);

        // Sign the encoded message hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, messageHash.toEthSignedMessageHash());

        // Return the signature in the format expected by the contract
        return abi.encodePacked(r, s, v);
    }

    function _activateConsensus() internal {
        vm.startPrank(owner);
        gateway.updateRequiredProofs(gateway.authorizedWitnessCount());
        vm.stopPrank();
    }

    function _deactivateConsensus() internal {
        vm.startPrank(owner);
        gateway.updateRequiredProofs(gateway.authorizedWitnessCount() + 1);
        vm.stopPrank();
    }

}
