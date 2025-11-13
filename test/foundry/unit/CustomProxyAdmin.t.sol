// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICustomProxyAdmin} from "src/interfaces/ICustomProxyAdmin.sol";

import {Errors} from "src/libraries/Errors.sol";
import {CustomProxyAdmin} from "src/utils/CustomProxyAdmin.sol";

import "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/* ---- Storage contracts ---- */
contract StorageA {

    uint256 public a;

}

contract StorageB is StorageA {

    uint256 public b;

}

contract StorageC is StorageB {

    uint256 public c;

}

/* ---- Base implementation contract ---- */
abstract contract ImplementationChanger {

    function upgradeSelfToAndCall(address customProxyAdmin, address newImplementation) public {
        ICustomProxyAdmin(customProxyAdmin).upgradeSelfToAndCall(
            newImplementation, abi.encodeCall(ImplementationChanger.initialize, ())
        );
    }

    function initialize() external virtual;

}

/* ---- Implementation contracts ---- */
// We use the same logic as Bootstrap and ClientChainGateway in the sense that
// the downstream contracts inherit from their respective storage and not from the parent impl
// We just use one common parent impl to avoid rewriting the code for the upgrade function.
contract ImplementationA is Initializable, StorageA, ImplementationChanger {

    constructor() {
        _disableInitializers();
    }

    function initialize() external virtual override initializer {
        a = 1;
    }

}

contract ImplementationB is Initializable, StorageB, ImplementationChanger {

    constructor() {
        _disableInitializers();
    }

    function initialize() external virtual override reinitializer(2) {
        a = 2;
        b = 1;
    }

}

contract ImplementationC is Initializable, StorageC, ImplementationChanger {

    constructor() {
        _disableInitializers();
    }

    function initialize() external virtual override reinitializer(3) {
        a = 3;
        b = 2;
        c = 1;
    }

}

contract CustomProxyAdminTest is Test {

    enum Stage {
        A,
        B,
        C
    }

    CustomProxyAdmin proxyAdmin;
    ImplementationA implementationA;
    address targetImpl;

    function setUp() public {
        proxyAdmin = new CustomProxyAdmin();
        ImplementationA logic = new ImplementationA();
        implementationA = ImplementationA(
            address(
                new TransparentUpgradeableProxy(
                    address(logic), address(proxyAdmin), abi.encodeCall(ImplementationA.initialize, ())
                )
            )
        );
        // construct the new implementation for the tests
        targetImpl = address(new ImplementationB());
        // validate that the implementation has not changed
        _validate(Stage.A);
    }

    function _initialize(address x) private {
        proxyAdmin.initialize(x);
    }

    function _validate(Stage stage) private {
        if (stage == Stage.A) {
            assertTrue(implementationA.a() == 1);
            vm.expectRevert();
            uint256 b = ImplementationB(address(implementationA)).b();
            vm.expectRevert();
            uint256 c = ImplementationC(address(implementationA)).c();
        } else if (stage == Stage.B) {
            assertTrue(implementationA.a() == 2);
            assertTrue(ImplementationB(address(implementationA)).b() == 1);
            vm.expectRevert();
            uint256 c = ImplementationC(address(implementationA)).c();
        } else if (stage == Stage.C) {
            assertTrue(implementationA.a() == 3);
            assertTrue(ImplementationB(address(implementationA)).b() == 2);
            assertTrue(ImplementationC(address(implementationA)).c() == 1);
        } else {
            revert("Invalid stage");
        }
    }

    function test01_Initialize() public {
        // check that 0 cannot be used
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        _initialize(address(0x0));
        // validate successful initialization for a new contract
        address proxy = address(0x123);
        _initialize(proxy);
        assertEq(proxyAdmin.proxy(), proxy);
        // validate that it cannot be initialized again
        vm.expectRevert("Initializable: contract is already initialized");
        proxyAdmin.initialize(address(0x1));
    }

    function test02_ChangeImplementation() public {
        _initialize(address(implementationA));
        implementationA.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        _validate(Stage.B);
    }

    function test02_ChangeImplementation_NoProxySet() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.CustomProxyAdminNoProxySet.selector));
        implementationA.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        _validate(Stage.A);
    }

    function test02_ChangeImplementation_UnmanagedProxy() public {
        _initialize(address(0x1));
        vm.expectRevert(abi.encodeWithSelector(Errors.CustomProxyAdminUnmanagedProxy.selector));
        implementationA.upgradeSelfToAndCall(address(proxyAdmin), targetImpl);
        _validate(Stage.A);
    }

    function test03_ChangeImplementation_MultipleUpgrades() public {
        test02_ChangeImplementation();
        // now try to do a new upgrade
        ImplementationC target = new ImplementationC();
        vm.expectRevert();
        implementationA.upgradeSelfToAndCall(address(proxyAdmin), address(target));
        // validate that we are at stage B not C even though we tried to upgrade to C
        _validate(Stage.B);
    }

}
