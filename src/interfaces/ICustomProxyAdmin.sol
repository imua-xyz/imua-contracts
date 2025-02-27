// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ICustomProxyAdmin
/// @author imua-xyz
/// @notice ICustomProxyAdmin provides a set of functions for custom proxy admin operations.
/// The additional function, beyond the standard OpenZeppelin ProxyAdmin, is changeImplementation.
interface ICustomProxyAdmin {

    /// @notice Changes the implementation of a proxy.
    /// @param proxy The address of the proxy to change the implementation of.
    /// @param implementation The address of the new implementation.
    /// @param data The data to send to the new implementation.
    /// @dev This function is only callable by the proxy itself to upgrade itself.
    function changeImplementation(ITransparentUpgradeableProxy proxy, address implementation, bytes memory data)
        external;

}
