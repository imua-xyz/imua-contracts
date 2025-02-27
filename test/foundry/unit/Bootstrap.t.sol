// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bootstrap} from "src/core/Bootstrap.sol";

import {ClientChainGateway} from "src/core/ClientChainGateway.sol";
import {BootstrapStorage} from "src/storage/BootstrapStorage.sol";

import {Vault} from "src/core/Vault.sol";
import {CustomProxyAdmin} from "src/utils/CustomProxyAdmin.sol";

import {IETHPOSDeposit} from "src/interfaces/IETHPOSDeposit.sol";
import {IValidatorRegistry} from "src/interfaces/IValidatorRegistry.sol";

import {NonShortCircuitEndpointV2Mock} from "../../mocks/NonShortCircuitEndpointV2Mock.sol";
import {MyToken} from "./MyToken.sol";

import {RewardVault} from "src/core/RewardVault.sol";
import {IRewardVault} from "src/interfaces/IRewardVault.sol";
import {IVault} from "src/interfaces/IVault.sol";

import {Origin} from "src/lzApp/OAppReceiverUpgradeable.sol";
import {BootstrapStorage} from "src/storage/BootstrapStorage.sol";
import {Action, GatewayStorage} from "src/storage/GatewayStorage.sol";

import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import "src/libraries/Errors.sol";

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import "@openzeppelin/contracts/utils/Create2.sol";

import "forge-std/Test.sol";
import "src/libraries/Errors.sol";

import "src/core/ImuaCapsule.sol";
import "src/storage/GatewayStorage.sol";
import "src/utils/BeaconProxyBytecode.sol";

contract BootstrapTest is Test {

    using stdStorage for StdStorage;

    MyToken myToken;
    CustomProxyAdmin proxyAdmin;
    Bootstrap bootstrap;
    Bootstrap bootstrapLogic;
    address[] addrs = new address[](6);
    uint256[] amounts = [
        35 * 10 ** 18, // self
        25 * 10 ** 18, // self
        10 * 10 ** 18, // self
        17 * 10 ** 18, // 8 + 9 + 0
        15 * 10 ** 18, // 0 + 7 + 8
        8 * 10 ** 18 // 2 + 0 + 6
    ];
    address deployer = address(0xdeadbeef);
    uint256 spawnTime;
    uint256 offsetDuration;
    uint16 imuachainChainId = 1;
    uint16 clientChainId = 2;
    address[] whitelistTokens;
    uint256[] tvlLimits;
    NonShortCircuitEndpointV2Mock clientChainLzEndpoint;
    address owner = vm.addr(uint256(0x8));
    address undeployedImuachainGateway = vm.addr(uint256(0x9));
    address undeployedImuachainLzEndpoint = vm.addr(uint256(0xb));
    address constant lzActor = address(0x20);

    IVault vaultImplementation;
    IRewardVault rewardVaultImplementation;
    IImuaCapsule capsuleImplementation;
    IBeacon vaultBeacon;
    IBeacon rewardVaultBeacon;
    IBeacon capsuleBeacon;
    BeaconProxyBytecode beaconProxyBytecode;

    address internal constant VIRTUAL_STAKED_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @dev The address of the ETHPOS deposit contract.
    IETHPOSDeposit internal constant ETH_POS = IETHPOSDeposit(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    bytes constant BEACON_PROXY_BYTECODE =
        hex"608060405260405161090e38038061090e83398101604081905261002291610460565b61002e82826000610035565b505061058a565b61003e83610100565b6040516001600160a01b038416907f1cf3b03a6cf19fa2baba4df148e9dcabedea7f8a5c07840e207e5c089be95d3e90600090a260008251118061007f5750805b156100fb576100f9836001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100c5573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100e99190610520565b836102a360201b6100291760201c565b505b505050565b610113816102cf60201b6100551760201c565b6101725760405162461bcd60e51b815260206004820152602560248201527f455243313936373a206e657720626561636f6e206973206e6f74206120636f6e6044820152641d1c9858dd60da1b60648201526084015b60405180910390fd5b6101e6816001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156101b3573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906101d79190610520565b6102cf60201b6100551760201c565b61024b5760405162461bcd60e51b815260206004820152603060248201527f455243313936373a20626561636f6e20696d706c656d656e746174696f6e206960448201526f1cc81b9bdd08184818dbdb9d1c9858dd60821b6064820152608401610169565b806102827fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d5060001b6102de60201b6100641760201c565b80546001600160a01b0319166001600160a01b039290921691909117905550565b60606102c883836040518060600160405280602781526020016108e7602791396102e1565b9392505050565b6001600160a01b03163b151590565b90565b6060600080856001600160a01b0316856040516102fe919061053b565b600060405180830381855af49150503d8060008114610339576040519150601f19603f3d011682016040523d82523d6000602084013e61033e565b606091505b5090925090506103508683838761035a565b9695505050505050565b606083156103c65782516103bf576001600160a01b0385163b6103bf5760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e74726163740000006044820152606401610169565b50816103d0565b6103d083836103d8565b949350505050565b8151156103e85781518083602001fd5b8060405162461bcd60e51b81526004016101699190610557565b80516001600160a01b038116811461041957600080fd5b919050565b634e487b7160e01b600052604160045260246000fd5b60005b8381101561044f578181015183820152602001610437565b838111156100f95750506000910152565b6000806040838503121561047357600080fd5b61047c83610402565b60208401519092506001600160401b038082111561049957600080fd5b818501915085601f8301126104ad57600080fd5b8151818111156104bf576104bf61041e565b604051601f8201601f19908116603f011681019083821181831017156104e7576104e761041e565b8160405282815288602084870101111561050057600080fd5b610511836020830160208801610434565b80955050505050509250929050565b60006020828403121561053257600080fd5b6102c882610402565b6000825161054d818460208701610434565b9190910192915050565b6020815260008251806020840152610576816040850160208701610434565b601f01601f19169190910160400192915050565b61034e806105996000396000f3fe60806040523661001357610011610017565b005b6100115b610027610022610067565b610100565b565b606061004e83836040518060600160405280602781526020016102f260279139610124565b9392505050565b6001600160a01b03163b151590565b90565b600061009a7fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50546001600160a01b031690565b6001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100d7573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100fb9190610249565b905090565b3660008037600080366000845af43d6000803e80801561011f573d6000f35b3d6000fd5b6060600080856001600160a01b03168560405161014191906102a2565b600060405180830381855af49150503d806000811461017c576040519150601f19603f3d011682016040523d82523d6000602084013e610181565b606091505b50915091506101928683838761019c565b9695505050505050565b6060831561020d578251610206576001600160a01b0385163b6102065760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e747261637400000060448201526064015b60405180910390fd5b5081610217565b610217838361021f565b949350505050565b81511561022f5781518083602001fd5b8060405162461bcd60e51b81526004016101fd91906102be565b60006020828403121561025b57600080fd5b81516001600160a01b038116811461004e57600080fd5b60005b8381101561028d578181015183820152602001610275565b8381111561029c576000848401525b50505050565b600082516102b4818460208701610272565b9190910192915050565b60208152600082518060208401526102dd816040850160208701610272565b601f01601f1916919091016040019291505056fe416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564a2646970667358221220d51e81d3bc5ed20a26aeb05dce7e825c503b2061aa78628027300c8d65b9d89a64736f6c634300080c0033416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564";

    function setUp() public {
        vm.chainId(1); // set chainid to 1 so that capsule implementation can use default network constants
        addrs[0] = address(0x1); // Simulated VALIDATOR1 address
        addrs[1] = address(0x2); // Simulated VALIDATOR2 address
        addrs[2] = address(0x3); // Simulated VALIDATOR3 address
        addrs[3] = address(0x4); // Simulated STAKER1 address
        addrs[4] = address(0x5); // Simulated STAKER2 address
        addrs[5] = address(0x6); // Simulated STAKER3 address

        vm.startPrank(deployer);
        // first deploy the token
        myToken = new MyToken("MyToken", "MYT", 18, addrs, 1000 * 10 ** 18);
        whitelistTokens.push(address(myToken));
        tvlLimits.push(myToken.totalSupply() / 20);

        // deploy vault implementationcontract that has logics called by proxy
        vaultImplementation = new Vault();
        rewardVaultImplementation = new RewardVault();
        capsuleImplementation = new ImuaCapsule(address(0));

        // deploy the vault beacon that store the implementation contract address
        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));

        // deploy BeaconProxyBytecode to store BeaconProxyBytecode
        beaconProxyBytecode = new BeaconProxyBytecode();

        // then the ProxyAdmin
        proxyAdmin = new CustomProxyAdmin();
        // then the logic
        clientChainLzEndpoint = new NonShortCircuitEndpointV2Mock(clientChainId, owner);
        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);

        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));
        // we could also use encodeWithSelector and supply .initialize.selector instead.
        bytes memory initialization = abi.encodeCall(clientGatewayLogic.initialize, (payable(owner)));
        // then the params + proxy
        spawnTime = block.timestamp + 1 hours;
        offsetDuration = 30 minutes;
        bootstrap = Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(clientGatewayLogic),
                                initialization
                            )
                        )
                    )
                )
            )
        );
        // validate the initialization
        assertTrue(bootstrap.isWhitelistedToken(address(myToken)));
        assertFalse(bootstrap.isWhitelistedToken(address(0xa)));
        assertTrue(bootstrap.getWhitelistedTokensCount() == 1);
        assertFalse(bootstrap.bootstrapped());
        proxyAdmin.initialize(address(bootstrap));
        // deployer is the owner
        address expectedVaultAddress = Create2.computeAddress(
            bytes32(uint256(uint160(address(myToken)))),
            keccak256(abi.encodePacked(BEACON_PROXY_BYTECODE, abi.encode(address(vaultBeacon), ""))),
            address(bootstrap)
        );
        IVault vault = bootstrap.tokenToVault(address(myToken));
        assertTrue(address(vault) == expectedVaultAddress);
        assertTrue(vault.getTvlLimit() == tvlLimits[0]);
        // now set the gateway address for Imuachain.
        clientChainLzEndpoint.setDestLzEndpoint(undeployedImuachainGateway, undeployedImuachainLzEndpoint);
        bootstrap.setPeer(imuachainChainId, bytes32(bytes20(undeployedImuachainGateway)));
        vm.stopPrank();
    }

    function test01_AddWhitelistToken() public returns (MyToken) {
        vm.startPrank(deployer);
        MyToken myTokenClone = new MyToken("MyToken", "MYT", 18, addrs, 1000 * 10 ** 18);
        address[] memory addedWhitelistTokens = new address[](1);
        addedWhitelistTokens[0] = address(myTokenClone);
        uint256[] memory addedTvlLimits = new uint256[](1);
        addedTvlLimits[0] = myTokenClone.totalSupply() / 40;
        bootstrap.addWhitelistTokens(addedWhitelistTokens, addedTvlLimits);
        vm.stopPrank();
        assertTrue(bootstrap.isWhitelistedToken(address(myTokenClone)));
        assertTrue(bootstrap.getWhitelistedTokensCount() == 2);
        address expectedVaultAddress = Create2.computeAddress(
            bytes32(uint256(uint160(address(myTokenClone)))),
            keccak256(abi.encodePacked(BEACON_PROXY_BYTECODE, abi.encode(address(vaultBeacon), ""))),
            address(bootstrap)
        );
        IVault vault = bootstrap.tokenToVault(address(myTokenClone));
        assertTrue(address(vault) == expectedVaultAddress);
        assertTrue(vault.getTvlLimit() == addedTvlLimits[0]);
        return myTokenClone;
    }

    function test01_AddWhitelistToken_AlreadyExists() public {
        vm.startPrank(deployer);
        address[] memory addedWhitelistTokens = new address[](1);
        addedWhitelistTokens[0] = address(myToken);
        uint256[] memory addedTvlLimits = new uint256[](1);
        addedTvlLimits[0] = myToken.totalSupply() / 20;
        vm.expectRevert(abi.encodeWithSelector(Errors.BootstrapAlreadyWhitelisted.selector, address(myToken)));
        bootstrap.addWhitelistTokens(addedWhitelistTokens, addedTvlLimits);
        vm.stopPrank();
    }

    // test that the vault is not deployed for the virtual token address representing natively staked ETH
    function test01_AddWhitelistToken_NoVaultForNativeETH() public {
        MyToken myTokenClone = new MyToken("MyToken", "MYT", 18, addrs, 1000 * 10 ** 18);

        vm.startPrank(deployer);
        address[] memory addedWhitelistTokens = new address[](2);
        addedWhitelistTokens[0] = address(myTokenClone);
        addedWhitelistTokens[1] = VIRTUAL_STAKED_ETH_ADDRESS;
        uint256[] memory addedTvlLimits = new uint256[](2);
        addedTvlLimits[0] = myTokenClone.totalSupply() / 20;
        addedTvlLimits[1] = 0;
        bootstrap.addWhitelistTokens(addedWhitelistTokens, addedTvlLimits);
        vm.stopPrank();

        assertTrue(address(bootstrap.tokenToVault(address(myToken))) != address(0));
        assertTrue(address(bootstrap.tokenToVault(VIRTUAL_STAKED_ETH_ADDRESS)) == address(0));
    }

    function test02_Deposit() public {
        // Distribute MyToken to addresses
        vm.startPrank(deployer);
        for (uint256 i = 0; i < 6; i++) {
            // from constructor logic, some initial balance is present.
            uint256 prevBalance = myToken.balanceOf(addrs[i]);
            myToken.transfer(addrs[i], amounts[i]);
            uint256 newBalance = myToken.balanceOf(addrs[i]);
            assertTrue(newBalance == prevBalance + amounts[i]);
        }
        vm.stopPrank();

        // get the vault to play with
        Vault vault = Vault(address(bootstrap.tokenToVault(address(myToken))));

        // Make deposits and check values
        for (uint256 i = 0; i < 6; i++) {
            vm.startPrank(addrs[i]);
            // first approve the vault
            myToken.approve(address(vault), amounts[i]);

            // store the current state of depositors count and if we are already one
            uint256 prevDepositorsCount = bootstrap.getDepositorsCount();
            bool prevIsDepositor = bootstrap.isDepositor(addrs[i]);
            // ...and current balance
            uint256 prevBalance = myToken.balanceOf(addrs[i]);
            // ...and current deposit by us
            uint256 prevDeposit = bootstrap.totalDepositAmounts(addrs[i], address(myToken));
            // ...and current withdrawable
            uint256 prevWithdrawable = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            // ...and current total token deposit
            uint256 prevTokenDeposit = bootstrap.depositsByToken(address(myToken));

            // finally execute the deposit
            bootstrap.deposit(address(myToken), amounts[i]);

            // check the balance and if it has decreased by the respective amount
            uint256 newBalance = myToken.balanceOf(addrs[i]);
            assertTrue(newBalance == prevBalance - amounts[i]);

            // check the deposit and withdrawable amounts
            uint256 newDeposit = bootstrap.totalDepositAmounts(addrs[i], address(myToken));
            assertTrue(newDeposit == prevDeposit + amounts[i]);
            uint256 newWithdrawable = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            assertTrue(newWithdrawable == prevWithdrawable + amounts[i]);

            // if previously not a depositor, count will increase
            if (!prevIsDepositor) {
                assertTrue(bootstrap.isDepositor(addrs[i]));
                assertTrue(bootstrap.getDepositorsCount() == prevDepositorsCount + 1);
            } else {
                assertTrue(bootstrap.getDepositorsCount() == prevDepositorsCount);
            }

            // total deposit amount should increase
            assertTrue(bootstrap.depositsByToken(address(myToken)) == prevTokenDeposit + amounts[i]);

            vm.stopPrank();
        }
    }

    function test02_Deposit_WithoutApproval() public {
        // make a transfer
        vm.startPrank(deployer);
        myToken.transfer(addrs[0], amounts[0]);
        vm.stopPrank();
        assertTrue(myToken.balanceOf(addrs[0]) >= amounts[0]);

        // now try to deposit
        vm.startPrank(addrs[0]);
        vm.expectRevert();
        bootstrap.deposit(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test02_Deposit_ZeroBalance() public {
        // Make deposits without having any balance
        vm.startPrank(addrs[0]);
        uint256 balance = myToken.balanceOf(addrs[0]);
        myToken.burn(balance);
        assertTrue(myToken.balanceOf(addrs[0]) == 0);
        myToken.approve(address(bootstrap), amounts[0]);
        vm.expectRevert();
        bootstrap.deposit(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test02_Deposit_NonWhitelistedToken() public {
        address cloneDeployer = address(0xdebd);
        // Deploy a new token
        vm.startPrank(cloneDeployer);
        MyToken myTokenClone = new MyToken("MyToken", "MYT", 18, addrs, 1000 * 10 ** 18);
        address cloneAddress = address(myTokenClone);
        vm.stopPrank();

        // now transfer it to address[0]
        vm.startPrank(cloneDeployer);
        myTokenClone.transfer(addrs[0], amounts[0]);

        // now try to deposit
        myToken.approve(address(bootstrap), amounts[0]);
        vm.expectRevert("BootstrapStorage: token is not whitelisted");
        bootstrap.deposit(cloneAddress, amounts[0]);
        vm.stopPrank();
    }

    function test02_Deposit_Success() public {
        address cloneDeployer = address(0xdebd);
        // Deploy a new token
        vm.startPrank(cloneDeployer);
        MyToken myTokenClone = new MyToken("MyToken", "MYT", 18, addrs, 1000 * 10 ** 18);
        address cloneAddress = address(myTokenClone);
        vm.stopPrank();

        // now transfer it to address[0]
        vm.startPrank(cloneDeployer);
        myTokenClone.transfer(addrs[0], amounts[0]);
        vm.stopPrank();

        // now add it to the whitelist
        vm.startPrank(deployer);
        address[] memory addedWhitelistTokens = new address[](1);
        addedWhitelistTokens[0] = cloneAddress;
        uint256[] memory addedTvlLimits = new uint256[](1);
        addedTvlLimits[0] = myTokenClone.totalSupply() / 20;
        bootstrap.addWhitelistTokens(addedWhitelistTokens, addedTvlLimits);
        vm.stopPrank();

        // now try to deposit
        vm.startPrank(addrs[0]);
        IVault vault = bootstrap.tokenToVault(cloneAddress);
        myTokenClone.approve(address(vault), amounts[0]);
        bootstrap.deposit(cloneAddress, amounts[0]);
        vm.stopPrank();
    }

    function test02_Deposit_MoreThanTvl() public {
        address addr = addrs[0];
        uint256 balance = myToken.balanceOf(addr);
        // reduce the TVL limit
        vm.prank(deployer);
        bootstrap.updateTvlLimit(address(myToken), balance / 2);
        // first approve the vault for more than the TVL limit to ensure that the error
        // cause isn't due to lack of approval
        vm.startPrank(addr);
        IVault vault = IVault(bootstrap.tokenToVault(address(myToken)));
        myToken.approve(address(vault), balance);
        // now attempt to deposit
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        bootstrap.deposit(address(myToken), balance);
        vm.stopPrank();
    }

    // This tests whether the TVL limit is enforced correctly when the TVL limit is updated
    // to less than the current TVL.
    function test02_Deposit_ReduceTvlWithdraw() public {
        address addr = addrs[0];
        // must be divisble by 4 to avoid rounding errors
        uint256 balance = myToken.balanceOf(addr);
        uint256 withdrawAmount = balance / 4;
        IVault vault = IVault(bootstrap.tokenToVault(address(myToken)));

        vm.startPrank(addr);
        myToken.approve(address(vault), type(uint256).max);
        bootstrap.deposit(address(myToken), balance);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == balance);

        // reduce the TVL limit below the total deposited amount
        uint256 newTvlLimit = balance / 2;

        vm.startPrank(deployer);
        bootstrap.updateTvlLimit(address(myToken), newTvlLimit);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == balance);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // now attempt to withdraw, which should go through
        vm.startPrank(addr);
        bootstrap.claimPrincipalFromImuachain(address(myToken), withdrawAmount);
        bootstrap.withdrawPrincipal(address(myToken), withdrawAmount, addr);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == balance - withdrawAmount);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // try to deposit, which will fail
        vm.startPrank(addr);
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        bootstrap.deposit(address(myToken), withdrawAmount);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == balance - withdrawAmount);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // withdraw to get just below tvl limit
        withdrawAmount = vault.getConsumedTvl() - vault.getTvlLimit() + 1;
        vm.startPrank(addr);
        bootstrap.claimPrincipalFromImuachain(address(myToken), withdrawAmount);
        bootstrap.withdrawPrincipal(address(myToken), withdrawAmount, addr);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == newTvlLimit - 1);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // then deposit a single unit, which should go through
        vm.startPrank(addr);
        bootstrap.deposit(address(myToken), 1);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == newTvlLimit);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // no more deposits should be allowed
        vm.startPrank(addr);
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        bootstrap.deposit(address(myToken), 1);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == newTvlLimit);
        assertTrue(vault.getTvlLimit() == newTvlLimit);
    }

    function test03_RegisterValidator() public {
        assertTrue(bootstrap.getValidatorsCount() == 0);
        // Register validators. The keys used below do not matter since they are unit test only.
        string[3] memory validators = [
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla",
            "im1wnw7zcl9fy04ax69uffumwkdxftfqsjyz0akf0",
            "im1rtg0cgw94ep744epyvanc0wdd5kedwqlw008ex"
        ];
        string[3] memory names = ["validator1", "validator2", "validator3"];
        bytes32[3] memory pubKeys = [
            bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782),
            bytes32(0xe2f00b6510e16fd8cc5802a4011d6f093acbbbca7c284cad6aa2c2e474bb50f9),
            bytes32(0xa29429a3ca352334fbe75df9485544bd517e3718df73725f33c6d06f3c1caade)
        ];
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(addrs[i]);
            bootstrap.registerValidator(validators[i], names[i], commission, pubKeys[i]);
            // check count
            assertTrue(bootstrap.getValidatorsCount() == i + 1);
            // check ethToImAddress mapping
            string memory imAddress = bootstrap.ethToImAddress(addrs[i]);
            assertTrue(keccak256(abi.encodePacked(imAddress)) == keccak256(abi.encodePacked(validators[i])));
            (string memory name, IValidatorRegistry.Commission memory thisCommision, bytes32 key) =
                bootstrap.validators(imAddress);
            assertTrue(keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked(names[i])));
            assertTrue(key == pubKeys[i]);
            assertTrue(thisCommision.rate == commission.rate);
            assertTrue(bootstrap.validatorNameInUse(names[i]));
            vm.stopPrank();
        }
    }

    function test03_RegisterValidator_EthAlreadyRegistered() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        // change all identifying params except eth address of validator
        im = "im1wnw7zcl9fy04ax69uffumwkdxftfqsjyz0akf0";
        name = "validator1_re";
        pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540783);
        vm.expectRevert(abi.encodeWithSelector(Errors.BootstrapValidatorAlreadyHasAddress.selector, addrs[0]));
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.stopPrank();
    }

    function test03_RegisterValidator_ImAlreadyRegistered() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        // change all identifying params except im address of validator
        vm.stopPrank();
        vm.startPrank(addrs[1]);
        name = "validator1_re";
        pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540783);
        vm.expectRevert(Errors.BootstrapValidatorAlreadyRegistered.selector);
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.stopPrank();
    }

    function test03_RegisterValidator_ConsensusKeyInUse() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);

        // change all identifying params except consensus key of validator
        vm.stopPrank();
        vm.startPrank(addrs[1]);
        im = "im1wnw7zcl9fy04ax69uffumwkdxftfqsjyz0akf0";
        name = "validator1_re";
        vm.expectRevert(abi.encodeWithSelector(Errors.BootstrapConsensusPubkeyAlreadyUsed.selector, pubKey));
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.stopPrank();
    }

    function test03_RegisterValidator_NameInUse() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);

        // change all identifying params except name of validator
        vm.stopPrank();
        vm.startPrank(addrs[1]);
        im = "im1wnw7zcl9fy04ax69uffumwkdxftfqsjyz0akf0";
        pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540783);
        vm.expectRevert(Errors.BootstrapValidatorNameAlreadyUsed.selector);
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.stopPrank();
    }

    function test03_RegisterValidator_EmptyName() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapValidatorNameLengthZero.selector);
        bootstrap.registerValidator(im, name, commission, pubKey);
    }

    function test03_RegisterValidator_ZeroConsensusKey() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0);
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.ZeroValue.selector);
        bootstrap.registerValidator(im, name, commission, pubKey);
    }

    function test04_DepositThenDelegate() public {
        // since deposit and delegate are already tested, we will just do a simple success
        // check here to ensure the reentrancy modifier works.
        test03_RegisterValidator();
        vm.startPrank(addrs[0]);
        IVault vault = IVault(bootstrap.tokenToVault(address(myToken)));
        myToken.approve(address(vault), amounts[0]);
        bootstrap.depositThenDelegateTo(address(myToken), amounts[0], "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla");
        vm.stopPrank();

        uint256 deposited = bootstrap.totalDepositAmounts(addrs[0], address(myToken));
        assertTrue(deposited == amounts[0]);

        uint256 delegated =
            bootstrap.delegations(addrs[0], "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken));
        assertTrue(delegated == amounts[0]);
    }

    function test05_ReplaceKey() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        assertTrue(bootstrap.getValidatorsCount() == 1);
        (,, bytes32 consensusPublicKey) = bootstrap.validators(im);
        assertTrue(consensusPublicKey == pubKey);
        // Then change the key
        bytes32 newKey = bytes32(0xd995b7f4b2178b0466cfa512955ce2299a4487ebcd86f817d686880dd2b7c4b0);
        bootstrap.replaceKey(newKey);
        (,, consensusPublicKey) = bootstrap.validators(im);
        assertTrue(consensusPublicKey == newKey);
        vm.stopPrank();
        // check the key values
        assertFalse(bootstrap.consensusPublicKeyInUse(pubKey));
        assertTrue(bootstrap.consensusPublicKeyInUse(newKey));
    }

    function test05_ReplaceKey_InUseByOther() public {
        test03_RegisterValidator();
        // Then change the key
        vm.startPrank(addrs[0]);
        bytes32 newKey = bytes32(0xe2f00b6510e16fd8cc5802a4011d6f093acbbbca7c284cad6aa2c2e474bb50f9);
        vm.expectRevert(abi.encodeWithSelector(Errors.BootstrapConsensusPubkeyAlreadyUsed.selector, newKey));
        bootstrap.replaceKey(newKey);
        vm.stopPrank();
    }

    function test05_ReplaceKey_InUseBySelf() public {
        test03_RegisterValidator();
        // Then change the key for the same address
        vm.startPrank(addrs[1]);
        bytes32 newKey = bytes32(0xe2f00b6510e16fd8cc5802a4011d6f093acbbbca7c284cad6aa2c2e474bb50f9);
        vm.expectRevert(abi.encodeWithSelector(Errors.BootstrapConsensusPubkeyAlreadyUsed.selector, newKey));
        bootstrap.replaceKey(newKey);
        vm.stopPrank();
    }

    function test05_ReplaceKey_Unregistered() public {
        vm.startPrank(addrs[1]);
        bytes32 newKey = bytes32(0xe2f00b6510e16fd8cc5802a4011d6f093acbbbca7c284cad6aa2c2e474bb50f9);
        vm.expectRevert(Errors.BootstrapValidatorNotExist.selector);
        bootstrap.replaceKey(newKey);
        vm.stopPrank();
    }

    function test05_ReplaceKey_ZeroConsensusKey() public {
        test03_RegisterValidator();
        vm.startPrank(addrs[0]);
        bytes32 newKey = bytes32(0);
        vm.expectRevert(Errors.ZeroValue.selector);
        bootstrap.replaceKey(newKey);
        vm.stopPrank();
    }

    function test06_UpdateRate() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register one validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        bootstrap.updateRate(1e17);
        (, IValidatorRegistry.Commission memory newCommission,) = bootstrap.validators(im);
        assertTrue(newCommission.rate == 1e17);
        vm.stopPrank();
    }

    function test06_UpdateRate_Twice() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        // Register one validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        bootstrap.updateRate(1e17);
        (, IValidatorRegistry.Commission memory newCommission,) = bootstrap.validators(im);
        assertTrue(newCommission.rate == 1e17);
        vm.expectRevert(Errors.BootstrapComissionAlreadyEdited.selector);
        bootstrap.updateRate(1e17);
        vm.stopPrank();
    }

    function test06_UpdateRate_MoreThanMaxRate() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e17, 1e17);
        // Register one validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.expectRevert(Errors.BootstrapRateExceedsMaxRate.selector);
        bootstrap.updateRate(2e17);
        vm.stopPrank();
    }

    function test06_UpdateRate_MoreThanMaxChangeRate() public {
        // 0, 0.1, 0.01
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e17, 1e16);
        // Register one validator
        string memory im = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";
        string memory name = "validator1";
        bytes32 pubKey = bytes32(0x27165ec2f29a4815b7c29e47d8700845b5ae267f2d61ad29fb3939aec5540782);
        vm.startPrank(addrs[0]);
        bootstrap.registerValidator(im, name, commission, pubKey);
        vm.expectRevert(Errors.BootstrapRateChangeExceedsMaxChangeRate.selector);
        bootstrap.updateRate(2e16);
        vm.stopPrank();
    }

    function test06_UpdateRate_Unregistered() public {
        // Register one validator
        address addr = address(0x7);
        vm.startPrank(addr);
        vm.expectRevert(Errors.BootstrapValidatorNotExist.selector);
        bootstrap.updateRate(1e18);
        vm.stopPrank();
    }

    function test07_UpdateTvlLimits() public {
        IVault vault = bootstrap.tokenToVault(address(myToken));
        uint256 newLimit = vault.getTvlLimit() * 2; // double the TVL limit
        vm.prank(deployer);
        bootstrap.updateTvlLimit(address(myToken), newLimit);
        assertTrue(vault.getTvlLimit() == newLimit);
    }

    function test07_UpdateTvlLimits_NotWhitelisted() public {
        vm.startPrank(deployer);
        address addr = address(0xa);
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotWhitelisted.selector, addr));
        bootstrap.updateTvlLimit(addr, 5);
        vm.stopPrank();
    }

    function test07_UpdateTvlLimits_NativeEth() public {
        address[] memory whitelistTokens = new address[](1);
        whitelistTokens[0] = VIRTUAL_STAKED_ETH_ADDRESS;
        uint256[] memory tvlLimits = new uint256[](1);
        tvlLimits[0] = 500;
        vm.startPrank(deployer);
        // first add token to whitelist
        bootstrap.addWhitelistTokens(whitelistTokens, tvlLimits);
        vm.expectRevert(Errors.NoTvlLimitForNativeRestaking.selector);
        bootstrap.updateTvlLimit(whitelistTokens[0], tvlLimits[0] * 2);
        vm.stopPrank();
    }

    function test08_ImuachainAddressIsValid() public {
        assertTrue(bootstrap.isValidImAddress("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla"));
    }

    function test08_ImuachainAddressIsValid_Length() public {
        assertFalse(bootstrap.isValidImAddress("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xlaaa"));
    }

    function test08_ImuachainAddressIsValid_Prefix() public {
        assertFalse(bootstrap.isValidImAddress("mi13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xlaaa"));
    }

    function test09_DelegateTo() public {
        // first, register the validators
        test03_RegisterValidator();
        // then, make the transfers and deposits
        test02_Deposit();
        // first, self delegate
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(addrs[i]);
            string memory im = bootstrap.ethToImAddress(addrs[i]);
            uint256 prevDelegation = bootstrap.delegations(addrs[i], im, address(myToken));
            uint256 prevDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
            uint256 prevWithdrawableAmount = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            bootstrap.delegateTo(im, address(myToken), amounts[i]);
            uint256 postDelegation = bootstrap.delegations(addrs[i], im, address(myToken));
            uint256 postDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
            uint256 postWithdrawableAmount = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            assertTrue(postDelegation == prevDelegation + amounts[i]);
            assertTrue(postDelegationByValidator == prevDelegationByValidator + amounts[i]);
            assertTrue(postWithdrawableAmount == prevWithdrawableAmount - amounts[i]);
            vm.stopPrank();
        }
        // finally, delegate from stakers to the validators
        uint8[3][3] memory delegations = [[8, 9, 0], [0, 7, 8], [2, 0, 6]];
        for (uint256 i = 0; i < 3; i++) {
            address delegator = addrs[i + 3];
            vm.startPrank(delegator);
            for (uint256 j = 0; j < 3; j++) {
                uint256 amount = delegations[i][j] * 10 ** 18;
                if (amount != 0) {
                    string memory im = bootstrap.ethToImAddress(addrs[j]);
                    uint256 prevDelegation = bootstrap.delegations(delegator, im, address(myToken));
                    uint256 prevDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
                    uint256 prevWithdrawableAmount = bootstrap.withdrawableAmounts(delegator, address(myToken));
                    bootstrap.delegateTo(im, address(myToken), uint256(amount));
                    uint256 postDelegation = bootstrap.delegations(delegator, im, address(myToken));
                    uint256 postDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
                    uint256 postWithdrawableAmount = bootstrap.withdrawableAmounts(delegator, address(myToken));
                    assertTrue(postDelegation == prevDelegation + amount);
                    assertTrue(postDelegationByValidator == prevDelegationByValidator + amount);
                    assertTrue(postWithdrawableAmount == prevWithdrawableAmount - amount);
                }
            }
            vm.stopPrank();
        }
    }

    function test09_DelegateTo_Unregistered() public {
        test02_Deposit();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapValidatorNotExist.selector);
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]);
    }

    function test09_DelegateTo_TokenNotWhitelisted() public {
        test03_RegisterValidator();
        test02_Deposit();
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: token is not whitelisted");
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(0xa), amounts[0]);
    }

    function test09_DelegateTo_NotEnoughBalance() public {
        test03_RegisterValidator();
        MyToken myToken = test01_AddWhitelistToken();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientWithdrawableBalance.selector);
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]);
    }

    function test09_DelegateTo_ZeroAmount() public {
        test03_RegisterValidator();
        test02_Deposit();
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: amount should be greater than zero");
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), 0);
    }

    function test09_DelegateTo_NoDeposits() public {
        test03_RegisterValidator();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientWithdrawableBalance.selector);
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]);
    }

    function test09_DelegateTo_Excess() public {
        test03_RegisterValidator();
        test02_Deposit();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientWithdrawableBalance.selector);
        bootstrap.delegateTo("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0] + 1);
    }

    function test10_UndelegateFrom() public {
        test09_DelegateTo();
        // first, self undelegate
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(addrs[i]);
            string memory im = bootstrap.ethToImAddress(addrs[i]);
            uint256 prevDelegation = bootstrap.delegations(addrs[i], im, address(myToken));
            uint256 prevDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
            uint256 prevWithdrawableAmount = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            bootstrap.undelegateFrom(im, address(myToken), amounts[i]);
            uint256 postDelegation = bootstrap.delegations(addrs[i], im, address(myToken));
            uint256 postDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
            uint256 postWithdrawableAmount = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            assertTrue(postDelegation == prevDelegation - amounts[i]);
            assertTrue(postDelegationByValidator == prevDelegationByValidator - amounts[i]);
            assertTrue(postWithdrawableAmount == prevWithdrawableAmount + amounts[i]);
            vm.stopPrank();
        }
        // finally, undelegate from stakers to the validators
        uint8[3][3] memory delegations = [[8, 9, 0], [0, 7, 8], [2, 0, 6]];
        for (uint256 i = 0; i < 3; i++) {
            address delegator = addrs[i + 3];
            vm.startPrank(delegator);
            for (uint256 j = 0; j < 3; j++) {
                uint256 amount = delegations[i][j] * 10 ** 18;
                if (amount != 0) {
                    string memory im = bootstrap.ethToImAddress(addrs[j]);
                    uint256 prevDelegation = bootstrap.delegations(delegator, im, address(myToken));
                    uint256 prevDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
                    uint256 prevWithdrawableAmount = bootstrap.withdrawableAmounts(delegator, address(myToken));
                    bootstrap.undelegateFrom(im, address(myToken), uint256(amount));
                    uint256 postDelegation = bootstrap.delegations(delegator, im, address(myToken));
                    uint256 postDelegationByValidator = bootstrap.delegationsByValidator(im, address(myToken));
                    uint256 postWithdrawableAmount = bootstrap.withdrawableAmounts(delegator, address(myToken));
                    assertTrue(postDelegation == prevDelegation - amount);
                    assertTrue(postDelegationByValidator == prevDelegationByValidator - amount);
                    assertTrue(postWithdrawableAmount == prevWithdrawableAmount + amount);
                }
            }
            vm.stopPrank();
        }
    }

    function test10_UndelegateFrom_Unregistered() public {
        test09_DelegateTo();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapValidatorNotExist.selector);
        bootstrap.undelegateFrom("im1awm72f4sc5yhedurdunx9afcshfq6ymqury93s", address(myToken), amounts[0]);
    }

    function test10_UndelegateFrom_TokenNotWhitelisted() public {
        test03_RegisterValidator();
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: token is not whitelisted");
        bootstrap.undelegateFrom("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(0xa), amounts[0]);
    }

    function test10_UndelegateFrom_NotEnoughBalance() public {
        test03_RegisterValidator();
        MyToken myToken = test01_AddWhitelistToken();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientDelegatedBalance.selector);
        bootstrap.undelegateFrom("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]);
    }

    function test10_UndelegateFrom_ZeroAmount() public {
        test03_RegisterValidator();
        test02_Deposit();
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: amount should be greater than zero");
        bootstrap.undelegateFrom("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), 0);
    }

    function test10_UndelegateFromValidator_Excess() public {
        test09_DelegateTo();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientDelegatedBalance.selector);
        bootstrap.undelegateFrom("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0] + 1);
    }

    function test10_UndelegateFrom_NoDelegation() public {
        test03_RegisterValidator();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientDelegatedBalance.selector);
        bootstrap.undelegateFrom("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]);
    }

    function test11_ClaimPrincipalFromImuachain() public {
        // delegate and then undelegate
        test10_UndelegateFrom();
        // now, withdraw
        for (uint256 i = 0; i < 6; i++) {
            vm.startPrank(addrs[i]);
            uint256 prevDeposit = bootstrap.totalDepositAmounts(addrs[i], address(myToken));
            uint256 prevWithdrawable = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            uint256 prevTokenDeposit = bootstrap.depositsByToken(address(myToken));
            uint256 prevVaultWithdrawable =
                Vault(address(bootstrap.tokenToVault(address(myToken)))).withdrawableBalances(addrs[i]);
            bootstrap.claimPrincipalFromImuachain(address(myToken), amounts[i]);
            uint256 postDeposit = bootstrap.totalDepositAmounts(addrs[i], address(myToken));
            uint256 postWithdrawable = bootstrap.withdrawableAmounts(addrs[i], address(myToken));
            uint256 postTokenDeposit = bootstrap.depositsByToken(address(myToken));
            uint256 postVaultWithdrawable =
                Vault(address(bootstrap.tokenToVault(address(myToken)))).withdrawableBalances(addrs[i]);
            assertTrue(postDeposit == prevDeposit - amounts[i]);
            assertTrue(postWithdrawable == prevWithdrawable - amounts[i]);
            assertTrue(postTokenDeposit == prevTokenDeposit - amounts[i]);
            assertTrue(postVaultWithdrawable == prevVaultWithdrawable + amounts[i]);
            // check the vault too
            vm.stopPrank();
        }
    }

    function test11_ClaimPrincipalFromImuachain_TokenNotWhitelisted() public {
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: token is not whitelisted");
        bootstrap.claimPrincipalFromImuachain(address(0xa), amounts[0]);
        vm.stopPrank();
    }

    function test11_ClaimPrincipalFromImuachain_ZeroAmount() public {
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: amount should be greater than zero");
        bootstrap.claimPrincipalFromImuachain(address(myToken), 0);
        vm.stopPrank();
    }

    function test11_ClaimPrincipalFromImuachain_NoDeposits() public {
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientDepositedBalance.selector);
        bootstrap.claimPrincipalFromImuachain(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test11_ClaimPrincipalFromImuachain_Excess() public {
        test10_UndelegateFrom();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientDepositedBalance.selector);
        bootstrap.claimPrincipalFromImuachain(address(myToken), amounts[0] + 1);
        vm.stopPrank();
    }

    function test11_ClaimPrincipalFromImuachain_ExcessFree() public {
        test09_DelegateTo();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapInsufficientWithdrawableBalance.selector);
        bootstrap.claimPrincipalFromImuachain(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test12_MarkBootstrapped() public {
        // go after spawn time
        vm.warp(spawnTime + 1);
        _markBootstrapped(1, true);
    }

    function _markBootstrapped(uint64 nonce, bool success) internal {
        vm.startPrank(lzActor);
        clientChainLzEndpoint.lzReceive(
            Origin(imuachainChainId, bytes32(bytes20(undeployedImuachainGateway)), nonce),
            address(bootstrap),
            generateUID(nonce),
            abi.encodePacked(Action.REQUEST_MARK_BOOTSTRAP, ""),
            bytes("")
        );
        vm.stopPrank();
        if (success) {
            assertTrue(bootstrap.bootstrapped());
            // no more upgrades are possible
            assertTrue(bootstrap.customProxyAdmin() == address(0));
            assertTrue(proxyAdmin.bootstrapper() == address(0));
            assertTrue(bootstrap.owner() == owner);
        } else {
            assertFalse(bootstrap.bootstrapped());
        }
    }

    function test12_MarkBootstrapped_NotTime() public {
        // spawn time is 1 hour later, so this will fail.
        _markBootstrapped(1, false);
    }

    function test12_MarkBootstrapped_AlreadyBootstrapped() public {
        vm.warp(spawnTime + 1);
        _markBootstrapped(1, true);
        vm.expectEmit(address(bootstrap));
        emit BootstrapStorage.BootstrappedAlready();
        _markBootstrapped(2, true);
        vm.stopPrank();
    }

    function test12_MarkBootstrapped_DirectCall() public {
        // can be any adddress but for clarity use non lz actor
        vm.startPrank(address(0x21));
        vm.warp(spawnTime + 2);
        vm.expectRevert(Errors.BootstrapLzReceiverOnlyCalledFromThis.selector);
        bootstrap.markBootstrapped();
        vm.stopPrank();
    }

    function test12_MarkBootstrapped_FailThenSucceed() public {
        vm.warp(spawnTime - 5);
        _markBootstrapped(1, false);
        vm.warp(spawnTime + 1);
        _markBootstrapped(2, true);
    }

    function test12_MarkBootstrapped_FailThenSucceed2x() public {
        vm.warp(spawnTime - 5);
        _markBootstrapped(1, false);
        vm.warp(spawnTime + 1);
        _markBootstrapped(2, true);
        // silently succeeds and does not block the system after bootstrapping
        vm.warp(spawnTime + 10);
        vm.expectEmit(address(bootstrap));
        emit BootstrapStorage.BootstrappedAlready();
        _markBootstrapped(3, true);
    }

    function test13_OperationAllowed() public {
        vm.warp(spawnTime - offsetDuration);
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.BootstrapBeforeLocked.selector);
        bootstrap.deposit(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test14_IsCommissionValid() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        assertTrue(bootstrap.isCommissionValid(commission));
    }

    function test14_IsCommissionValidRateLarge() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(1.1e18, 1e18, 1e18);
        assertFalse(bootstrap.isCommissionValid(commission));
    }

    function test14_IsCommissionValidMaxRateLarge() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1.1e18, 1e18);
        assertFalse(bootstrap.isCommissionValid(commission));
    }

    function test14_IsCommissionValidMaxChangeRateLarge() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1.1e18);
        assertFalse(bootstrap.isCommissionValid(commission));
    }

    function test14_IsCommissionValidRateExceedsMaxRate() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0.5e18, 0.2e18, 1e18);
        assertFalse(bootstrap.isCommissionValid(commission));
    }

    function test14_IsCommissionValidMaxChangeRateExceedsMaxRate() public {
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0.1e18, 0.2e18, 1e18);
        assertFalse(bootstrap.isCommissionValid(commission));
    }

    function generateUID(uint64 nonce) internal view returns (bytes32 uid) {
        uid = GUID.generate(
            nonce,
            imuachainChainId,
            address(undeployedImuachainGateway),
            clientChainId,
            bytes32(bytes20(address(bootstrap)))
        );
    }

    function test15_Initialize_OwnerZero() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.ZeroAddress.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                address(0x0),
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_SpawnTimeNotFuture() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.warp(20);
        vm.expectRevert(Errors.BootstrapSpawnTimeAlreadyPast.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                block.timestamp - 10,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_OffsetDurationZero() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.ZeroValue.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                spawnTime,
                                0,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_SpawnTimeLTOffsetDuration() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.BootstrapSpawnTimeLessThanDuration.selector);
        vm.warp(20);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                21,
                                22,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_LockTimeNotFuture() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.BootstrapLockTimeAlreadyPast.selector);
        vm.warp(20);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                21,
                                9,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_CustomProxyAdminZero() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.ZeroAddress.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(0x0),
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_GatewayZero() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.ZeroAddress.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x0),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );
    }

    function test15_Initialize_GatewayLogicZero() public {
        vm.startPrank(deployer);
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(0x1),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(0)
        });
        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);
        vm.expectRevert(Errors.BootstrapClientChainDataMalformed.selector);
        Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                deployer,
                                spawnTime,
                                offsetDuration,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                address(0x1),
                                bytes("")
                            )
                        )
                    )
                )
            )
        );
    }

    function test16_SetSpawnTime() public {
        vm.startPrank(deployer);
        bootstrap.setSpawnTime(block.timestamp + 35 minutes);
        assertTrue(bootstrap.spawnTime() == block.timestamp + 35 minutes);
    }

    function test16_SetSpawnTime_NotInFuture() public {
        vm.startPrank(deployer);
        vm.warp(10);
        vm.expectRevert(Errors.BootstrapSpawnTimeAlreadyPast.selector);
        bootstrap.setSpawnTime(9);
    }

    function test16_SetSpawnTime_LessThanOffsetDuration() public {
        vm.startPrank(deployer);
        vm.expectRevert(Errors.BootstrapSpawnTimeLessThanDuration.selector);
        bootstrap.setSpawnTime(offsetDuration - 1);
    }

    function test16_SetSpawnTime_LockTimeNotInFuture() public {
        vm.startPrank(deployer);
        vm.warp(offsetDuration - 1);
        vm.expectRevert(Errors.BootstrapLockTimeAlreadyPast.selector);
        // the initial block.timestamp is 1, so subtract 2 here - 1 for
        // the test and 1 for the warp offset above.
        bootstrap.setSpawnTime(spawnTime - 2);
    }

    function test17_SetOffsetDuration() public {
        vm.startPrank(deployer);
        bootstrap.setOffsetDuration(offsetDuration + 1);
        assertTrue(bootstrap.offsetDuration() == offsetDuration + 1);
    }

    function test17_SetOffsetDuration_GreaterThanSpawnTime() public {
        vm.startPrank(deployer);
        vm.expectRevert(Errors.BootstrapSpawnTimeLessThanDuration.selector);
        bootstrap.setOffsetDuration(spawnTime + 1);
    }

    function test17_SetOffsetDuration_EqualSpawnTime() public {
        vm.startPrank(deployer);
        vm.expectRevert(Errors.BootstrapLockTimeAlreadyPast.selector);
        bootstrap.setOffsetDuration(spawnTime);
    }

    function test17_SetOffsetDuration_LockTimeNotInFuture() public {
        vm.warp(offsetDuration - 1);
        vm.startPrank(deployer);
        vm.expectRevert(Errors.BootstrapLockTimeAlreadyPast.selector);
        bootstrap.setOffsetDuration(offsetDuration + 2);
    }

    function test20_WithdrawRewardFromImuachain() public {
        vm.expectRevert(abi.encodeWithSignature("NotYetSupported()"));
        bootstrap.claimRewardFromImuachain(address(0x0), 1);
    }

    function test22_WithdrawPrincipal() public {
        test11_ClaimPrincipalFromImuachain();
        for (uint256 i = 0; i < 6; i++) {
            vm.startPrank(addrs[i]);
            uint256 prevBalance = myToken.balanceOf(addrs[i]);
            bootstrap.withdrawPrincipal(address(myToken), amounts[i], addrs[i]);
            uint256 postBalance = myToken.balanceOf(addrs[i]);
            assertTrue(postBalance == prevBalance + amounts[i]);
            vm.stopPrank();
        }
    }

    function test22_Claim_TokenNotWhitelisted() public {
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: token is not whitelisted");
        bootstrap.withdrawPrincipal(address(0xa), amounts[0], addrs[0]);
    }

    function test22_Claim_ZeroAmount() public {
        vm.startPrank(addrs[0]);
        vm.expectRevert("BootstrapStorage: amount should be greater than zero");
        bootstrap.withdrawPrincipal(address(myToken), 0, addrs[0]);
    }

    function test22_WithdrawPrincipal_Excess() public {
        test11_ClaimPrincipalFromImuachain();
        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.VaultWithdrawalAmountExceeds.selector);
        bootstrap.withdrawPrincipal(address(myToken), amounts[0] + 5, addrs[0]);
    }

    function test23_RevertWhen_Deposit_WithEther() public {
        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.deposit{value: 0.1 ether}(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test23_RevertWhen_ClaimPrincipalFromImuachain_WithEther() public {
        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.claimPrincipalFromImuachain{value: 0.1 ether}(address(myToken), amounts[0]);
        vm.stopPrank();
    }

    function test23_RevertWhen_DelegateTo_WithEther() public {
        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.delegateTo{value: 0.1 ether}(
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]
        );
        vm.stopPrank();
    }

    function test23_RevertWhen_UndelegateFrom_WithEther() public {
        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.undelegateFrom{value: 0.1 ether}(
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", address(myToken), amounts[0]
        );
        vm.stopPrank();
    }

    function test23_RevertWhen_DepositThenDelegateTo_WithEther() public {
        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.depositThenDelegateTo{value: 0.1 ether}(
            address(myToken), amounts[0], "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla"
        );
        vm.stopPrank();
    }

    // Add these tests to the BootstrapTest contract

    function test24_Stake() public {
        _enableNativeRestaking();

        bytes memory pubkey = new bytes(48);
        bytes memory signature = new bytes(96);
        bytes32 depositDataRoot = bytes32(0);

        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 32 ether);

        // Mock ETHPOS contract to successfully execute
        vm.mockCall(address(ETH_POS), abi.encodeWithSelector(ETH_POS.deposit.selector), abi.encode(true));

        // First stake should create new capsule
        bootstrap.stake{value: 32 ether}(pubkey, signature, depositDataRoot);

        IImuaCapsule capsule = bootstrap.ownerToCapsule(addrs[0]);
        address expectedCapsuleAddress = Create2.computeAddress(
            bytes32(uint256(uint160(addrs[0]))),
            keccak256(abi.encodePacked(BEACON_PROXY_BYTECODE, abi.encode(address(capsuleBeacon), ""))),
            address(bootstrap)
        );
        assertEq(address(capsule), expectedCapsuleAddress, "Capsule address does not match expected");
        vm.stopPrank();
    }

    function test24_Stake_InvalidValue() public {
        _enableNativeRestaking();

        bytes memory pubkey = new bytes(48);
        bytes memory signature = new bytes(96);
        bytes32 depositDataRoot = bytes32(0);

        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 33 ether);

        vm.expectRevert(Errors.NativeRestakingControllerInvalidStakeValue.selector);
        bootstrap.stake{value: 31 ether}(pubkey, signature, depositDataRoot);
        vm.stopPrank();
    }

    function test24_Stake_WhenDisabled() public {
        _disableNativeRestaking();

        bytes memory pubkey = new bytes(48);
        bytes memory signature = new bytes(96);
        bytes32 depositDataRoot = bytes32(0);

        vm.startPrank(addrs[0]);
        vm.deal(addrs[0], 32 ether);

        vm.expectRevert(Errors.NativeRestakingControllerNotWhitelisted.selector);
        bootstrap.stake{value: 32 ether}(pubkey, signature, depositDataRoot);
        vm.stopPrank();
    }

    function test25_CreateImuaCapsule() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);

        address capsuleAddr = bootstrap.createImuaCapsule();
        assertTrue(capsuleAddr != address(0), "Capsule address should not be zero");

        IImuaCapsule capsule = bootstrap.ownerToCapsule(addrs[0]);
        assertTrue(address(capsule) == capsuleAddr, "Capsule should be registered");
        vm.stopPrank();
    }

    function test25_CreateImuaCapsule_AlreadyExists() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);

        bootstrap.createImuaCapsule();
        vm.expectRevert(Errors.NativeRestakingControllerCapsuleAlreadyCreated.selector);
        bootstrap.createImuaCapsule();
        vm.stopPrank();
    }

    function test25_CreateImuaCapsule_WhenDisabled() public {
        _disableNativeRestaking();

        vm.startPrank(addrs[0]);
        vm.expectRevert(Errors.NativeRestakingControllerNotWhitelisted.selector);
        bootstrap.createImuaCapsule();
        vm.stopPrank();
    }

    function test26_VerifyAndDepositNativeStake() public {
        _enableNativeRestaking();

        // First create a capsule
        vm.startPrank(addrs[0]);
        bootstrap.createImuaCapsule();

        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory proof;

        // Mock the capsule to return a specific deposit value
        uint256 expectedDepositValue = 32 ether;
        vm.mockCall(
            address(bootstrap.ownerToCapsule(addrs[0])),
            abi.encodeWithSelector(IImuaCapsule.verifyDepositProof.selector),
            abi.encode(expectedDepositValue)
        );

        // Check initial state
        uint256 initialDeposit = bootstrap.totalDepositAmounts(addrs[0], VIRTUAL_STAKED_ETH_ADDRESS);
        uint256 initialWithdrawable = bootstrap.withdrawableAmounts(addrs[0], VIRTUAL_STAKED_ETH_ADDRESS);
        uint256 initialDepositsByToken = bootstrap.depositsByToken(VIRTUAL_STAKED_ETH_ADDRESS);

        bootstrap.verifyAndDepositNativeStake(validatorContainer, proof);

        // Verify state changes
        assertTrue(
            bootstrap.totalDepositAmounts(addrs[0], VIRTUAL_STAKED_ETH_ADDRESS) == initialDeposit + expectedDepositValue
        );
        assertTrue(
            bootstrap.withdrawableAmounts(addrs[0], VIRTUAL_STAKED_ETH_ADDRESS)
                == initialWithdrawable + expectedDepositValue
        );
        assertTrue(
            bootstrap.depositsByToken(VIRTUAL_STAKED_ETH_ADDRESS) == initialDepositsByToken + expectedDepositValue
        );
        assertTrue(bootstrap.isDepositor(addrs[0]), "Should be marked as depositor");
        vm.stopPrank();
    }

    function test26_VerifyAndDepositNativeStake_WithEther() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);
        bootstrap.createImuaCapsule();

        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory proof;

        vm.deal(addrs[0], 1 ether);
        vm.expectRevert(Errors.NonZeroValue.selector);
        bootstrap.verifyAndDepositNativeStake{value: 0.1 ether}(validatorContainer, proof);
        vm.stopPrank();
    }

    function test26_VerifyAndDepositNativeStake_NoCapsule() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);

        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory proof;

        vm.expectRevert(Errors.CapsuleDoesNotExist.selector);
        bootstrap.verifyAndDepositNativeStake(validatorContainer, proof);
        vm.stopPrank();
    }

    function test26_VerifyAndDepositNativeStake_WhenDisabled() public {
        _disableNativeRestaking();

        vm.startPrank(addrs[0]);
        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory proof;

        vm.expectRevert(Errors.NativeRestakingControllerNotWhitelisted.selector);
        bootstrap.verifyAndDepositNativeStake(validatorContainer, proof);
        vm.stopPrank();
    }

    function test27_WithdrawNonBeaconChainETHFromCapsule() public {
        _enableNativeRestaking();

        // First create a capsule
        vm.startPrank(addrs[0]);
        bootstrap.createImuaCapsule();

        uint256 withdrawAmount = 1 ether;
        address payable recipient = payable(addrs[1]);

        // Mock the capsule withdrawal call
        vm.mockCall(
            address(bootstrap.ownerToCapsule(addrs[0])),
            abi.encodeWithSelector(IImuaCapsule.withdrawNonBeaconChainETHBalance.selector),
            abi.encode()
        );

        bootstrap.withdrawNonBeaconChainETHFromCapsule(recipient, withdrawAmount);
        vm.stopPrank();
    }

    function test27_WithdrawNonBeaconChainETHFromCapsule_NoCapsule() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);

        uint256 withdrawAmount = 1 ether;
        address payable recipient = payable(addrs[1]);

        vm.expectRevert(Errors.CapsuleDoesNotExist.selector);
        bootstrap.withdrawNonBeaconChainETHFromCapsule(recipient, withdrawAmount);
        vm.stopPrank();
    }

    function test27_WithdrawNonBeaconChainETHFromCapsule_WhenDisabled() public {
        _disableNativeRestaking();

        vm.startPrank(addrs[0]);
        uint256 withdrawAmount = 1 ether;
        address payable recipient = payable(addrs[1]);

        vm.expectRevert(Errors.NativeRestakingControllerNotWhitelisted.selector);
        bootstrap.withdrawNonBeaconChainETHFromCapsule(recipient, withdrawAmount);
        vm.stopPrank();
    }

    function test28_ProcessBeaconChainWithdrawal() public {
        _enableNativeRestaking();

        vm.startPrank(addrs[0]);

        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory validatorProof;
        bytes32[] memory withdrawalContainer = new bytes32[](3);
        BeaconChainProofs.WithdrawalProof memory withdrawalProof;

        vm.expectRevert(Errors.NotYetSupported.selector);
        bootstrap.processBeaconChainWithdrawal(validatorContainer, validatorProof, withdrawalContainer, withdrawalProof);
        vm.stopPrank();
    }

    function test28_ProcessBeaconChainWithdrawal_WhenDisabled() public {
        _disableNativeRestaking();

        vm.startPrank(addrs[0]);
        bytes32[] memory validatorContainer = new bytes32[](3);
        BeaconChainProofs.ValidatorContainerProof memory validatorProof;
        bytes32[] memory withdrawalContainer = new bytes32[](3);
        BeaconChainProofs.WithdrawalProof memory withdrawalProof;

        vm.expectRevert(Errors.NativeRestakingControllerNotWhitelisted.selector);
        bootstrap.processBeaconChainWithdrawal(validatorContainer, validatorProof, withdrawalContainer, withdrawalProof);
        vm.stopPrank();
    }

    function _enableNativeRestaking() internal {
        // First find the slot from the logic contract
        bytes32 whitelistSlot = bytes32(
            stdstore.target(address(bootstrapLogic)).sig("isWhitelistedToken(address)").with_key(
                VIRTUAL_STAKED_ETH_ADDRESS
            ).find()
        );

        // Then write to the proxy contract's storage
        vm.store(address(bootstrap), whitelistSlot, bytes32(uint256(1))); // 1 for true
    }

    function _disableNativeRestaking() internal {
        // First find the slot from the logic contract
        bytes32 whitelistSlot = bytes32(
            stdstore.target(address(bootstrapLogic)).sig("isWhitelistedToken(address)").with_key(
                VIRTUAL_STAKED_ETH_ADDRESS
            ).find()
        );

        // Then write to the proxy contract's storage
        vm.store(address(bootstrap), whitelistSlot, bytes32(uint256(0))); // 0 for false
    }

}
