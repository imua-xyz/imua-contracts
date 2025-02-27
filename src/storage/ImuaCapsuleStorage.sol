// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {NetworkConstants} from "../libraries/NetworkConstants.sol";

import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {INetworkConfig} from "../interfaces/INetworkConfig.sol";

import {IBeaconChainOracle} from "@beacon-oracle/contracts/src/IBeaconChainOracle.sol";

/// @title ImuaCapsuleStorage
/// @author imua-xyz
/// @notice The storage contract for the ImuaCapsule contract.
/// @dev It does not inherit from INetworkConfig because the functions are `internal` and not `external` or `public`.
/// Additionally, not all functions are used in the ImuaCapsule contract.
contract ImuaCapsuleStorage {

    /// @notice Enum representing the status of a validator.
    // solhint-disable-next-line contract-name-camelcase
    enum VALIDATOR_STATUS {
        UNREGISTERED, // the validator has not been registered in this ImuaCapsule
        REGISTERED, // staked on ethpos and withdrawal credentials are pointed to the ImuaCapsule
        WITHDRAWN // withdrawn from the Beacon Chain

    }

    /// @notice Struct representing a validator in the ImuaCapsule.
    /// @param validatorIndex The index of the validator in the Beacon Chain.
    /// @param restakedBalanceGwei The amount of Beacon Chain ETH restaked on Imuachain in gwei.
    /// @param mostRecentBalanceUpdateTimestamp The timestamp of the validator's most recent balance update.
    /// @param status The status of the validator.
    struct Validator {
        // index of the validator in the beacon chain
        uint256 validatorIndex;
        // status of the validator
        VALIDATOR_STATUS status;
    }

    // constant state variables
    /// @notice The maximum time after the deposit proof timestamp that a deposit can be proven.
    /// @dev It is measured from the proof generation timestamp and not the deposit timestamp. If the proof becomes too
    /// old, it can be regenerated and then submitted, as long as the beacon block root for the proof timestamp is
    /// available (within the oracle or through the system contract).
    /// @dev Without the beacon oracle, the maximum permissible window would be 8,191 blocks * 12 seconds / block
    /// = 27.3 hours, according to EIP-4788. However, with the beacon oracle, the root is available for any timestamp
    /// and hence, there is no technical limit.
    /// @dev A smaller value is chosen to be more conservative, that is, the limit is more a practical one than a
    /// technical one.
    /// @dev On our integration test network, the seconds per slot is 4, so the maximum window becomes 9.1 hours, which
    /// is higher than this one. So, there is no need to make this parameter configurable based on the network.
    uint256 internal constant VERIFY_BALANCE_UPDATE_WINDOW_SECONDS = 4.5 hours;

    /// @notice Conversion factor from gwei to wei.
    uint256 public constant GWEI_TO_WEI = 1e9;

    /// @notice The maximum amount of balance that a validator can restake, in gwei.
    uint64 public constant MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR = 32e9;

    /// @notice The address of the NetworkConfig contract.
    /// @dev If it is set to the 0 address, the NetworkConstants library is used instead.
    address public immutable NETWORK_CONFIG;

    /// @notice the amount of execution layer ETH in this contract that is staked in(i.e. withdrawn from the Beacon
    /// Chain but not from Imuachain)
    uint256 public withdrawableBalance;

    /// @notice The amount of non-beacon chain ETH balance.
    /// @dev This variable tracks any ETH deposited into this contract via the `receive` fallback function
    uint256 public nonBeaconChainETHBalance;

    /// @notice The owner of the ImuaCapsule.
    address payable public capsuleOwner;

    /// @notice The address of the NativeRestakingController contract.
    INativeRestakingController public gateway;

    /// @notice The address of the Beacon Chain Oracle contract.
    IBeaconChainOracle public beaconOracle;

    /// @dev Mapping of validator pubkey hash to their corresponding struct.
    mapping(bytes32 pubkeyHash => Validator validator) internal _capsuleValidators;

    /// @dev Mapping of validator index to their corresponding pubkey hash.
    mapping(uint256 index => bytes32 pubkeyHash) internal _capsuleValidatorsByIndex;

    /// @notice This is a mapping of validatorPubkeyHash to withdrawal index to whether or not they have proven a
    /// withdrawal
    mapping(bytes32 => mapping(uint256 => bool)) public provenWithdrawal;

    /// @dev Storage gap to allow for future upgrades.
    uint256[40] private __gap;

    /// @notice Sets the network configuration contract address for the ImuaCapsule contract.
    /// @param networkConfig_ The address of the NetworkConfig contract.
    constructor(address networkConfig_) {
        NETWORK_CONFIG = networkConfig_;
    }

    /// @dev Gets the deneb hard fork timestamp, either from the NetworkConfig contract or the NetworkConstants library.
    function getDenebHardForkTimestamp() internal view returns (uint256) {
        if (NETWORK_CONFIG == address(0)) {
            return NetworkConstants.getDenebHardForkTimestamp();
        } else {
            return INetworkConfig(NETWORK_CONFIG).getDenebHardForkTimestamp();
        }
    }

    /// @dev Gets the slots per epoch, either from the NetworkConfig contract or the NetworkConstants library.
    function getSlotsPerEpoch() internal view returns (uint64) {
        if (NETWORK_CONFIG == address(0)) {
            return NetworkConstants.getSlotsPerEpoch();
        } else {
            return INetworkConfig(NETWORK_CONFIG).getSlotsPerEpoch();
        }
    }

    /// @dev Gets the seconds per slot, either from the NetworkConfig contract or the NetworkConstants library.
    function getSecondsPerEpoch() internal view returns (uint64) {
        if (NETWORK_CONFIG == address(0)) {
            return NetworkConstants.getSecondsPerEpoch();
        } else {
            return INetworkConfig(NETWORK_CONFIG).getSecondsPerEpoch();
        }
    }

    /// @dev Gets the beacon genesis timestamp, either from the NetworkConfig contract or the NetworkConstants library.
    function getBeaconGenesisTimestamp() internal view returns (uint256) {
        if (NETWORK_CONFIG == address(0)) {
            return NetworkConstants.getBeaconGenesisTimestamp();
        } else {
            return INetworkConfig(NETWORK_CONFIG).getBeaconGenesisTimestamp();
        }
    }

}
