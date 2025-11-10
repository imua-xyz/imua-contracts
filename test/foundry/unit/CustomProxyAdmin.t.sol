// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICustomProxyAdmin} from "src/interfaces/ICustomProxyAdmin.sol";

import {Errors} from "src/libraries/Errors.sol";
import {CustomProxyAdmin} from "src/utils/CustomProxyAdmin.sol";

import "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract StorageOld {

    bool public implementationChanged;

}

contract StorageNew is StorageOld {

    bool public hi;

}

contract ImplementationChanger is Initializable, StorageOld {

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        implementationChanged = false;
    }

    function upgradeSelfToAndCall(address customProxyAdmin, address newImplementation) public {
        ICustomProxyAdmin(customProxyAdmin).upgradeSelfToAndCall(
            newImplementation, abi.encodeCall(ImplementationChanger.initialize, ())
        );
    }

}

contract NewImplementation is Initializable, StorageNew {

    constructor() {
        _disableInitializers();
    }

    function initialize() external reinitializer(2) {
        implementationChanged = true;
        hi = true;
    }

}

contract CustomProxyAdminTest is Test {

    CustomProxyAdmin proxyAdmin;

    function setUp() public {
        proxyAdmin = new CustomProxyAdmin();
    }

    function test01_Initialize() public {
        address proxy = address(0x123);
        proxyAdmin.initialize(proxy);
        assertEq(proxyAdmin.proxy(), proxy);

        vm.expectRevert();
        proxyAdmin.initialize(address(0x1));
    }

    function test02_ChangeImplementation() public {
        // initialize the contract
        ImplementationChanger implementationChanger = ImplementationChanger(
            address(
                new TransparentUpgradeableProxy(
                    address(new ImplementationChanger()),
                    address(proxyAdmin),
                    abi.encodeCall(ImplementationChanger.initialize, ())
                )
            )
        );
        // validate that the implementation has not changed already
        assertFalse(implementationChanger.implementationChanged());
        // check that it does not have a `hi` function in there.
        NewImplementation newImplementation = NewImplementation(address(implementationChanger));
        vm.expectRevert(); // EVM error
        assertFalse(newImplementation.hi());
        // now change the implementation
        address targetImpl = address(new NewImplementation());
        proxyAdmin.initialize(address(implementationChanger));
        implementationChanger.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        // validate that it has changed
        assertTrue(implementationChanger.implementationChanged());
        assertTrue(newImplementation.hi());
    }

    function test02_ChangeImplementation_NoProxySet() public {
        // initialize the contract
        ImplementationChanger implementationChanger = ImplementationChanger(
            address(
                new TransparentUpgradeableProxy(
                    address(new ImplementationChanger()),
                    address(proxyAdmin),
                    abi.encodeCall(ImplementationChanger.initialize, ())
                )
            )
        );
        // validate that the implementation has not changed already
        assertFalse(implementationChanger.implementationChanged());
        address targetImpl = address(new NewImplementation());
        vm.expectRevert(abi.encodeWithSelector(Errors.CustomProxyAdminNoProxySet.selector));
        implementationChanger.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        assertFalse(implementationChanger.implementationChanged());
    }

    function test02_ChangeImplementation_UnmanagedProxy() public {
        // initialize the contract
        ImplementationChanger implementationChanger = ImplementationChanger(
            address(
                new TransparentUpgradeableProxy(
                    address(new ImplementationChanger()),
                    address(proxyAdmin),
                    abi.encodeCall(ImplementationChanger.initialize, ())
                )
            )
        );
        // set a random proxy
        address randomProxy = address(0x123);
        proxyAdmin.initialize(randomProxy);
        // validate that the implementation has not changed already
        assertFalse(implementationChanger.implementationChanged());
        address targetImpl = address(new NewImplementation());
        vm.expectRevert(abi.encodeWithSelector(Errors.CustomProxyAdminUnmanagedProxy.selector));
        implementationChanger.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        assertFalse(implementationChanger.implementationChanged());
    }

}
