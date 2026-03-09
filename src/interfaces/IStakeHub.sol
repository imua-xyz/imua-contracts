// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStakeHub
/// @notice Minimal interface for BNB staking delegation on BSC-like chains.
/// @dev The real StakeHub / staking system contract may differ across networks.
/// This interface is intentionally minimal and can be adapted per deployment via a custom implementation.
interface IStakeHub {

    /// @notice Delegate native token (BNB) to a validator.
    /// @param operatorAddress The validator/operator address to delegate to.
    /// @param delegateVotePower Whether to delegate governance voting power to the validator.
    function delegate(address operatorAddress, bool delegateVotePower) external payable;

    /// @notice Undelegate native token (BNB) from a validator.
    /// @param validator The validator/operator address to undelegate from.
    /// @param amount The amount to undelegate.
    function undelegate(address validator, uint256 amount) external;

    /// @notice Returns the per-validator credit contract address.
    function getValidatorCreditContract(address operatorAddress) external view returns (address);

    /// @notice Claim unbonded BNB for a validator.
    /// @dev requestNumber==0 claims all available unbond requests for that validator.
    function claim(address operatorAddress, uint256 requestNumber) external;

}
