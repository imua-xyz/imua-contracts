// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRewardVault} from "../interfaces/IRewardVault.sol";
import {Errors} from "../libraries/Errors.sol";

import {BootstrapStorage} from "../storage/BootstrapStorage.sol";
import {Action} from "../storage/GatewayStorage.sol";

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/// @title ClientChainGatewayStorage
/// @author imua-xyz
/// @notice ClientChainGatewayStorage is the storage used by the ClientChainGateway contract. It inherits from
/// BootstrapStorage, since the Bootstrap contract upgrades itself to the ClientChainGateway contract in response to a
/// cross-chain message.
/// @dev This contract should contain state variables, events and errors exclusively owned by
/// ClientChainGateway contract. Shared items should be kept in BootstrapStorage.
contract ClientChainGatewayStorage is BootstrapStorage {

    /// @dev Mapping of request IDs to their corresponding request data.
    mapping(uint64 => bytes) internal _registeredRequests;

    /// @dev Mapping of request IDs to their corresponding request actions.
    mapping(uint64 => Action) internal _registeredRequestActions;

    /// @notice The beacon for the reward vault contract, which stores the reward vault implementation.
    IBeacon public immutable REWARD_VAULT_BEACON;

    /// @dev The length of an add whitelist token request, in bytes.
    // bytes32 token + uint128 tvlLimit
    uint256 internal constant ADD_TOKEN_WHITELIST_REQUEST_LENGTH = 48;

    /// @dev The gas limit for all the destination chains.
    uint128 internal constant DESTINATION_GAS_LIMIT = 500_000;

    /// @dev The msg.value for all the destination chains.
    uint128 internal constant DESTINATION_MSG_VALUE = 0;

    /// @notice The reward vault contract.
    IRewardVault public rewardVault;

    /// @dev Storage gap to allow for future upgrades.
    uint256[39] private __gap;

    /* ----------------------------- restaking events     ------------------------------ */

    /// Emitted when a claim is successful.
    /// @param token Address of the token.
    /// @param recipient Address of the recipient.
    /// @param amount Amount of @param token claimed.
    event ClaimSucceeded(address token, address recipient, uint256 amount);

    /// @notice Emitted upon reward withdrawal response from Imuachain.
    /// @param success Whether the withdrawal was successful.
    /// @param token Address of the token.
    /// @param withdrawer Address of the withdrawer.
    /// @param amount Amount of @param token withdrawn.
    event WithdrawRewardResult(bool indexed success, address indexed token, address indexed withdrawer, uint256 amount);

    /// @notice Emitted when a response is processed.
    /// @param action The correspoding request action.
    /// @param requestId The corresponding request ID.
    /// @param success Whether the corresponding request was successful on Imuachain.
    event ResponseProcessed(Action indexed action, uint64 indexed requestId, bool indexed success);

    /// @notice Emitted when a reward vault is created.
    /// @param vault Address of the reward vault.
    event RewardVaultCreated(address vault);

    /// @notice Initializes the ClientChainGatewayStorage contract.
    /// @param config The parameters to initialize the contract immutable variables.
    /// @param rewardVaultBeacon_ The address of the reward vault beacon.
    constructor(ImmutableConfig memory config, address rewardVaultBeacon_) BootstrapStorage(config) {
        if (rewardVaultBeacon_ == address(0)) {
            revert Errors.InvalidImmutableConfig();
        }
        REWARD_VAULT_BEACON = IBeacon(rewardVaultBeacon_);
    }

}
