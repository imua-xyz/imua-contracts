// SPDX-License-Identifier: MIT
// solhint-disable max-line-length
pragma solidity ^0.8.0;

import {NetworkParams} from "../interfaces/INetworkConfig.sol";

/// @title NetworkConstants
/// @notice This library provides constants for known Ethereum PoS networks.
/// @author imua-xyz
/// @dev It does not have `is INetworkConfig` since libraries cannot do that.
/// @dev It is a library because we do not expect the parameters to change at all.
library NetworkConstants {

    /// @notice The default number of slots in an epoch.
    uint64 public constant SLOTS_PER_EPOCH_DEFAULT = 32;

    /// @notice The default number of seconds in a slot.
    uint64 public constant SECONDS_PER_SLOT_DEFAULT = 12;

    /// @notice Returns the network params for the running chain ID.
    /// @notice Reverts if the chain ID is not supported.
    function getNetworkParams() internal view returns (NetworkParams memory) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            // mainnet
            return NetworkParams(
                // https://github.com/eth-clients/mainnet/blob/f6b7882618a5ad2c1d2731ae35e5d16a660d5bb7/metadata/config.yaml#L101
                0x00000000219ab540356cBB839Cbe05303d7705Fa,
                // https://eips.ethereum.org/EIPS/eip-7569
                1_710_338_135,
                // the `config.yaml` above uses the below preset as a base
                // https://github.com/ethereum/consensus-specs/blob/a09d0c321550c5411557674a981e2b444a1178c0/presets/mainnet/phase0.yaml#L36
                SLOTS_PER_EPOCH_DEFAULT,
                // https://github.com/eth-clients/mainnet/blob/f6b7882618a5ad2c1d2731ae35e5d16a660d5bb7/metadata/config.yaml#L58
                SECONDS_PER_SLOT_DEFAULT,
                // https://github.com/eth-clients/mainnet?tab=readme-ov-file
                1_606_824_023
            );
        } else if (chainId == 11_155_111) {
            // sepolia
            return NetworkParams(
                // https://github.com/eth-clients/sepolia/blob/f2c219a93c4491cee3d90c18f2f8e82aed850eab/metadata/config.yaml#L77
                0x7f02C3E3c98b133055B8B348B2Ac625669Ed295D,
                // https://eips.ethereum.org/EIPS/eip-7569
                1_706_655_072,
                // the `config.yaml` above uses the below preset as a base
                // https://github.com/ethereum/consensus-specs/blob/a09d0c321550c5411557674a981e2b444a1178c0/presets/mainnet/phase0.yaml#L36
                SLOTS_PER_EPOCH_DEFAULT,
                // https://github.com/eth-clients/sepolia/blob/f2c219a93c4491cee3d90c18f2f8e82aed850eab/metadata/config.yaml#L42
                SECONDS_PER_SLOT_DEFAULT,
                // https://github.com/eth-clients/sepolia?tab=readme-ov-file#meta-data-bepolia
                1_655_733_600
            );
        } else if (chainId == 17_000) {
            // holesky
            return NetworkParams(
                // https://github.com/eth-clients/holesky/blob/901c0f33339f8e79250a1053dc9d995270b666e9/metadata/config.yaml#L78
                0x4242424242424242424242424242424242424242,
                // https://eips.ethereum.org/EIPS/eip-7569
                1_707_305_664,
                // the `config.yaml` above uses the below preset as a base
                // https://github.com/ethereum/consensus-specs/blob/a09d0c321550c5411557674a981e2b444a1178c0/presets/mainnet/phase0.yaml#L36
                SLOTS_PER_EPOCH_DEFAULT,
                // https://github.com/eth-clients/holesky/blob/901c0f33339f8e79250a1053dc9d995270b666e9/metadata/config.yaml#L43
                SECONDS_PER_SLOT_DEFAULT,
                // Holesky launched with Shanghai fork (which has the Beacon), hence there is no separate genesis time
                // for the beacon.
                // In other words, the genesis time of the execution layer is the same as that of the Beacon.
                // https://github.com/eth-clients/holesky?tab=readme-ov-file#metadata
                1_695_902_400
            );
        } else {
            // note that goerli is deprecated
            revert("Unsupported network");
        }
    }

    /// @notice Returns the deposit contract address.
    /// @return The deposit contract address.
    function getDepositContractAddress() external view returns (address) {
        return getNetworkParams().depositContractAddress;
    }

    /// @notice Returns the Deneb hard fork timestamp.
    /// @return The Deneb hard fork timestamp.
    function getDenebHardForkTimestamp() external view returns (uint256) {
        return getNetworkParams().denebHardForkTimestamp;
    }

    /// @notice Returns the number of slots per epoch.
    /// @return The number of slots per epoch.
    function getSlotsPerEpoch() external view returns (uint64) {
        // technically it is known to us that this is always 32 but we avoid returning the constant intentionally.
        return getNetworkParams().slotsPerEpoch;
    }

    /// @notice Returns the number of seconds per slot.
    /// @return The number of seconds per slot.
    function getSecondsPerSlot() external view returns (uint64) {
        // technically it is known to us that this is always 12 but we avoid returning the constant intentionally.
        return getNetworkParams().secondsPerSlot;
    }

    /// @notice Returns the number of seconds per epoch.
    /// @return The number of seconds per epoch.
    function getSecondsPerEpoch() external view returns (uint64) {
        // reading from storage is more expensive than performing the calculation
        return getNetworkParams().slotsPerEpoch * getNetworkParams().secondsPerSlot;
    }

    /// @notice Returns the beacon chain genesis timestamp.
    /// @return The beacon chain genesis timestamp.
    function getBeaconGenesisTimestamp() external view returns (uint256) {
        return getNetworkParams().beaconGenesisTimestamp;
    }

}
