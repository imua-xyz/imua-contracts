// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";

/// @title ImuaCapsuleStorageBSC
/// @notice Storage for ImuaCapsuleBSC (BNB native staking capsule).
contract ImuaCapsuleStorageBSC {

    /// @notice The minimum interval between successful NST claims.
    uint256 public constant MIN_CLAIM_INTERVAL = 10 minutes;

    /// @notice Withdrawable native principal (BNB) unlocked by Imuachain.
    uint256 public withdrawableBalance;

    /// @notice Capsule owner (the delegator).
    address payable public capsuleOwner;

    /// @notice ClientChainGateway (native restaking controller) address.
    INativeRestakingController public gateway;

    /// @notice Stake hub / staking system contract address (network-specific).
    address public stakeHub;

    /// @notice The validator chosen by this capsule (one capsule -> one validator).
    address public validator;

    /// @notice The per-validator credit contract address used to query locked+pooled BNB for this capsule.
    address public validatorCreditContract;

    /// @notice Whether a NST claim is in progress.
    bool public inClaimProgress;

    /// @notice Timestamp of the last successful NST claim.
    uint256 public lastClaimTimestamp;

    /// @notice Pending claim amount (BNB) for the current claim-in-progress.
    uint256 public pendingClaimAmount;

    /// @notice Pending claim request count to be claimed from StakeHub for the current claim.
    uint256 public pendingClaimRequestCount;

    /// @dev Storage gap for upgrade safety.
    uint256[41] private __gap;

}
