// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {INetworkConfig} from "src/interfaces/INetworkConfig.sol";
import {NetworkConstants} from "src/libraries/NetworkConstants.sol";

import {IBeaconChainOracle} from "@beacon-oracle/contracts/src/IBeaconChainOracle.sol";

/// @title BeaconOracle
/// @author Succinct Labs and imua-xyz
contract BeaconOracle is IBeaconChainOracle {

    /// @notice The address of the beacon roots precompile.
    /// @dev https://eips.ethereum.org/EIPS/eip-4788
    address internal constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    /// @notice The length of the beacon roots ring buffer.
    /// @dev https://eips.ethereum.org/EIPS/eip-4788
    uint256 internal constant BEACON_ROOTS_HISTORY_BUFFER_LENGTH = 8191;

    /// @notice The timestamp to block root mapping.
    mapping(uint256 => bytes32) public timestampToBlockRoot;

    /// @notice The genesis block timestamp.
    uint256 public immutable GENESIS_BLOCK_TIMESTAMP;

    /// @notice The seconds per slot.
    uint256 public immutable SECONDS_PER_SLOT;

    /// @notice The event emitted when a new block is added to the oracle.
    event BeaconOracleUpdate(uint256 slot, uint256 timestamp, bytes32 blockRoot);

    /// @notice Block timestamp does not correspond to a valid slot.
    error InvalidBlockTimestamp();

    /// @notice Timestamp out of range for the the beacon roots precompile.
    error TimestampOutOfRange();

    /// @notice No block root is found using the beacon roots precompile.
    error NoBlockRootFound();

    constructor(address networkConfigAddress_) {
        if (networkConfigAddress_ == address(0)) {
            GENESIS_BLOCK_TIMESTAMP = NetworkConstants.getBeaconGenesisTimestamp();
            SECONDS_PER_SLOT = NetworkConstants.getSecondsPerSlot();
        } else {
            INetworkConfig networkConfig = INetworkConfig(networkConfigAddress_);
            GENESIS_BLOCK_TIMESTAMP = networkConfig.getBeaconGenesisTimestamp();
            SECONDS_PER_SLOT = networkConfig.getSecondsPerSlot();
        }
    }

    function addTimestamp(uint256 _targetTimestamp) external {
        if (_targetTimestamp < GENESIS_BLOCK_TIMESTAMP) {
            revert InvalidBlockTimestamp();
        }
        // If the targetTimestamp is not guaranteed to be within the beacon block root ring buffer, revert.
        if ((block.timestamp - _targetTimestamp) >= (BEACON_ROOTS_HISTORY_BUFFER_LENGTH * SECONDS_PER_SLOT)) {
            revert TimestampOutOfRange();
        }

        // If _targetTimestamp corresponds to slot n, then the block root for slot n - 1 is returned.
        (bool success,) = BEACON_ROOTS.staticcall(abi.encode(_targetTimestamp));

        if (!success) {
            revert InvalidBlockTimestamp();
        }

        uint256 slot = (_targetTimestamp - GENESIS_BLOCK_TIMESTAMP) / SECONDS_PER_SLOT;

        // Find the block root for the target timestamp.
        bytes32 blockRoot = findBlockRoot(uint64(slot));

        // Add the block root to the mapping.
        timestampToBlockRoot[_targetTimestamp] = blockRoot;

        // Emit the event.
        emit BeaconOracleUpdate(slot, _targetTimestamp, blockRoot);
    }

    /// @notice Attempts to find the block root for the given slot.
    /// @param _slot The slot to get the block root for.
    /// @return blockRoot The beacon block root of the given slot.
    /// @dev BEACON_ROOTS returns a block root for a given parent block's timestamp. To get the block root for slot
    ///      N, you use the timestamp of slot N+1. If N+1 is not avaliable, you use the timestamp of slot N+2, and
    //       so on.
    function findBlockRoot(uint64 _slot) public view returns (bytes32 blockRoot) {
        uint256 currBlockTimestamp = GENESIS_BLOCK_TIMESTAMP + ((_slot + 1) * SECONDS_PER_SLOT);

        uint256 earliestBlockTimestamp = block.timestamp - (BEACON_ROOTS_HISTORY_BUFFER_LENGTH * SECONDS_PER_SLOT);
        if (currBlockTimestamp <= earliestBlockTimestamp) {
            revert TimestampOutOfRange();
        }

        while (currBlockTimestamp <= block.timestamp) {
            (bool success, bytes memory result) = BEACON_ROOTS.staticcall(abi.encode(currBlockTimestamp));
            if (success && result.length > 0) {
                return abi.decode(result, (bytes32));
            }

            unchecked {
                currBlockTimestamp += SECONDS_PER_SLOT;
            }
        }

        revert NoBlockRootFound();
    }

}
