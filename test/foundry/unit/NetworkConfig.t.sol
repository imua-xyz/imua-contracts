// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {stdError} from "forge-std/StdError.sol";
import "forge-std/Test.sol";
import {NetworkConfig} from "script/integration/NetworkConfig.sol";

contract NetworkConfigTest is Test {

    NetworkConfig public networkConfig;

    uint256 public constant ALLOWED_CHAIN_ID = 31_337;
    address public constant DEPOSIT_CONTRACT_ADDRESS = 0x1234567890AbcdEF1234567890aBcdef12345678;
    uint256 public constant DENEB_TIMESTAMP = 1_710_338_135;
    uint64 public constant SLOTS_PER_EPOCH = 32;
    uint64 public constant SECONDS_PER_SLOT = 12;
    uint256 public constant BEACON_GENESIS_TIMESTAMP = 1_606_824_023;
    uint256 public constant PECTRA_TIMESTAMP = 1_746_612_311;

    /// @notice Sets up the chain ID for testing and initializes a new contract instance.
    function setUp() public {
        // Simulate the chain ID for integration testing (31337)
        vm.chainId(31_337);

        // Deploy the contract with valid test parameters
        networkConfig = new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS,
            DENEB_TIMESTAMP,
            SLOTS_PER_EPOCH,
            SECONDS_PER_SLOT,
            BEACON_GENESIS_TIMESTAMP,
            PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract was correctly initialized and returns the correct deposit contract address.
    function testGetDepositContractAddress() public {
        assertEq(
            networkConfig.getDepositContractAddress(), DEPOSIT_CONTRACT_ADDRESS, "Deposit contract address mismatch"
        );
    }

    /// @notice Tests if the contract correctly returns the Deneb hard fork timestamp.
    function testGetDenebHardForkTimestamp() public {
        assertEq(networkConfig.getDenebHardForkTimestamp(), DENEB_TIMESTAMP, "Deneb timestamp mismatch");
    }

    /// @notice Tests if the contract correctly returns the number of slots per epoch.
    function testGetSlotsPerEpoch() public {
        assertEq(networkConfig.getSlotsPerEpoch(), SLOTS_PER_EPOCH, "Slots per epoch mismatch");
    }

    /// @notice Tests if the contract correctly returns the number of seconds per slot.
    function testGetSecondsPerSlot() public {
        assertEq(networkConfig.getSecondsPerSlot(), SECONDS_PER_SLOT, "Seconds per slot mismatch");
    }

    /// @notice Tests if the contract correctly calculates the number of seconds per epoch.
    function testGetSecondsPerEpoch() public {
        assertEq(networkConfig.getSecondsPerEpoch(), SECONDS_PER_SLOT * SLOTS_PER_EPOCH, "Seconds per epoch mismatch");
    }

    /// @notice Tests if the contract correctly returns the beacon chain genesis timestamp.
    function testGetBeaconGenesisTimestamp() public {
        assertEq(
            networkConfig.getBeaconGenesisTimestamp(), BEACON_GENESIS_TIMESTAMP, "Beacon genesis timestamp mismatch"
        );
    }

    /// @notice Tests if the contract reverts when initialized with an unsupported chain ID.
    function testRevertUnsupportedChainId() public {
        // Change the chain ID to something other than 31337
        vm.chainId(1);
        vm.expectRevert("only the 31337 chain ID is supported for integration tests");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS,
            DENEB_TIMESTAMP,
            SLOTS_PER_EPOCH,
            SECONDS_PER_SLOT,
            BEACON_GENESIS_TIMESTAMP,
            PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with an invalid deposit contract address.
    function testRevertInvalidDepositAddress() public {
        vm.expectRevert("Deposit contract address must be set for integration network");
        new NetworkConfig(
            address(0), DENEB_TIMESTAMP, SLOTS_PER_EPOCH, SECONDS_PER_SLOT, BEACON_GENESIS_TIMESTAMP, PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with an invalid Deneb timestamp.
    function testRevertInvalidDenebTimestamp() public {
        vm.expectRevert("Deneb timestamp must be set for integration network");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS, 0, SLOTS_PER_EPOCH, SECONDS_PER_SLOT, BEACON_GENESIS_TIMESTAMP, PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with invalid slots per epoch.
    function testRevertInvalidSlotsPerEpoch() public {
        vm.expectRevert("Slots per epoch must be set for integration network");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS, DENEB_TIMESTAMP, 0, SECONDS_PER_SLOT, BEACON_GENESIS_TIMESTAMP, PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with invalid seconds per slot.
    function testRevertInvalidSecondsPerSlot() public {
        vm.expectRevert("Seconds per slot must be set for integration network");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS, DENEB_TIMESTAMP, SLOTS_PER_EPOCH, 0, BEACON_GENESIS_TIMESTAMP, PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with an invalid beacon genesis timestamp.
    function testRevertInvalidBeaconGenesisTimestamp() public {
        vm.expectRevert("Beacon genesis timestamp must be set for integration network");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS, DENEB_TIMESTAMP, SLOTS_PER_EPOCH, SECONDS_PER_SLOT, 0, PECTRA_TIMESTAMP
        );
    }

    /// @notice Tests if the contract reverts when initialized with an invalid Pectra timestamp.
    function testRevertInvalidPectraTimestamp() public {
        vm.expectRevert("Pectra timestamp must be set for integration network");
        new NetworkConfig(
            DEPOSIT_CONTRACT_ADDRESS, DENEB_TIMESTAMP, SLOTS_PER_EPOCH, SECONDS_PER_SLOT, BEACON_GENESIS_TIMESTAMP, 0
        );
    }

}
