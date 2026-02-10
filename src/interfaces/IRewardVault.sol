// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRewardVault {

    /**
     * @notice Initializes the reward vault.
     * @param gateway_ The address of the gateway.
     */
    function initialize(address gateway_) external;

    /**
     * @notice Deposits a token into the reward vault.
     * @param token The address of the token to be deposited.
     * @param avs The avs ID to which the token is deposited.
     * @param amount The amount of the token to be deposited.
     */
    function deposit(address token, address depositor, address avs, uint256 amount) external;

    /**
     * @notice Withdraws a token from the reward vault.
     * @param token The address of the token to be withdrawn.
     * @param withdrawer The address of the withdrawer.
     * @param recipient The address of the recipient.
     * @param amount The amount of the token to be withdrawn.
     */
    function withdraw(address token, address withdrawer, address recipient, uint256 amount) external;

    /**
     * @notice Unlocks and increases the withdrawable balance of a user for later withdrawal.
     * @param token The address of the token to be unlocked.
     * @param withdrawer The address of the withdrawer.
     * @param amount The amount of the token to be unlocked.
     */
    function unlockReward(address token, address withdrawer, uint256 amount) external;

    /**
     * @notice Returns the withdrawable balance of a user.
     * @param token The address of the token.
     * @param withdrawer The address of the withdrawer.
     * @return The withdrawable balance of the user.
     */
    function getWithdrawableBalance(address token, address withdrawer) external view returns (uint256);

    /**
     * @notice Returns the locked reward balance for a token (amount deposited but not yet unlocked).
     * @param token The address of the token.
     * @return The locked reward balance for the token.
     */
    function getLockedRewards(address token) external view returns (uint256);

}
