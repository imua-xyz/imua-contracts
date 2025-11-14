pragma solidity ^0.8.19;

import {Vault} from "../../../src/core/Vault.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

contract MockERC20 is ERC20 {

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1e10 * 10 ** 18);
    }

}

contract MockGateway {}

contract VaultTest is Test {

    Vault public vaultImplementation;
    Vault public vault;
    MockERC20 public token;
    MockGateway public gateway;
    ProxyAdmin public proxyAdmin;
    address public depositor;
    address public withdrawer;
    uint256 public constant TVL_LIMIT = 1_000_000 * 10 ** 18;

    event ConsumedTvlChanged(uint256 newConsumedTvl);
    event PrincipalDeposited(address indexed depositor, uint256 amount);
    event PrincipalWithdrawn(address indexed withdrawer, address indexed recipient, uint256 amount);
    event PrincipalUnlocked(address indexed user, uint256 amount);
    event TvlLimitUpdated(uint256 newTvlLimit);

    function setUp() public {
        vaultImplementation = new Vault();
        proxyAdmin = new ProxyAdmin();
        token = new MockERC20("Test Token", "TEST");
        gateway = new MockGateway();
        depositor = address(0x1);
        withdrawer = address(0x2);

        // Deploy the proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            address(proxyAdmin),
            abi.encodeWithSelector(Vault.initialize.selector, address(token), TVL_LIMIT, address(gateway))
        );

        // Cast the proxy to Vault
        vault = Vault(address(proxy));

        bool fundedDepositor = token.transfer(depositor, TVL_LIMIT + 1000 * 10 ** 18); // Give enough tokens to exceed
        // TVL
        assertTrue(fundedDepositor, "token funding failed");
    }

    function testInitialize() public {
        assertEq(vault.getUnderlyingToken(), address(token));
        assertEq(vault.getTvlLimit(), TVL_LIMIT);
        assertEq(address(vault.gateway()), address(gateway));
    }

    function testDeposit() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vm.expectEmit(false, false, false, true);
        emit ConsumedTvlChanged(amount);
        vm.expectEmit(true, false, false, true);
        emit PrincipalDeposited(depositor, amount);
        vault.deposit(depositor, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(vault.totalDepositedPrincipalAmount(depositor), amount);
        assertEq(vault.getConsumedTvl(), amount);
    }

    function testWithdraw() public {
        uint256 amount = 100 * 10 ** 18;

        bool fundedWithdrawer = token.transfer(withdrawer, amount); // Give enough tokens to exceed TVL
        assertTrue(fundedWithdrawer, "token funding failed");

        vm.startPrank(withdrawer);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vault.deposit(withdrawer, amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vault.unlockPrincipal(withdrawer, amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vm.expectEmit(false, false, false, true);
        emit ConsumedTvlChanged(0);
        vm.expectEmit(true, true, false, true);
        emit PrincipalWithdrawn(withdrawer, withdrawer, amount);
        vault.withdraw(withdrawer, withdrawer, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(withdrawer), amount);
        assertEq(vault.getWithdrawableBalance(withdrawer), 0);
        assertEq(vault.getConsumedTvl(), 0);
    }

    function testUnlockPrincipal() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vault.deposit(depositor, amount);
        vm.expectEmit(true, false, false, true);
        emit PrincipalUnlocked(depositor, amount);
        vault.unlockPrincipal(depositor, amount);
        vm.stopPrank();

        assertEq(vault.getWithdrawableBalance(depositor), amount);
    }

    function testSetTvlLimit() public {
        uint256 newLimit = 2_000_000 * 10 ** 18;
        vm.startPrank(address(gateway));
        vm.expectEmit(false, false, false, true);
        emit TvlLimitUpdated(newLimit);
        vault.setTvlLimit(newLimit);
        vm.stopPrank();

        assertEq(vault.getTvlLimit(), newLimit);
    }

    function testOnlyGatewayModifier() public {
        vm.expectRevert(Errors.VaultCallerIsNotGateway.selector);
        vault.deposit(depositor, 100 * 10 ** 18);
    }

    function testDepositExceedsTvlLimit() public {
        uint256 amount = TVL_LIMIT + 1;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        vault.deposit(depositor, amount);
        vm.stopPrank();
    }

    function testWithdrawExceedsBalance() public {
        vm.startPrank(address(gateway));
        vm.expectRevert(Errors.VaultWithdrawalAmountExceeds.selector);
        vault.withdraw(withdrawer, withdrawer, 1);
        vm.stopPrank();
    }

    function testUnlockPrincipalExceedsTotalDeposit() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vault.deposit(depositor, amount);
        vm.expectRevert(Errors.VaultPrincipalExceedsTotalDeposit.selector);
        vault.unlockPrincipal(depositor, amount + 1);
        vm.stopPrank();
    }

    function testTotalUnlockPrincipalExceedsDeposit() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vm.stopPrank();

        vm.startPrank(address(gateway));
        vault.deposit(depositor, amount);
        vault.unlockPrincipal(depositor, amount / 2);
        vm.expectRevert(Errors.VaultTotalUnlockPrincipalExceedsDeposit.selector);
        vault.unlockPrincipal(depositor, (amount / 2) + 1);
        vm.stopPrank();
    }

}
