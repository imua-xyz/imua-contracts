// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title INetworkConfig
/// @notice Interface for a network config contract to report params like slots per epoch and seconds per slot.
/// @dev This interface defines the necessary functions for interacting with the NetworkConfig contract.
/// @author imua-xyz
interface INetworkConfig {

    /// @notice Returns the deposit contract address.
    /// @return The deposit contract address.
    function getDepositContractAddress() external view returns (address);

    /// @notice Returns the Deneb hard fork timestamp.
    /// @return The Deneb hard fork timestamp.
    function getDenebHardForkTimestamp() external view returns (uint256);

    /// @notice Returns the number of slots per epoch.
    /// @return The number of slots per epoch.
    function getSlotsPerEpoch() external view returns (uint64);

    /// @notice Returns the number of seconds per slot.
    /// @return The number of seconds per slot.
    function getSecondsPerSlot() external view returns (uint64);

    /// @notice Returns the number of seconds per epoch.
    /// @return The number of seconds per epoch.
    function getSecondsPerEpoch() external view returns (uint64);

    /// @notice Returns the beacon chain genesis timestamp.
    /// @return The beacon chain genesis timestamp.
    function getBeaconGenesisTimestamp() external view returns (uint256);

}

/// @notice Struct representing the configuration of a network.
/// @param depositContractAddress The address of the deposit contract for the network.
/// @param denebHardForkTimestamp The timestamp of the Deneb hard fork for the network.
/// @param slotsPerEpoch The number of slots in an epoch for the network.
/// @param secondsPerSlot The number of seconds in a slot for the network.
struct NetworkParams {
    address depositContractAddress;
    uint256 denebHardForkTimestamp;
    uint64 slotsPerEpoch;
    uint64 secondsPerSlot;
    uint256 beaconGenesisTimestamp;
}
