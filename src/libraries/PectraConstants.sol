// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title PectraConstants
/// @notice Constants for Pectra hard fork and EIP-7002 beacon withdrawal functionality
/// @author imua-xyz
library PectraConstants {

    /// @notice The address of the Beacon Withdrawal Precompile (EIP-7002)
    address internal constant BEACON_WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;

    /// @notice Constants for EIP-7002 withdrawal requests
    uint256 internal constant PUBKEY_LENGTH = 48;
    uint256 internal constant AMOUNT_LENGTH = 8;
    uint256 internal constant CALLDATA_LENGTH = 56; // PUBKEY_LENGTH + AMOUNT_LENGTH
    uint256 internal constant MIN_WITHDRAWAL_FEE = 1 wei;
    uint256 internal constant FEE_RESPONSE_LENGTH = 32; // Length of fee response from precompile

}
