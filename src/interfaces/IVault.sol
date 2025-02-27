// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IVault
/// @notice Interface for a Vault contract handling deposits, withdrawals, and balance updates.
/// @dev This interface defines the necessary functions for interacting with the Vault.
/// @author imua-xyz
interface IVault {

    /// @notice Withdraws a specified amount from the vault.
    /// @param withdrawer The address initiating the withdrawal.
    /// @param recipient The address receiving the withdrawn amount.
    /// @param amount The amount to be withdrawn.
    function withdraw(address withdrawer, address recipient, uint256 amount) external;

    /// @notice Deposits a specified amount into the vault.
    /// @param depositor The address initiating the deposit.
    /// @param amount The amount to be deposited.
    function deposit(address depositor, uint256 amount) external;

    /// @notice Unlock and increase the withdrawable balance of a user for later withdrawal.
    /// @param staker The address of the staker whose principal balance is being unlocked.
    /// @param amount The amount of principal to be unlocked.
    function unlockPrincipal(address staker, uint256 amount) external;

    /// @notice Returns the address of the underlying token.
    /// @return The address of the underlying token.
    function getUnderlyingToken() external returns (address);

    /// @notice Sets the TVL limit for the vault.
    /// @param tvlLimit_ The new TVL limit for the vault.
    /// @dev It is possible to reduce or increase the TVL limit. Even if the consumed TVL limit is more than the new TVL
    /// limit, this transaction will go through and future deposits will be blocked until sufficient withdrawals are
    /// made.
    function setTvlLimit(uint256 tvlLimit_) external;

    /// @notice Gets the TVL limit for the vault.
    /// @return The TVL limit for the vault.
    // This is a function so that IVault can be used in other contracts without importing the Vault contract.
    function getTvlLimit() external returns (uint256);

    /// @notice Gets the total value locked in the vault.
    /// @return The total value locked in the vault.
    // This is a function so that IVault can be used in other contracts without importing the Vault contract.
    function getConsumedTvl() external returns (uint256);

}
