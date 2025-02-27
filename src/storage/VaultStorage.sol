// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILSTRestakingController} from "../interfaces/ILSTRestakingController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VaultStorage
/// @author imua-xyz
/// @notice Storage contract for the Vault contract.
contract VaultStorage {

    /// @notice Mapping of withdrawable balances for each user.
    mapping(address => uint256) public withdrawableBalances;

    /// @notice Mapping of total deposited principal amounts for each user.
    mapping(address => uint256) public totalDepositedPrincipalAmount;

    /// @notice Mapping of total unlocked principal amounts for each user.
    mapping(address => uint256) public totalUnlockPrincipalAmount;

    /// @notice Address of the underlying token.
    IERC20 public underlyingToken;

    /// @notice TVL limit for the vault.
    uint256 public tvlLimit;

    /// @notice Consumed TVL.
    uint256 public consumedTvl;

    /// @notice Address of the gateway contract.
    ILSTRestakingController public gateway;

    /// @notice Emitted when a user's principal balance is deposited.
    /// @param depositor The address of the depositor.
    /// @param amount The amount of the principal balance deposited.
    event PrincipalDeposited(address indexed depositor, uint256 amount);

    /// @notice Emitted when a user's principal balance is unlocked for withdrawal.
    /// @param staker The address of the withdrawer.
    /// @param amount The amount of the principal balance unlocked.
    event PrincipalUnlocked(address indexed staker, uint256 amount);

    /// @notice Emitted when a user's principal balance is withdrawn.
    /// @param src The address of the withdrawer.
    /// @param dst The address of the recipient.
    /// @param amount The amount of the principal balance withdrawn.
    event PrincipalWithdrawn(address indexed src, address indexed dst, uint256 amount);

    /// @notice Emitted upon the TVL limit being updated.
    /// @param newTvlLimit The new TVL limit.
    event TvlLimitUpdated(uint256 newTvlLimit);

    /// @notice Emitted when the TVL limit consumed so far changes.
    /// @param consumed The total amount consumed, including the current transaction.
    event ConsumedTvlChanged(uint256 consumed);

    /// @dev Storage gap to allow for future upgrades.
    uint256[40] private __gap;

}
