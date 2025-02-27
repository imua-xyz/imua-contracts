// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ImuachainBytes {

    /// @notice Converts an Ethereum address to Imuachain's 32-byte address format
    /// @param addr The Ethereum address to convert
    /// @return The address as 32-byte Imuachain format (20 bytes + right padding)
    function toImuachainBytes(address addr) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(bytes20(addr)));
    }

}
