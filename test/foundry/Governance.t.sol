// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@safe-contracts/GnosisSafe.sol";
import "@safe-contracts/GnosisSafeL2.sol";
import "@safe-contracts/proxies/GnosisSafeProxyFactory.sol";
import "forge-std/Test.sol";
import "src/core/ClientChainGateway.sol";
import "src/utils/CustomTimelockController.sol";

import "@beacon-oracle/contracts/src/EigenLayerBeaconOracle.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";

import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

import "src/core/ClientChainGateway.sol";
import "src/storage/ClientChainGatewayStorage.sol";

import "src/core/ImuaCapsule.sol";

import {RewardVault} from "src/core/RewardVault.sol";
import {Vault} from "src/core/Vault.sol";
import {IRewardVault} from "src/interfaces/IRewardVault.sol";

import {NonShortCircuitEndpointV2Mock} from "../mocks/NonShortCircuitEndpointV2Mock.sol";
import "src/interfaces/IImuaCapsule.sol";
import "src/interfaces/IVault.sol";

import "src/utils/BeaconProxyBytecode.sol";

import {NetworkConstants} from "src/libraries/NetworkConstants.sol";
import {BootstrapStorage} from "src/storage/BootstrapStorage.sol";

contract GovernanceTest is Test {

    struct Player {
        uint256 privateKey;
        address addr;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    Player signer1;
    Player signer2;
    Player signer3;

    GnosisSafeL2 public safeImplementation;
    GnosisSafeProxyFactory public safeProxyFactory;
    GnosisSafeL2 public multisig;
    CustomTimelockController public timelock;

    ERC20PresetFixedSupply restakeToken;

    ClientChainGateway clientGateway;
    ClientChainGateway clientGatewayLogic;
    ILayerZeroEndpointV2 clientChainLzEndpoint;
    IBeaconChainOracle beaconOracle;
    IVault vaultImplementation;
    IRewardVault rewardVaultImplementation;
    IImuaCapsule capsuleImplementation;
    IBeacon vaultBeacon;
    IBeacon rewardVaultBeacon;
    IBeacon capsuleBeacon;
    BeaconProxyBytecode beaconProxyBytecode;

    uint32 imuachainChainId = 2;
    uint32 clientChainId = 1;

    uint256 holeskyFork;

    function setUp() public {
        // Fork Holesky testnet
        holeskyFork = vm.createSelectFork("https://ethereum-holesky.publicnode.com");

        // Use already deployed Gnosis Safe contracts on Holesky
        safeImplementation = GnosisSafeL2(payable(0x3E5c63644E683549055b9Be8653de26E0B4CD36E));
        safeProxyFactory = GnosisSafeProxyFactory(0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2);
        address fallbackHandlerAddress = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;

        // initialise players
        signer1 = Player({privateKey: 1, addr: vm.addr(1)});
        signer2 = Player({privateKey: 2, addr: vm.addr(2)});
        signer3 = Player({privateKey: 3, addr: vm.addr(3)});

        // Deploy 2-of-3 multisig
        address[] memory owners = new address[](3);
        owners[0] = signer1.addr;
        owners[1] = signer2.addr;
        owners[2] = signer3.addr;

        bytes memory initializer = abi.encodeWithSelector(
            GnosisSafe.setup.selector,
            owners,
            2,
            address(0),
            "",
            fallbackHandlerAddress,
            address(0),
            0,
            payable(address(0))
        );

        GnosisSafeProxy multisigProxy =
            safeProxyFactory.createProxyWithNonce(address(safeImplementation), initializer, 0);
        multisig = GnosisSafeL2(payable(address(multisigProxy)));

        // Deploy CustomTimelockController
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        address[] memory circuitBreakers = new address[](1);
        proposers[0] = address(multisig);
        executors[0] = address(multisig);
        circuitBreakers[0] = address(multisig);

        timelock = new CustomTimelockController(
            1 days, // minDelay
            proposers,
            executors,
            circuitBreakers,
            address(multisig) // admin
        );

        // Deploy and initialize ClientChainGateway
        _deployClientChainGateway(address(timelock));
    }

    function _deployClientChainGateway(address owner) internal {
        beaconOracle = IBeaconChainOracle(new EigenLayerBeaconOracle(NetworkConstants.getBeaconGenesisTimestamp()));

        vaultImplementation = new Vault();
        rewardVaultImplementation = new RewardVault();
        capsuleImplementation = new ImuaCapsule(address(0));

        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));

        beaconProxyBytecode = new BeaconProxyBytecode();

        restakeToken = new ERC20PresetFixedSupply("rest", "rest", 1e16, owner);

        clientChainLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, owner);
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });

        // Update ClientChainGateway constructor call
        clientGatewayLogic = new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        clientGateway = ClientChainGateway(
            payable(address(new TransparentUpgradeableProxy(address(clientGatewayLogic), address(proxyAdmin), "")))
        );

        clientGateway.initialize(payable(owner));
    }

    function testFuzz_MultisigCanPauseImmediately(uint8 signersMask) public {
        vm.assume(signersMask > 0 && signersMask < 8); // Ensure at least one signer and constrain to 3 bits

        // Fork Holesky testnet
        vm.selectFork(holeskyFork);

        // Prepare multisig transaction to call pause on timelock
        bytes memory pauseData = abi.encodeWithSelector(CustomTimelockController.pause.selector, address(clientGateway));

        // Use the fuzzed input to determine which signers to include
        Player[] memory selectedSigners = selectSigners(signersMask);

        // Sign the transaction
        bytes memory signatures = signMultisigTransaction(address(timelock), 0, pauseData, selectedSigners);

        // Execute multisig transaction if we have enough signers
        if (selectedSigners.length >= 2) {
            multisig.execTransaction(
                address(timelock),
                0,
                pauseData,
                Enum.Operation.Call,
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(0), // refundReceiver
                signatures
            );

            // Check if gateway is paused
            assertTrue(clientGateway.paused(), "Gateway should be paused");
        } else {
            // If we don't have enough signers, expect the transaction to revert
            vm.expectRevert();
            multisig.execTransaction(
                address(timelock),
                0,
                pauseData,
                Enum.Operation.Call,
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(0), // refundReceiver
                signatures
            );

            // Check that the gateway is still not paused
            assertFalse(clientGateway.paused(), "Gateway should not be paused");
        }
    }

    function testFuzz_MultisigNeedsDelayToUnpause(
        uint8 pauseSignersMask,
        uint8 scheduleSignersMask,
        uint8 executeSignersMask
    ) public {
        vm.assume(pauseSignersMask > 0 && pauseSignersMask < 8);
        vm.assume(scheduleSignersMask > 0 && scheduleSignersMask < 8);
        vm.assume(executeSignersMask > 0 && executeSignersMask < 8);

        // Fork Holesky testnet
        vm.selectFork(holeskyFork);

        // First, pause the gateway
        bytes memory pauseData = abi.encodeWithSelector(CustomTimelockController.pause.selector, address(clientGateway));
        Player[] memory pauseSigners = selectSigners(pauseSignersMask);
        bytes memory pauseSignatures = signMultisigTransaction(address(timelock), 0, pauseData, pauseSigners);

        if (pauseSigners.length >= 2) {
            multisig.execTransaction(
                address(timelock), 0, pauseData, Enum.Operation.Call, 0, 0, 0, address(0), payable(0), pauseSignatures
            );
            assertTrue(clientGateway.paused(), "Gateway should be paused");
        } else {
            vm.expectRevert();
            multisig.execTransaction(
                address(timelock), 0, pauseData, Enum.Operation.Call, 0, 0, 0, address(0), payable(0), pauseSignatures
            );
            assertFalse(clientGateway.paused(), "Gateway should not be paused");
            return; // Exit the test if we couldn't pause
        }

        // Prepare unpause data
        bytes memory unpauseData = abi.encodeWithSelector(ClientChainGateway.unpause.selector);

        // Schedule unpause operation
        bytes memory scheduleData = abi.encodeWithSelector(
            TimelockController.schedule.selector, address(clientGateway), 0, unpauseData, bytes32(0), bytes32(0), 1 days
        );
        Player[] memory scheduleSigners = selectSigners(scheduleSignersMask);
        bytes memory scheduleSignatures = signMultisigTransaction(address(timelock), 0, scheduleData, scheduleSigners);

        if (scheduleSigners.length >= 2) {
            multisig.execTransaction(
                address(timelock),
                0,
                scheduleData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(0),
                scheduleSignatures
            );
        } else {
            vm.expectRevert();
            multisig.execTransaction(
                address(timelock),
                0,
                scheduleData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(0),
                scheduleSignatures
            );
            return; // Exit the test if we couldn't schedule
        }

        // Try to execute immediately (should fail)
        bytes memory executeData = abi.encodeWithSelector(
            TimelockController.execute.selector, address(clientGateway), 0, unpauseData, bytes32(0), bytes32(0)
        );
        Player[] memory executeSigners = selectSigners(executeSignersMask);
        bytes memory executeSignatures = signMultisigTransaction(address(timelock), 0, executeData, executeSigners);

        // The transaction should revert because not enough signers or delay not passed
        vm.expectRevert();
        multisig.execTransaction(
            address(timelock), 0, executeData, Enum.Operation.Call, 0, 0, 0, address(0), payable(0), executeSignatures
        );

        // Wait for delay
        vm.warp(block.timestamp + 1 days + 1);

        // Execute unpause operation
        if (executeSigners.length >= 2) {
            multisig.execTransaction(
                address(timelock),
                0,
                executeData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(0),
                executeSignatures
            );
            assertFalse(clientGateway.paused(), "Gateway should be unpaused");
        } else {
            vm.expectRevert();
            multisig.execTransaction(
                address(timelock),
                0,
                executeData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(0),
                executeSignatures
            );
            assertTrue(clientGateway.paused(), "Gateway should still be paused");
        }
    }

    function selectSigners(uint8 signersMask) internal view returns (Player[] memory) {
        Player[] memory selectedSigners = new Player[](3);
        uint256 signerCount = 0;

        if (signersMask & 1 != 0) {
            selectedSigners[signerCount++] = signer1;
        }
        if (signersMask & 2 != 0) {
            selectedSigners[signerCount++] = signer2;
        }
        if (signersMask & 4 != 0) {
            selectedSigners[signerCount++] = signer3;
        }

        // Resize the array to match the actual number of selected signers
        assembly {
            mstore(selectedSigners, signerCount)
        }

        return selectedSigners;
    }

    function signMultisigTransaction(address to, uint256 value, bytes memory data, Player[] memory signers)
        internal
        view
        returns (bytes memory)
    {
        bytes32 txHash = multisig.getTransactionHash(
            to,
            value,
            data,
            Enum.Operation.Call,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(0), // refundReceiver
            multisig.nonce()
        );

        // Sort signers array based on address
        for (uint256 i = 0; i < signers.length - 1; i++) {
            for (uint256 j = 0; j < signers.length - i - 1; j++) {
                if (signers[j].addr > signers[j + 1].addr) {
                    Player memory temp = signers[j];
                    signers[j] = signers[j + 1];
                    signers[j + 1] = temp;
                }
            }
        }

        // Generate sorted signatures
        bytes memory signatures;
        for (uint256 i = 0; i < signers.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[i].privateKey, txHash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }

        // return signatures
        return signatures;
    }

}
