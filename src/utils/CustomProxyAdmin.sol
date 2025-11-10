// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ICustomProxyAdmin} from "../interfaces/ICustomProxyAdmin.sol";
import {Errors} from "../libraries/Errors.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title CustomProxyAdmin
/// @author imua-xyz
/// @notice CustomProxyAdmin is a custom implementation of ProxyAdmin that allows a proxy contract to upgrade its own
/// implementation.
/// @dev This contract is not upgradeable intentionally, since doing so would produce a lot of risk.
contract CustomProxyAdmin is Initializable, ProxyAdmin, ICustomProxyAdmin {

    /// @notice The address of the proxy which will upgrade itself.
    /// @dev We only support one such upgrade throughout the lifetime of the contract, and
    /// for only one proxy. This is for simplicity; we don't need support for multiple upgrades
    /// or proxies.
    address public proxy;

    constructor() {
        // this contract is not upgradeable, so do not call disableInitializers here.
        // the inheritance from Initializable is not used for upgradeability, instead,
        // it is used to prevent multiple initializations.
    }

    /// @notice Initializes the CustomProxyAdmin contract.
    /// @param proxy_ The address of the proxy which will upgrade itself.
    function initialize(address proxy_) external initializer onlyOwner {
        if (proxy_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        proxy = proxy_;
    }

    /// @notice Changes the implementation of the calling contract, provided it is the `proxy`.
    /// @param implementation The address of the new implementation contract.
    /// @param data The data to be passed to the new implementation contract.
    /// @dev This function can only be called by the proxy to upgrade itself, exactly once.
    function upgradeSelfToAndCall(address implementation, bytes calldata data) public virtual {
        if (proxy == address(0)) {
            revert Errors.CustomProxyAdminNoProxySet();
        }
        // only the `proxy` can call this function to upgrade itself
        if (msg.sender != proxy) {
            revert Errors.CustomProxyAdminOnlyCalledFromThis();
        }
        // we follow check-effects-interactions pattern to write state before external call
        address proxy_ = proxy;
        // prevent reentrancy by resetting the proxy
        proxy = address(0);
        ITransparentUpgradeableProxy(proxy_).upgradeToAndCall(implementation, data);
    }

}
