// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ITokenWhitelister
/// @author imua-xyz
/// @notice An interface for the TokenWhitelister contract that allows whitelisting and obtaining
/// the count of whitelisted tokens.
interface ITokenWhitelister {

    /// @notice Adds a list of whitelisted tokens.
    /// @param tokens The list of token addresses to be whitelisted.
    /// @param tvlLimits The list of TVL limits for the corresponding tokens.
    function addWhitelistTokens(address[] calldata tokens, uint256[] calldata tvlLimits) external;

    /// @notice Gets the count of whitelisted tokens.
    /// @return The count of whitelisted tokens.
    function getWhitelistedTokensCount() external returns (uint256);

    /// @notice Updates the TVL limit for a token.
    /// @dev The token must be whitelisted before.
    /// @param token The token address.
    /// @param tvlLimit The new TVL limit for the token.
    function updateTvlLimit(address token, uint256 tvlLimit) external;

}
