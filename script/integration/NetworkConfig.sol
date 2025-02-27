// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {INetworkConfig, NetworkParams} from "src/interfaces/INetworkConfig.sol";

/// @dev The chain ID that is allowed for integration tests.
uint256 constant ALLOWED_CHAIN_ID = 31_337;

/// @title NetworkConfig
/// @author imua-xyz
/// @notice This contract provides an interface to expose the network configuration.
/// @dev This contract is used for integration testing and is a substitute for the NetworkConstants library. Hence, it
/// is located in the `integration` folder, and it is not used in the production environment. It needs to have the
/// params defined in the constructor and they aren't changed later.
contract NetworkConfig is INetworkConfig {

    /// @notice The network configuration.
    NetworkParams public params;

    /// @notice Constructs the NetworkConfig contract.
    /// @param deposit The deposit contract address to set for the integration network.
    /// @param denebTimestamp The deneb timestamp to set for the integration network.
    /// @param slotsPerEpoch The number of slots per epoch to set for the integration network.
    /// @param secondsPerSlot The number of seconds per slot to set for the integration network.
    /// @param beaconGenesisTimestamp The timestamp of the beacon chain genesis.
    /// @dev Given that this contract is only used during integration testing, the parameters are set in the
    /// constructor and cannot be changed later.
    constructor(
        address deposit,
        uint256 denebTimestamp,
        uint64 slotsPerEpoch,
        uint64 secondsPerSlot,
        uint256 beaconGenesisTimestamp
    ) {
        // the value of 31337 is known to be a reserved chain id for testing.
        // it is different from Anvil's 1337 to avoid confusion, since it does not support PoS.
        // the downside of this number is that another chain id must be configured in `foundry.toml` to be used
        // by default, during tests. setting this configuration also prevents NetworkConstants from complaining
        // about Unsupported Network during tests, so it is worth it.
        require(block.chainid == ALLOWED_CHAIN_ID, "only the 31337 chain ID is supported for integration tests");
        require(deposit != address(0), "Deposit contract address must be set for integration network");
        require(denebTimestamp > 0, "Deneb timestamp must be set for integration network");
        require(slotsPerEpoch > 0, "Slots per epoch must be set for integration network");
        require(secondsPerSlot > 0, "Seconds per slot must be set for integration network");
        require(beaconGenesisTimestamp > 0, "Beacon genesis timestamp must be set for integration network");
        params = NetworkParams(deposit, denebTimestamp, slotsPerEpoch, secondsPerSlot, beaconGenesisTimestamp);
    }

    /// @inheritdoc INetworkConfig
    function getDepositContractAddress() external view returns (address) {
        return params.depositContractAddress;
    }

    /// @inheritdoc INetworkConfig
    function getDenebHardForkTimestamp() external view returns (uint256) {
        return params.denebHardForkTimestamp;
    }

    /// @inheritdoc INetworkConfig
    function getSlotsPerEpoch() external view returns (uint64) {
        return params.slotsPerEpoch;
    }

    /// @inheritdoc INetworkConfig
    function getSecondsPerSlot() external view returns (uint64) {
        return params.secondsPerSlot;
    }

    /// @inheritdoc INetworkConfig
    function getSecondsPerEpoch() external view returns (uint64) {
        // reading from storage is more expensive than performing the calculation
        return params.slotsPerEpoch * params.secondsPerSlot;
    }

    /// @inheritdoc INetworkConfig
    function getBeaconGenesisTimestamp() external view returns (uint256) {
        return params.beaconGenesisTimestamp;
    }

}
