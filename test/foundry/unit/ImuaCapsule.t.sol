pragma solidity ^0.8.19;

import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Test.sol";

import "src/core/ImuaCapsule.sol";
import "src/interfaces/IImuaCapsule.sol";

import "src/libraries/BeaconChainProofs.sol";
import "src/libraries/Endian.sol";

import {Errors} from "src/libraries/Errors.sol";
import {ImuaCapsuleStorage} from "src/storage/ImuaCapsuleStorage.sol";

contract DepositSetup is Test {

    using stdStorage for StdStorage;
    using Endian for bytes32;

    bytes32[] validatorContainer;
    /**
     * struct ValidatorContainerProof {
     *         uint256 beaconBlockTimestamp;
     *         bytes32 stateRoot;
     *         bytes32[] stateRootProof;
     *         bytes32[] validatorContainerRootProof;
     *         uint256 validatorContainerRootIndex;
     *     }
     */
    BeaconChainProofs.ValidatorContainerProof validatorProof;
    bytes32 beaconBlockRoot;

    ImuaCapsule capsule;
    IBeaconChainOracle beaconOracle;
    address payable capsuleOwner;

    uint256 constant BEACON_CHAIN_GENESIS_TIME = 1_606_824_023;
    /// @notice The number of slots each epoch in the beacon chain
    uint64 internal constant SLOTS_PER_EPOCH = 32;
    /// @notice The number of seconds in a slot in the beacon chain
    uint64 internal constant SECONDS_PER_SLOT = 12;
    /// @notice Number of seconds per epoch: 384 == 32 slots/epoch * 12 seconds/slot
    uint64 internal constant SECONDS_PER_EPOCH = SLOTS_PER_EPOCH * SECONDS_PER_SLOT;
    uint256 internal constant VERIFY_BALANCE_UPDATE_WINDOW_SECONDS = 4.5 hours;

    uint256 mockProofTimestamp;
    uint256 mockCurrentBlockTimestamp;

    function setUp() public {
        vm.chainId(1); // set chainid to 1 so that capsule implementation can use default network constants
        string memory validatorInfo = vm.readFile("test/foundry/test-data/validator_container_proof_8955769.json");

        validatorContainer = stdJson.readBytes32Array(validatorInfo, ".ValidatorFields");
        require(validatorContainer.length > 0, "validator container should not be empty");

        validatorProof.stateRoot = stdJson.readBytes32(validatorInfo, ".beaconStateRoot");
        require(validatorProof.stateRoot != bytes32(0), "state root should not be empty");
        validatorProof.stateRootProof =
            stdJson.readBytes32Array(validatorInfo, ".StateRootAgainstLatestBlockHeaderProof");
        require(validatorProof.stateRootProof.length == 3, "state root proof should have 3 nodes");
        validatorProof.validatorContainerRootProof =
            stdJson.readBytes32Array(validatorInfo, ".WithdrawalCredentialProof");
        require(validatorProof.validatorContainerRootProof.length == 46, "validator root proof should have 46 nodes");
        validatorProof.validatorIndex = stdJson.readUint(validatorInfo, ".validatorIndex");
        require(validatorProof.validatorIndex != 0, "validator root index should not be 0");

        beaconBlockRoot = stdJson.readBytes32(validatorInfo, ".latestBlockHeaderRoot");
        require(beaconBlockRoot != bytes32(0), "beacon block root should not be empty");

        beaconOracle = IBeaconChainOracle(address(0x123));
        vm.etch(address(beaconOracle), bytes("aabb"));

        capsuleOwner = payable(address(0x125));

        ImuaCapsule phantomCapsule = new ImuaCapsule(address(0));

        address capsuleAddress = _getCapsuleFromWithdrawalCredentials(_getWithdrawalCredentials(validatorContainer));
        vm.etch(capsuleAddress, address(phantomCapsule).code);
        capsule = ImuaCapsule(payable(capsuleAddress));

        capsule.initialize(address(this), capsuleOwner, address(beaconOracle));
    }

    function _getCapsuleFromWithdrawalCredentials(bytes32 withdrawalCredentials) internal pure returns (address) {
        return address(bytes20(uint160(uint256(withdrawalCredentials))));
    }

    function _getPubkey(bytes32[] storage vc) internal view returns (bytes32) {
        return vc[0];
    }

    function _getWithdrawalCredentials(bytes32[] storage vc) internal view returns (bytes32) {
        return vc[1];
    }

    function _getEffectiveBalance(bytes32[] storage vc) internal view returns (uint64) {
        return vc[2].fromLittleEndianUint64();
    }

    function _getActivationEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[5].fromLittleEndianUint64();
    }

    function _getExitEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[6].fromLittleEndianUint64();
    }

}

contract Initialize is DepositSetup {

    using stdStorage for StdStorage;

    function test_success_CapsuleInitialized() public {
        // Assert that the gateway is set correctly
        assertEq(address(capsule.gateway()), address(this));

        // Assert that the capsule owner is set correctly
        assertEq(capsule.capsuleOwner(), capsuleOwner);

        // Assert that the beacon oracle is set correctly
        assertEq(address(capsule.beaconOracle()), address(beaconOracle));

        // Assert that the reentrancy guard is not entered
        uint256 NOT_ENTERED = 1;
        bytes32 reentrancyStatusSlot = bytes32(uint256(1));
        uint256 status = uint256(vm.load(address(capsule), reentrancyStatusSlot));

        assertEq(status, NOT_ENTERED);

        // Assert that the capsule withdrawal credentials are set correctly
        assertEq(bytes32(capsule.capsuleWithdrawalCredentials()), _getWithdrawalCredentials(validatorContainer));
    }

}

contract VerifyDepositProof is DepositSetup {

    using BeaconChainProofs for bytes32;
    using stdStorage for StdStorage;

    function test_verifyDepositProof_success() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        capsule.verifyDepositProof(validatorContainer, validatorProof);

        ImuaCapsuleStorage.Validator memory validator =
            capsule.getRegisteredValidatorByPubkey(_getPubkey(validatorContainer));
        assertEq(uint8(validator.status), uint8(ImuaCapsuleStorage.VALIDATOR_STATUS.REGISTERED));
        assertEq(validator.validatorIndex, validatorProof.validatorIndex);
    }

    function test_verifyDepositProof_revert_validatorAlreadyDeposited() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        capsule.verifyDepositProof(validatorContainer, validatorProof);

        // deposit again should revert
        vm.expectRevert(
            abi.encodeWithSelector(ImuaCapsule.DoubleDepositedValidator.selector, _getPubkey(validatorContainer))
        );
        capsule.verifyDepositProof(validatorContainer, validatorProof);
    }

    function test_verifyDepositProof_revert_staleProof() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp + 1 hours;
        mockCurrentBlockTimestamp = mockProofTimestamp + VERIFY_BALANCE_UPDATE_WINDOW_SECONDS + 1 seconds;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        // deposit should revert because of proof is stale
        vm.expectRevert(
            abi.encodeWithSelector(
                ImuaCapsule.StaleValidatorContainer.selector, _getPubkey(validatorContainer), mockProofTimestamp
            )
        );
        capsule.verifyDepositProof(validatorContainer, validatorProof);
    }

    function test_verifyDepositProof_revert_malformedValidatorContainer() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        uint256 snapshot = vm.snapshotState();

        // construct malformed validator container that has extra fields
        validatorContainer.push(bytes32(uint256(123)));
        vm.expectRevert(
            abi.encodeWithSelector(ImuaCapsule.InvalidValidatorContainer.selector, _getPubkey(validatorContainer))
        );
        capsule.verifyDepositProof(validatorContainer, validatorProof);

        vm.revertToState(snapshot);
        // construct malformed validator container that misses fields
        validatorContainer.pop();
        vm.expectRevert(
            abi.encodeWithSelector(ImuaCapsule.InvalidValidatorContainer.selector, _getPubkey(validatorContainer))
        );
        capsule.verifyDepositProof(validatorContainer, validatorProof);
    }

    function test_verifyDepositProof_success_inactiveValidatorContainer() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        // set proof timestamp before activation epoch
        mockProofTimestamp = activationTimestamp - 1 seconds;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        capsule.verifyDepositProof(validatorContainer, validatorProof);

        ImuaCapsuleStorage.Validator memory validator =
            capsule.getRegisteredValidatorByPubkey(_getPubkey(validatorContainer));
        assertEq(uint8(validator.status), uint8(ImuaCapsuleStorage.VALIDATOR_STATUS.REGISTERED));
        assertEq(validator.validatorIndex, validatorProof.validatorIndex);
    }

    function test_verifyDepositProof_revert_mismatchWithdrawalCredentials() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        // validator container withdrawal credentials are pointed to another capsule
        ImuaCapsule anotherCapsule = new ImuaCapsule(address(0));

        bytes32 gatewaySlot = bytes32(stdstore.target(address(anotherCapsule)).sig("gateway()").find());
        vm.store(address(anotherCapsule), gatewaySlot, bytes32(uint256(uint160(address(this)))));

        bytes32 ownerSlot = bytes32(stdstore.target(address(anotherCapsule)).sig("capsuleOwner()").find());
        vm.store(address(anotherCapsule), ownerSlot, bytes32(uint256(uint160(address(capsuleOwner)))));

        bytes32 beaconOraclerSlot = bytes32(stdstore.target(address(anotherCapsule)).sig("beaconOracle()").find());
        vm.store(address(anotherCapsule), beaconOraclerSlot, bytes32(uint256(uint160(address(beaconOracle)))));

        vm.expectRevert(abi.encodeWithSelector(ImuaCapsule.WithdrawalCredentialsNotMatch.selector));
        anotherCapsule.verifyDepositProof(validatorContainer, validatorProof);
    }

    function test_verifyDepositProof_revert_proofNotMatchWithBeaconRoot() public {
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        bytes32 mismatchBeaconBlockRoot = bytes32(uint256(123));
        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(mismatchBeaconBlockRoot)
        );

        // verify proof against mismatch beacon block root
        vm.expectRevert(
            abi.encodeWithSelector(ImuaCapsule.InvalidValidatorContainer.selector, _getPubkey(validatorContainer))
        );
        capsule.verifyDepositProof(validatorContainer, validatorProof);
    }

}

contract WithdrawalSetup is Test {

    using stdStorage for StdStorage;
    using Endian for bytes32;

    bytes32[] validatorContainer;
    /**
     * struct ValidatorContainerProof {
     *     uint256 beaconBlockTimestamp;
     *     bytes32 stateRoot;
     *     bytes32[] stateRootProof;
     *     bytes32[] validatorContainerRootProof;
     *     uint256 validatorIndex;
     * }
     */
    BeaconChainProofs.ValidatorContainerProof validatorProof;

    bytes32[] withdrawalContainer;
    bytes32 beaconBlockRoot; // latest beacon block root

    ImuaCapsule capsule;
    IBeaconChainOracle beaconOracle;
    address capsuleOwner;

    uint256 constant BEACON_CHAIN_GENESIS_TIME = 1_606_824_023;
    /// @notice The number of slots each epoch in the beacon chain
    uint64 internal constant SLOTS_PER_EPOCH = 32;
    /// @notice The number of seconds in a slot in the beacon chain
    uint64 internal constant SECONDS_PER_SLOT = 12;
    /// @notice Number of seconds per epoch: 384 == 32 slots/epoch * 12 seconds/slot
    uint64 internal constant SECONDS_PER_EPOCH = SLOTS_PER_EPOCH * SECONDS_PER_SLOT;
    uint256 internal constant VERIFY_BALANCE_UPDATE_WINDOW_SECONDS = 4.5 hours;

    uint256 mockProofTimestamp;
    uint256 mockCurrentBlockTimestamp;
    uint256 activationTimestamp;
    uint256 depositAmount;

    function setUp() public {
        vm.chainId(1); // set chainid to 1 so that capsule implementation can use default network constants
        string memory validatorInfo = vm.readFile("test/foundry/test-data/validator_container_proof_302913.json");
        _setValidatorContainer(validatorInfo);

        beaconOracle = IBeaconChainOracle(address(0x123));
        vm.etch(address(beaconOracle), bytes("aabb"));

        capsuleOwner = address(0x125);

        ImuaCapsule phantomCapsule = new ImuaCapsule(address(0));

        address capsuleAddress = _getCapsuleFromWithdrawalCredentials(_getWithdrawalCredentials(validatorContainer));
        vm.etch(capsuleAddress, address(phantomCapsule).code);
        capsule = ImuaCapsule(payable(capsuleAddress));
        assertEq(bytes32(capsule.capsuleWithdrawalCredentials()), _getWithdrawalCredentials(validatorContainer));

        stdstore.target(capsuleAddress).sig("gateway()").checked_write(bytes32(uint256(uint160(address(this)))));

        stdstore.target(capsuleAddress).sig("capsuleOwner()").checked_write(bytes32(uint256(uint160(capsuleOwner))));

        stdstore.target(capsuleAddress).sig("beaconOracle()").checked_write(
            bytes32(uint256(uint160(address(beaconOracle))))
        );

        activationTimestamp = BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;

        vm.warp(mockCurrentBlockTimestamp);
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector, mockProofTimestamp),
            abi.encode(beaconBlockRoot)
        );

        depositAmount = capsule.verifyDepositProof(validatorContainer, validatorProof);

        ImuaCapsuleStorage.Validator memory validator =
            capsule.getRegisteredValidatorByPubkey(_getPubkey(validatorContainer));
        assertEq(uint8(validator.status), uint8(ImuaCapsuleStorage.VALIDATOR_STATUS.REGISTERED));
        assertEq(validator.validatorIndex, validatorProof.validatorIndex);
    }

    function _setValidatorContainer(string memory validatorInfo) internal {
        validatorContainer = stdJson.readBytes32Array(validatorInfo, ".ValidatorFields");
        require(validatorContainer.length > 0, "validator container should not be empty");

        validatorProof.stateRoot = stdJson.readBytes32(validatorInfo, ".beaconStateRoot");
        require(validatorProof.stateRoot != bytes32(0), "state root should not be empty");
        validatorProof.stateRootProof =
            stdJson.readBytes32Array(validatorInfo, ".StateRootAgainstLatestBlockHeaderProof");
        require(validatorProof.stateRootProof.length == 3, "state root proof should have 3 nodes");
        validatorProof.validatorContainerRootProof =
            stdJson.readBytes32Array(validatorInfo, ".WithdrawalCredentialProof");
        require(validatorProof.validatorContainerRootProof.length == 46, "validator root proof should have 46 nodes");
        validatorProof.validatorIndex = stdJson.readUint(validatorInfo, ".validatorIndex");
        require(validatorProof.validatorIndex != 0, "validator root index should not be 0");

        beaconBlockRoot = stdJson.readBytes32(validatorInfo, ".latestBlockHeaderRoot");
        require(beaconBlockRoot != bytes32(0), "beacon block root should not be empty");
    }

    function _setTimeStamp() internal {
        validatorProof.beaconBlockTimestamp = activationTimestamp + SECONDS_PER_SLOT;
        mockCurrentBlockTimestamp = validatorProof.beaconBlockTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);
        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector, validatorProof.beaconBlockTimestamp),
            abi.encode(beaconBlockRoot)
        );
    }

    function _getCapsuleFromWithdrawalCredentials(bytes32 withdrawalCredentials) internal pure returns (address) {
        return address(bytes20(uint160(uint256(withdrawalCredentials))));
    }

    function _getPubkey(bytes32[] storage vc) internal view returns (bytes32) {
        return vc[0];
    }

    function _getWithdrawalCredentials(bytes32[] storage vc) internal view returns (bytes32) {
        return vc[1];
    }

    function _getEffectiveBalance(bytes32[] storage vc) internal view returns (uint64) {
        return vc[2].fromLittleEndianUint64();
    }

    function _getActivationEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[5].fromLittleEndianUint64();
    }

    function _getExitEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[6].fromLittleEndianUint64();
    }

    function _getWithdrawalIndex(bytes32[] storage wc) internal view returns (uint64) {
        return wc[0].fromLittleEndianUint64();
    }

}

contract VerifyWithdrawalProof is WithdrawalSetup {

    using BeaconChainProofs for bytes32;
    using stdStorage for StdStorage;

    uint256 constant MIN_CLAIM_INTERVAL = 10 minutes;

    function test_startClaimNST_success() public {
        // simulate beacon chain withdrawal that transfers deposit amount to the capsule
        vm.deal(address(capsule), depositAmount);
        assertEq(address(capsule).balance, depositAmount);
        capsule.startClaimNST(depositAmount);
    }

    function test_startClaimNST_revert_ExceedClaimableBalance() public {
        // simulate beacon chain withdrawal that transfers deposit amount to the capsule
        vm.deal(address(capsule), depositAmount);
        uint256 claimableBalance = address(capsule).balance - capsule.withdrawableBalance();
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector));
        capsule.startClaimNST(claimableBalance + 0.1 ether);
    }

    function test_startClaimNST_revert_HasClaimInProgress() public {
        // simulate beacon chain withdrawal that transfers deposit amount to the capsule
        vm.deal(address(capsule), depositAmount);

        uint256 claimableBalance = address(capsule).balance - capsule.withdrawableBalance();
        // start a claim to make capsule in claim progress
        capsule.startClaimNST(claimableBalance / 3);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClaimAlreadyInProgress.selector));
        capsule.startClaimNST(claimableBalance / 3);
    }

    function test_startClaimNST_revert_TooEarlySinceLastClaim() public {
        // simulate beacon chain withdrawal that transfers deposit amount to the capsule
        vm.deal(address(capsule), depositAmount);
        // simulate the claim is successful and updates the last claim timestamp
        capsule.unlockETHPrincipal(depositAmount);

        uint256 claimableBalance = address(capsule).balance - capsule.withdrawableBalance();

        vm.warp(block.timestamp + MIN_CLAIM_INTERVAL - 1 seconds);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooEarlySinceLastClaim.selector));
        capsule.startClaimNST(claimableBalance / 3);
    }

}
