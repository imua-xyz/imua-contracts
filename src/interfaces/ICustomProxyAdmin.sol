// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ICustomProxyAdmin
/// @author imua-xyz
/// @notice ICustomProxyAdmin provides a set of functions for custom proxy admin operations.
/// The additional function, beyond the standard OpenZeppelin ProxyAdmin, is changeImplementation.
interface ICustomProxyAdmin {

    /// @notice Changes the implementation of a proxy.
    /// @param implementation The address of the new implementation.
    /// @param data The data to send to the new implementation.
    /// @dev This function is only callable by the proxy itself to upgrade itself.
    function upgradeSelfToAndCall(address implementation, bytes memory data) external;

}
