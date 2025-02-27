pragma solidity ^0.8.19;

import "../../src/core/ImuaCapsule.sol";
import "../../src/core/ImuachainGateway.sol";

import {IImuaCapsule} from "../../src/interfaces/IImuaCapsule.sol";
import {ILSTRestakingController} from "../../src/interfaces/ILSTRestakingController.sol";

import "../../src/storage/GatewayStorage.sol";
import "./ImuachainDeployer.t.sol";
import "forge-std/Test.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

contract TvlLimitsTest is ImuachainDeployer {

    event TvlLimitUpdated(uint256 newTvlLimit);

    function setUp() public virtual override {
        super.setUp();
        test_AddWhitelistTokens();
    }

    // for a token that is not whitelisted, nothing should happen
    function test07_UpdateTvlLimit_NotWhitelisted() public {
        address addr = address(0xa);
        vm.startPrank(owner.addr);
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotWhitelisted.selector, addr));
        clientGateway.updateTvlLimit(addr, 500);
        vm.stopPrank();
    }

    // native restaking does not have a TVL limit
    function test07_UpdateTvlLimit_NativeEth() public {
        vm.startPrank(owner.addr);
        vm.expectRevert(Errors.NoTvlLimitForNativeRestaking.selector);
        clientGateway.updateTvlLimit(VIRTUAL_STAKED_ETH_ADDRESS, 500);
        vm.stopPrank();
    }

    function test07_UpdateTvlLimit_NotOwner() public {
        IVault vault = clientGateway.tokenToVault(address(restakeToken));
        assertTrue(address(vault) != address(0));
        uint256 originalLimit = vault.getTvlLimit();
        vm.expectRevert("Ownable: caller is not the owner");
        clientGateway.updateTvlLimit(address(restakeToken), originalLimit * 2);
        assertTrue(vault.getTvlLimit() == originalLimit);
    }

    function test07_UpdateTvlLimit_Paused() public {
        vm.startPrank(owner.addr);
        clientGateway.pause();
        IVault vault = clientGateway.tokenToVault(address(restakeToken));
        assertTrue(address(vault) != address(0));
        uint256 originalLimit = vault.getTvlLimit();
        vm.expectRevert("Pausable: paused");
        clientGateway.updateTvlLimit(address(restakeToken), originalLimit * 2);
        assertTrue(vault.getTvlLimit() == originalLimit);
    }

    // whitelist tokens should be added before updating tvl limits
    function test08_AddWhitelistTokens_NotPermitted() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(restakeToken);
        uint256[] memory tvlLimits = new uint256[](1);
        tvlLimits[0] = 500;
        vm.startPrank(owner.addr);
        vm.expectRevert(Errors.ClientChainGatewayTokenAdditionViaImuachain.selector);
        clientGateway.addWhitelistTokens(tokens, tvlLimits);
    }

    // tvlLimit increases or decreases are both permitted
    function test07_IncreaseTvlLimit() public {
        uint256 factor = 2;
        IVault vault = clientGateway.tokenToVault(address(restakeToken));
        assertTrue(address(vault) != address(0));
        uint256 tvlLimit = vault.getTvlLimit();
        uint256 proposedTvlLimit = tvlLimit * factor;
        vm.startPrank(owner.addr);
        vm.expectEmit(address(vault));
        emit TvlLimitUpdated(proposedTvlLimit);
        clientGateway.updateTvlLimit(address(restakeToken), proposedTvlLimit);
        assertTrue(vault.getTvlLimit() == proposedTvlLimit);
    }

    // tvlLimit increases or decreases are both permitted
    function test07_DecreaseTvlLimit() public {
        uint256 factor = 2;
        IVault vault = clientGateway.tokenToVault(address(restakeToken));
        assertTrue(address(vault) != address(0));
        uint256 tvlLimit = vault.getTvlLimit();
        uint256 proposedTvlLimit = tvlLimit / factor;
        vm.startPrank(owner.addr);
        vm.expectEmit(address(vault));
        emit TvlLimitUpdated(proposedTvlLimit);
        clientGateway.updateTvlLimit(address(restakeToken), proposedTvlLimit);
        assertTrue(vault.getTvlLimit() == proposedTvlLimit);
    }

}
