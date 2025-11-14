pragma solidity ^0.8.19;

import {RewardVault} from "../../../src/core/RewardVault.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

contract MockERC20 is ERC20 {

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

}

contract MockGateway {}

contract RewardVaultTest is Test {

    RewardVault public rewardVaultImplementation;
    RewardVault public rewardVault;
    MockERC20 public token;
    MockGateway public gateway;
    address public depositor;
    address public withdrawer;
    address public avs;
    ProxyAdmin public proxyAdmin;

    event RewardDeposited(address indexed token, address indexed avs, uint256 amount);
    event RewardWithdrawn(address indexed token, address indexed withdrawer, address indexed recipient, uint256 amount);
    event RewardUnlocked(address indexed token, address indexed withdrawer, uint256 amount);

    function setUp() public {
        rewardVaultImplementation = new RewardVault();
        proxyAdmin = new ProxyAdmin();
        gateway = new MockGateway();

        // Deploy the proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(rewardVaultImplementation),
            address(proxyAdmin),
            abi.encodeWithSelector(RewardVault.initialize.selector, address(gateway))
        );

        // Cast the proxy to RewardVault
        rewardVault = RewardVault(address(proxy));

        token = new MockERC20("Test Token", "TEST");
        depositor = address(0x1);
        withdrawer = address(0x2);
        avs = address(0x3);

        bool fundedDepositor = token.transfer(depositor, 1000 * 10 ** 18);
        assertTrue(fundedDepositor, "token funding failed");
    }

    function testInitialize() public {
        assertEq(rewardVault.gateway(), address(gateway));
    }

    function testDeposit() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(rewardVault), amount);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit RewardDeposited(address(token), avs, amount);

        vm.prank(address(gateway));
        rewardVault.deposit(address(token), depositor, avs, amount);

        assertEq(token.balanceOf(address(rewardVault)), amount);
        assertEq(rewardVault.getTotalDepositedRewards(address(token), avs), amount);
    }

    function testWithdraw() public {
        uint256 amount = 100 * 10 ** 18;

        vm.prank(depositor);
        token.approve(address(rewardVault), amount);

        vm.prank(address(gateway));
        rewardVault.deposit(address(token), depositor, avs, amount);

        vm.prank(address(gateway));
        rewardVault.unlockReward(address(token), withdrawer, amount);

        vm.expectEmit(true, true, true, true);
        emit RewardWithdrawn(address(token), withdrawer, withdrawer, amount);

        vm.prank(address(gateway));
        rewardVault.withdraw(address(token), withdrawer, withdrawer, amount);

        assertEq(token.balanceOf(withdrawer), amount);
        assertEq(rewardVault.getWithdrawableBalance(address(token), withdrawer), 0);
    }

    function testUnlockReward() public {
        uint256 amount = 100 * 10 ** 18;

        vm.expectEmit(true, true, false, true);
        emit RewardUnlocked(address(token), withdrawer, amount);

        vm.prank(address(gateway));
        rewardVault.unlockReward(address(token), withdrawer, amount);

        assertEq(rewardVault.getWithdrawableBalance(address(token), withdrawer), amount);
    }

    function testGetWithdrawableBalance() public {
        uint256 amount = 100 * 10 ** 18;
        vm.prank(address(gateway));
        rewardVault.unlockReward(address(token), withdrawer, amount);

        assertEq(rewardVault.getWithdrawableBalance(address(token), withdrawer), amount);
    }

    function testGetTotalDepositedRewards() public {
        uint256 amount = 100 * 10 ** 18;
        vm.startPrank(depositor);
        token.approve(address(rewardVault), amount);
        vm.stopPrank();

        vm.prank(address(gateway));
        rewardVault.deposit(address(token), depositor, avs, amount);

        assertEq(rewardVault.getTotalDepositedRewards(address(token), avs), amount);
    }

    function testOnlyGatewayModifier() public {
        vm.prank(address(0x4));
        vm.expectRevert(Errors.VaultCallerIsNotGateway.selector);
        rewardVault.deposit(address(token), depositor, avs, 100 * 10 ** 18);
        vm.expectRevert(Errors.VaultCallerIsNotGateway.selector);
        rewardVault.withdraw(address(token), withdrawer, withdrawer, 100 * 10 ** 18);
        vm.expectRevert(Errors.VaultCallerIsNotGateway.selector);
        rewardVault.unlockReward(address(token), withdrawer, 100 * 10 ** 18);
    }

    function testWithdrawInsufficientBalance() public {
        vm.prank(address(gateway));
        vm.expectRevert(Errors.InsufficientBalance.selector);
        rewardVault.withdraw(address(token), withdrawer, withdrawer, 100 * 10 ** 18);
    }

    function testWithdrawVaultInsufficientTokenBalance() public {
        uint256 amount = 100 * 10 ** 18;
        vm.prank(address(gateway));
        rewardVault.unlockReward(address(token), withdrawer, amount);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(address(gateway));
        rewardVault.withdraw(address(token), withdrawer, withdrawer, amount);
    }

}
