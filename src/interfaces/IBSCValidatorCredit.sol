// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IBSCValidatorCredit
/// @notice Minimal interface for per-validator credit contract on BSC.
/// @dev Each validator has its own credit contract tracking delegators' locked + pooled BNB.
interface IBSCValidatorCredit {

    /// @notice Returns how many unbond requests are claimable now.
    function claimableUnbondRequest(address delegator) external view returns (uint256);

    /// @notice Sum of locked BNBs in delegator's unbonding queue.
    /// @dev `number==0` returns total locked BNBs.
    function lockedBNBs(address delegator, uint256 number) external view returns (uint256);

    /// @notice Current pooled BNB for delegator.
    function getPooledBNB(address delegator) external view returns (uint256);

}

