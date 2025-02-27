// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Test.sol";

import {NonShortCircuitEndpointV2Mock} from "test/mocks/NonShortCircuitEndpointV2Mock.sol";

import "../../src/core/Bootstrap.sol";
import "../../src/core/ImuaCapsule.sol";
import "../../src/utils/BeaconProxyBytecode.sol";
import {BeaconChainProofs} from "src/libraries/BeaconChainProofs.sol";
import {Endian} from "src/libraries/Endian.sol";
import "test/mocks/ETHPOSDepositMock.sol";

import {ClientChainGateway} from "src/core/ClientChainGateway.sol";
import {Vault} from "src/core/Vault.sol";
import {CustomProxyAdmin} from "src/utils/CustomProxyAdmin.sol";
import {MyToken} from "test/foundry/unit/MyToken.sol";

contract BootstrapDepositNSTTest is Test {

    using Endian for bytes32;
    using stdStorage for StdStorage;

    Bootstrap bootstrap;
    Bootstrap bootstrapLogic;

    address deployer = address(0x1);
    address owner = address(0x2);
    address depositor = address(0x3);

    uint256 spawnTime;
    uint256 offsetDuration;
    uint16 imuachainChainId = 1;
    uint16 clientChainId = 2;
    address[] whitelistTokens;
    uint256[] tvlLimits;
    MyToken myToken;
    CustomProxyAdmin proxyAdmin;
    NonShortCircuitEndpointV2Mock clientChainLzEndpoint;

    EigenLayerBeaconOracle beaconOracle;
    IVault vaultImplementation;
    IImuaCapsule capsuleImplementation;
    IBeacon vaultBeacon;
    IBeacon capsuleBeacon;
    BeaconProxyBytecode beaconProxyBytecode;
    ImuaCapsule capsule;

    bytes32[] validatorContainer;
    BeaconChainProofs.ValidatorContainerProof validatorProof;
    bytes32 beaconBlockRoot;

    uint256 constant BEACON_CHAIN_GENESIS_TIME = 1_606_824_023;
    uint64 constant SLOTS_PER_EPOCH = 32;
    uint64 constant SECONDS_PER_SLOT = 12;
    uint64 constant SECONDS_PER_EPOCH = SLOTS_PER_EPOCH * SECONDS_PER_SLOT;
    uint256 constant GWEI_TO_WEI = 1e9;
    address constant VIRTUAL_STAKED_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IETHPOSDeposit constant ETH_POS = IETHPOSDeposit(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    bytes constant BEACON_PROXY_BYTECODE =
        hex"608060405260405161090e38038061090e83398101604081905261002291610460565b61002e82826000610035565b505061058a565b61003e83610100565b6040516001600160a01b038416907f1cf3b03a6cf19fa2baba4df148e9dcabedea7f8a5c07840e207e5c089be95d3e90600090a260008251118061007f5750805b156100fb576100f9836001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100c5573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100e99190610520565b836102a360201b6100291760201c565b505b505050565b610113816102cf60201b6100551760201c565b6101725760405162461bcd60e51b815260206004820152602560248201527f455243313936373a206e657720626561636f6e206973206e6f74206120636f6e6044820152641d1c9858dd60da1b60648201526084015b60405180910390fd5b6101e6816001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156101b3573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906101d79190610520565b6102cf60201b6100551760201c565b61024b5760405162461bcd60e51b815260206004820152603060248201527f455243313936373a20626561636f6e20696d706c656d656e746174696f6e206960448201526f1cc81b9bdd08184818dbdb9d1c9858dd60821b6064820152608401610169565b806102827fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d5060001b6102de60201b6100641760201c565b80546001600160a01b0319166001600160a01b039290921691909117905550565b60606102c883836040518060600160405280602781526020016108e7602791396102e1565b9392505050565b6001600160a01b03163b151590565b90565b6060600080856001600160a01b0316856040516102fe919061053b565b600060405180830381855af49150503d8060008114610339576040519150601f19603f3d011682016040523d82523d6000602084013e61033e565b606091505b5090925090506103508683838761035a565b9695505050505050565b606083156103c65782516103bf576001600160a01b0385163b6103bf5760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e74726163740000006044820152606401610169565b50816103d0565b6103d083836103d8565b949350505050565b8151156103e85781518083602001fd5b8060405162461bcd60e51b81526004016101699190610557565b80516001600160a01b038116811461041957600080fd5b919050565b634e487b7160e01b600052604160045260246000fd5b60005b8381101561044f578181015183820152602001610437565b838111156100f95750506000910152565b6000806040838503121561047357600080fd5b61047c83610402565b60208401519092506001600160401b038082111561049957600080fd5b818501915085601f8301126104ad57600080fd5b8151818111156104bf576104bf61041e565b604051601f8201601f19908116603f011681019083821181831017156104e7576104e761041e565b8160405282815288602084870101111561050057600080fd5b610511836020830160208801610434565b80955050505050509250929050565b60006020828403121561053257600080fd5b6102c882610402565b6000825161054d818460208701610434565b9190910192915050565b6020815260008251806020840152610576816040850160208701610434565b601f01601f19169190910160400192915050565b61034e806105996000396000f3fe60806040523661001357610011610017565b005b6100115b610027610022610067565b610100565b565b606061004e83836040518060600160405280602781526020016102f260279139610124565b9392505050565b6001600160a01b03163b151590565b90565b600061009a7fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50546001600160a01b031690565b6001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100d7573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100fb9190610249565b905090565b3660008037600080366000845af43d6000803e80801561011f573d6000f35b3d6000fd5b6060600080856001600160a01b03168560405161014191906102a2565b600060405180830381855af49150503d806000811461017c576040519150601f19603f3d011682016040523d82523d6000602084013e610181565b606091505b50915091506101928683838761019c565b9695505050505050565b6060831561020d578251610206576001600160a01b0385163b6102065760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e747261637400000060448201526064015b60405180910390fd5b5081610217565b610217838361021f565b949350505050565b81511561022f5781518083602001fd5b8060405162461bcd60e51b81526004016101fd91906102be565b60006020828403121561025b57600080fd5b81516001600160a01b038116811461004e57600080fd5b60005b8381101561028d578181015183820152602001610275565b8381111561029c576000848401525b50505050565b600082516102b4818460208701610272565b9190910192915050565b60208152600082518060208401526102dd816040850160208701610272565b601f01601f1916919091016040019291505056fe416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564a2646970667358221220d51e81d3bc5ed20a26aeb05dce7e825c503b2061aa78628027300c8d65b9d89a64736f6c634300080c0033416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564";

    event DepositResult(bool indexed success, address indexed token, address indexed depositor, uint256 amount);
    event CapsuleCreated(address indexed owner, address indexed capsule);
    event StakedWithCapsule(address indexed staker, address indexed capsule);

    function setUp() public {
        vm.chainId(1); // set chainid to 1 so that capsule implementation can use default network constants
        vm.startPrank(deployer);

        whitelistTokens.push(VIRTUAL_STAKED_ETH_ADDRESS);
        tvlLimits.push(0);

        // use arbitrary address as beaconOracle
        beaconOracle = EigenLayerBeaconOracle(address(0xa));

        // deploy vault implementationcontract that has logics called by proxy
        vaultImplementation = new Vault();
        capsuleImplementation = new ImuaCapsule(address(0));

        // deploy the vault beacon that store the implementation contract address
        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));

        // deploy BeaconProxyBytecode to store BeaconProxyBytecode
        beaconProxyBytecode = new BeaconProxyBytecode();

        // then the ProxyAdmin
        proxyAdmin = new CustomProxyAdmin();
        // then the logic
        clientChainLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, owner);
        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);

        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(0xb));
        // we could also use encodeWithSelector and supply .initialize.selector instead.
        bytes memory initialization = abi.encodeCall(clientGatewayLogic.initialize, (payable(owner)));
        // then the params + proxy
        spawnTime = block.timestamp + 1 hours;
        offsetDuration = 30 minutes;
        bootstrap = Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                owner,
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(clientGatewayLogic),
                                initialization
                            )
                        )
                    )
                )
            )
        );
        // validate the initialization
        assertTrue(bootstrap.isWhitelistedToken(VIRTUAL_STAKED_ETH_ADDRESS));
        assertTrue(bootstrap.getWhitelistedTokensCount() == 1);
        assertFalse(bootstrap.bootstrapped());
        proxyAdmin.initialize(address(bootstrap));

        vm.stopPrank();

        // Load validator data from json file
        string memory validatorInfo = vm.readFile("test/foundry/test-data/validator_container_proof_302913.json");

        // Parse validator container and proof data
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

    function test_VerifyAndDepositNativeStake() public {
        vm.startPrank(depositor);

        // setup block environment like the current block timestamp
        _simulateBlockEnvironmentForNativeDeposit();

        // 1. firstly depositor should stake to beacon chain by depositing 32 ETH to ETHPOS contract
        IImuaCapsule expectedCapsule = IImuaCapsule(
            Create2.computeAddress(
                bytes32(uint256(uint160(depositor))),
                keccak256(abi.encodePacked(BEACON_PROXY_BYTECODE, abi.encode(address(capsuleBeacon), ""))),
                address(bootstrap)
            )
        );

        vm.expectEmit(true, true, true, true, address(bootstrap));
        emit CapsuleCreated(depositor, address(expectedCapsule));
        vm.expectEmit(address(bootstrap));
        emit StakedWithCapsule(depositor, address(expectedCapsule));

        vm.deal(depositor, 33 ether); // 32 ETH for deposit and 1 ETH for gas
        bootstrap.stake{value: 32 ether}(abi.encodePacked(_getPubkey(validatorContainer)), bytes(""), bytes32(0));

        // do some hack to replace expectedCapsule address with capsule address loaded from proof file
        // because capsule address is expected to be compatible with validator container withdrawal credentails
        _attachCapsuleToWithdrawalCredentials(expectedCapsule, depositor);

        // Calculate expected deposit value
        uint256 expectedDepositValue = uint256(_getEffectiveBalance(validatorContainer)) * GWEI_TO_WEI;
        if (expectedDepositValue > 32 ether) {
            expectedDepositValue = 32 ether;
        }

        // Record initial states
        uint256 initialDeposit = bootstrap.totalDepositAmounts(depositor, VIRTUAL_STAKED_ETH_ADDRESS);
        uint256 initialWithdrawable = bootstrap.withdrawableAmounts(depositor, VIRTUAL_STAKED_ETH_ADDRESS);
        uint256 initialDepositsByToken = bootstrap.depositsByToken(VIRTUAL_STAKED_ETH_ADDRESS);

        // Verify and deposit with real validator data
        vm.expectEmit(true, true, true, true);
        emit DepositResult(true, VIRTUAL_STAKED_ETH_ADDRESS, depositor, expectedDepositValue);
        bootstrap.verifyAndDepositNativeStake(validatorContainer, validatorProof);

        // Verify state changes
        assertEq(
            bootstrap.totalDepositAmounts(depositor, VIRTUAL_STAKED_ETH_ADDRESS),
            initialDeposit + expectedDepositValue,
            "Total deposit amount should increase"
        );
        assertEq(
            bootstrap.withdrawableAmounts(depositor, VIRTUAL_STAKED_ETH_ADDRESS),
            initialWithdrawable + expectedDepositValue,
            "Withdrawable amount should increase"
        );
        assertEq(
            bootstrap.depositsByToken(VIRTUAL_STAKED_ETH_ADDRESS),
            initialDepositsByToken + expectedDepositValue,
            "Deposits by token should increase"
        );
        assertTrue(bootstrap.isDepositor(depositor), "Should be marked as depositor");

        vm.stopPrank();
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

    function _getActivationEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[5].fromLittleEndianUint64();
    }

    function _getExitEpoch(bytes32[] storage vc) internal view returns (uint64) {
        return vc[6].fromLittleEndianUint64();
    }

    function _getEffectiveBalance(bytes32[] storage vc) internal view returns (uint64) {
        return vc[2].fromLittleEndianUint64();
    }

    function _getWithdrawalAmount(bytes32[] storage wc) internal view returns (uint64) {
        return wc[3].fromLittleEndianUint64();
    }

    function _simulateBlockEnvironmentForNativeDeposit() internal {
        /// we set the timestamp of proof to be exactly the timestamp that the validator container get activated on
        /// beacon chain
        uint256 activationTimestamp =
            BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        uint256 mockProofTimestamp = activationTimestamp;
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        /// we set current block timestamp to be exactly one slot after the proof generation timestamp
        uint256 mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);

        /// we mock the call beaconOracle.timestampToBlockRoot to return the expected block root in proof file
        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );

        // mock the call ETH_POS.deposit to return true
        vm.mockCall(address(ETH_POS), abi.encodeWithSelector(ETH_POS.deposit.selector), abi.encode(true));
    }

    function _attachCapsuleToWithdrawalCredentials(IImuaCapsule createdCapsule, address depositor_) internal {
        address capsuleAddress = _getCapsuleFromWithdrawalCredentials(_getWithdrawalCredentials(validatorContainer));
        vm.etch(capsuleAddress, address(createdCapsule).code);
        capsule = ImuaCapsule(payable(capsuleAddress));
        // TODO: load this dynamically somehow instead of hardcoding it
        bytes32 beaconSlotInCapsule = bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1);
        bytes32 beaconAddress = bytes32(uint256(uint160(address(capsuleBeacon))));
        vm.store(capsuleAddress, beaconSlotInCapsule, beaconAddress);
        assertEq(vm.load(capsuleAddress, beaconSlotInCapsule), beaconAddress);

        /// replace expectedCapsule with capsule
        bytes32 capsuleSlotInGateway =
            bytes32(stdstore.target(address(bootstrapLogic)).sig("ownerToCapsule(address)").with_key(depositor_).find());
        vm.store(address(bootstrap), capsuleSlotInGateway, bytes32(uint256(uint160(address(capsule)))));
        assertEq(address(bootstrap.ownerToCapsule(depositor_)), address(capsule));

        /// initialize replaced capsule
        capsule.initialize(address(bootstrap), payable(depositor_), address(beaconOracle));
    }

}
