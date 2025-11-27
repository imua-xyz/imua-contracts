// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "forge-std/StdJson.sol";
import "forge-std/console.sol";

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EndpointV2Mock} from "../../test/mocks/EndpointV2Mock.sol";

import {Bootstrap} from "../../src/core/Bootstrap.sol";
import {ClientChainGateway} from "../../src/core/ClientChainGateway.sol";
import {RewardVault} from "../../src/core/RewardVault.sol";

import {BootstrapStorage} from "../../src/storage/BootstrapStorage.sol";

import {BeaconOracle} from "./BeaconOracle.sol";
import {ALLOWED_CHAIN_ID, NetworkConfig} from "./NetworkConfig.sol";

import {ImuaCapsule} from "../../src/core/ImuaCapsule.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IImuaCapsule} from "../../src/interfaces/IImuaCapsule.sol";

import {IRewardVault} from "../../src/interfaces/IRewardVault.sol";
import {IValidatorRegistry} from "../../src/interfaces/IValidatorRegistry.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

import {BeaconProxyBytecode} from "../../src/utils/BeaconProxyBytecode.sol";
import {CustomProxyAdmin} from "../../src/utils/CustomProxyAdmin.sol";
import {MyToken} from "../../test/foundry/unit/MyToken.sol";

// Technically this is used for testing but it is marked as a script
// because it is a script that is used to deploy the contracts on Anvil / Prysm PoS
// and setup the initial state of Imuachain.

// The keys provided in the dot-env file are required to be already
// initialized by Anvil by `anvil --accounts 20`.
// When you run with this config, the keys already in the file will work
// because Anvil uses a common mnemonic across systems, which is also shared by Prysm.
contract DeployContracts is Script {

    using stdJson for string;

    // no cross-chain communication is part of this test so these are not relevant
    uint16 imuachainChainId = 1;
    uint16 clientChainId = 2;

    uint256[] validators;
    uint256[] stakers;
    // also the owner of the contracts
    uint256 contractDeployer;
    uint256 nstDepositor;
    Bootstrap bootstrap;
    uint256[] tokenDeployers;
    uint8[2] decimals = [18, 6];
    address[] whitelistTokens;
    uint256[] tvlLimits;
    IVault[] vaults;
    CustomProxyAdmin proxyAdmin;

    BeaconOracle beaconOracle;
    IVault vaultImplementation;
    IRewardVault rewardVaultImplementation;
    IImuaCapsule capsuleImplementation;
    IBeacon vaultBeacon;
    IBeacon capsuleBeacon;
    IBeacon rewardVaultBeacon;
    BeaconProxyBytecode beaconProxyBytecode;
    NetworkConfig networkConfig;

    address internal constant VIRTUAL_STAKED_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address depositAddress;
    uint256 denebTimestamp;
    uint64 secondsPerSlot;
    uint64 slotsPerEpoch;
    uint256 beaconGenesisTimestamp;
    bytes pubkey;
    bytes signature;
    bytes32 depositDataRoot;
    uint256 pectraTimestamp;

    function setUp() private {
        // placate the pre-simulation runner
        vm.chainId(ALLOWED_CHAIN_ID);
        // these are default values for Anvil's usual mnemonic.
        // the addresses are also funded in the prysm ethpos devnet!
        uint256[] memory ANVIL_VALIDATORS = new uint256[](3);
        ANVIL_VALIDATORS[0] = uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        ANVIL_VALIDATORS[1] = uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d);
        ANVIL_VALIDATORS[2] = uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a);

        uint256[] memory ANVIL_STAKERS = new uint256[](7);
        ANVIL_STAKERS[0] = uint256(0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6);
        ANVIL_STAKERS[1] = uint256(0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a);
        ANVIL_STAKERS[2] = uint256(0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba);
        ANVIL_STAKERS[3] = uint256(0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e);
        ANVIL_STAKERS[4] = uint256(0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356);
        ANVIL_STAKERS[5] = uint256(0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97);
        ANVIL_STAKERS[6] = uint256(0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6);

        uint256[] memory ANVIL_TOKEN_DEPLOYERS = new uint256[](2);
        ANVIL_TOKEN_DEPLOYERS[0] = uint256(0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82);
        ANVIL_TOKEN_DEPLOYERS[1] = uint256(0xa267530f49f8280200edf313ee7af6b827f2a8bce2897751d06a843f644967b1);

        uint256 ANVIL_CONTRACT_DEPLOYER = uint256(0xf214f2b2cd398c806f84e317254e0f0b801d0643303237d97a22a48e01628897);

        uint256 ANVIL_NST_DEPOSITOR = uint256(0x47c99abed3324a2707c28affff1267e45918ec8c3f20b8aa892e8b065d2942dd);

        // load the keys for validators, stakers, token deployers, and the contract deployer
        validators = vm.envOr("INTEGRATION_VALIDATOR_KEYS", ",", ANVIL_VALIDATORS);
        // we don't validate the contents of the keys because vm.addr will throw if they are invalid
        require(validators.length == 3, "Modify this script to support validators.length other than 3");
        stakers = vm.envOr("INTEGRATION_STAKERS", ",", ANVIL_STAKERS);
        require(stakers.length == 7, "Modify this script to support stakers.length other than 7");
        tokenDeployers = vm.envOr("INTEGRATION_TOKEN_DEPLOYERS", ",", ANVIL_TOKEN_DEPLOYERS);
        require(tokenDeployers.length == 2, "Modify this script to support tokenDeployers.length other than 2");
        require(decimals.length == tokenDeployers.length, "Decimals and tokenDeployers must have the same length");
        contractDeployer = vm.envOr("INTEGRATION_CONTRACT_DEPLOYER", ANVIL_CONTRACT_DEPLOYER);
        nstDepositor = vm.envOr("INTEGRATION_NST_DEPOSITOR", ANVIL_NST_DEPOSITOR);

        // read the network configuration parameters and validate them
        depositAddress = vm.envOr("INTEGRATION_DEPOSIT_ADDRESS", address(0x6969696969696969696969696969696969696969));
        require(depositAddress != address(0), "Deposit address must be set");
        denebTimestamp = vm.envUint("INTEGRATION_DENEB_TIMESTAMP");
        require(denebTimestamp > 0, "Deneb timestamp must be set");
        beaconGenesisTimestamp = vm.envUint("INTEGRATION_BEACON_GENESIS_TIMESTAMP");
        require(beaconGenesisTimestamp > 0, "Beacon timestamp must be set");
        pectraTimestamp = vm.envUint("INTEGRATION_PECTRA_TIMESTAMP");
        require(pectraTimestamp > 0, "Pectra timestamp must be set");
        // can not read uint64 from env
        uint256 secondsPerSlot_ = vm.envUint("INTEGRATION_SECONDS_PER_SLOT");
        require(secondsPerSlot_ > 0, "Seconds per slot must be set");
        require(secondsPerSlot_ <= type(uint64).max, "Seconds per slot must be less than or equal to uint64 max");
        // casting to 'uint64' is safe because we ensure the value does not exceed uint64 max above
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsPerSlot = uint64(secondsPerSlot_);
        uint256 slotsPerEpoch_ = vm.envUint("INTEGRATION_SLOTS_PER_EPOCH");
        require(slotsPerEpoch_ > 0, "Slots per epoch must be set");
        require(slotsPerEpoch_ <= type(uint64).max, "Slots per epoch must be less than or equal to uint64 max");
        // casting to 'uint64' is safe because we ensure the value does not exceed uint64 max above
        // forge-lint: disable-next-line(unsafe-typecast)
        slotsPerEpoch = uint64(slotsPerEpoch_);
        // then, the Ethereum-native validator configuration
        pubkey = vm.envOr(
            "INTEGRATION_PUBKEY",
            hex"98db81971df910a5d46314d21320f897060d76fdf137d22f0eb91a8693a4767d2a22730a3aaa955f07d13ad604f968e9"
        );
        require(pubkey.length == 48, "Pubkey must be 48 bytes");
        signature = vm.envOr(
            "INTEGRATION_SIGNATURE",
            hex"922a316bdc3516bfa66e88259d5e93e339ef81bc85b70e6c715542222025a28fa1e3644c853beb8c3ba76a2c5c03b726081bf605bde3a16e1f33f902cc1b6c01093c19609de87da9383fa4b1f347bd2d4222e1ae5428727a7896c8e553cc8071"
        );
        require(signature.length == 96, "Signature must be 96 bytes");
        depositDataRoot = vm.envOr(
            "INTEGRATION_DEPOSIT_DATA_ROOT", bytes32(0x456934ced8f08ff106857418a6d885ba69d31e1b7fab9a931be06da25490cd1d)
        );
        require(depositDataRoot != bytes32(0), "Deposit data root must be set");
    }

    function deployTokens() private {
        // first, add this guy to the whitelist so we can start from i = 1
        whitelistTokens.push(VIRTUAL_STAKED_ETH_ADDRESS);
        tvlLimits.push(0); // not enforced for virtual staked eth

        string[2] memory names = ["MyToken1", "MyToken2"];
        string[2] memory symbols = ["MT1", "MT2"];
        uint256[2] memory initialBalances = [2000 * 10 ** decimals[0], 5000 * 10 ** decimals[1]];
        address[] memory initialAddresses = new address[](validators.length + stakers.length);
        for (uint256 i = 0; i < validators.length; i++) {
            initialAddresses[i] = vm.addr(validators[i]);
        }
        for (uint256 i = 0; i < stakers.length; i++) {
            initialAddresses[validators.length + i] = vm.addr(stakers[i]);
        }
        for (uint256 i = 0; i < tokenDeployers.length; i++) {
            vm.startBroadcast(tokenDeployers[i]);
            MyToken myToken = new MyToken(names[i], symbols[i], decimals[i], initialAddresses, initialBalances[i]);
            whitelistTokens.push(address(myToken));
            tvlLimits.push(myToken.totalSupply() / ((i + 1) * 20));
            vm.stopBroadcast();
        }
    }

    function deployContract() private {
        vm.startBroadcast(contractDeployer);
        networkConfig = new NetworkConfig(
            depositAddress, denebTimestamp, slotsPerEpoch, secondsPerSlot, beaconGenesisTimestamp, pectraTimestamp
        );
        beaconOracle = new BeaconOracle(address(networkConfig));

        /// deploy vault implementation contract, capsule implementation contract
        vaultImplementation = new Vault();
        capsuleImplementation = new ImuaCapsule(address(networkConfig));

        /// deploy the vault beacon and capsule beacon
        vaultBeacon = new UpgradeableBeacon(address(vaultImplementation));
        capsuleBeacon = new UpgradeableBeacon(address(capsuleImplementation));

        // deploy BeaconProxyBytecode
        beaconProxyBytecode = new BeaconProxyBytecode();

        proxyAdmin = new CustomProxyAdmin();
        EndpointV2Mock clientChainLzEndpoint = new EndpointV2Mock(clientChainId);

        // Create ImmutableConfig struct
        BootstrapStorage.ImmutableConfig memory config = BootstrapStorage.ImmutableConfig({
            imuachainChainId: imuachainChainId,
            beaconOracleAddress: address(beaconOracle),
            vaultBeacon: address(vaultBeacon),
            imuaCapsuleBeacon: address(capsuleBeacon),
            beaconProxyBytecode: address(beaconProxyBytecode),
            networkConfig: address(networkConfig)
        });

        Bootstrap bootstrapLogic = new Bootstrap(address(clientChainLzEndpoint), config);

        bootstrap = Bootstrap(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bootstrapLogic),
                        address(proxyAdmin),
                        abi.encodeCall(
                            bootstrap.initialize,
                            (
                                vm.addr(contractDeployer),
                                // keep a large buffer because we are going to be depositing a lot of tokens
                                block.timestamp + 24 hours,
                                1 seconds,
                                whitelistTokens,
                                tvlLimits,
                                address(proxyAdmin),
                                // not needed for creating the contract
                                address(0x1),
                                bytes("123456")
                            )
                        )
                    )
                )
            )
        );

        // to keep bootstrap address constant, we must keep its nonce unchanged. hence, further transactions are sent
        // after the bare minimum bootstrap and associated deployments.
        // the default deposit params are created using imuacapsule address 0x90618D1cDb01bF37c24FC012E70029DA20fCe971
        // which is made using the default NST_DEPOSITOR + bootstrap address 0xF801fc13AA08876F343fEBf50dFfA52A78180811
        // if you get a DepositDataRoot or related error, check these addresses first.
        // if these addresses match, check that the DepositDataRoot, the Signature and the Pubkey match the default
        // in setUp().
        proxyAdmin.initialize(address(bootstrap));
        rewardVaultImplementation = new RewardVault();
        rewardVaultBeacon = new UpgradeableBeacon(address(rewardVaultImplementation));
        ClientChainGateway clientGatewayLogic =
            new ClientChainGateway(address(clientChainLzEndpoint), config, address(rewardVaultBeacon));

        bytes memory initialization =
            abi.encodeWithSelector(clientGatewayLogic.initialize.selector, vm.addr(contractDeployer));

        bootstrap.setClientChainGatewayLogic(address(clientGatewayLogic), initialization);

        vm.stopBroadcast();
        console.log("Bootstrap address: ", address(bootstrap));

        // set the vaults
        for (uint256 i = 1; i < whitelistTokens.length; i++) {
            IVault vault = bootstrap.tokenToVault(whitelistTokens[i]);
            vaults.push(vault);
        }
    }

    function approveAndDepositLST() private {
        // amounts deposited by each validators, for the tokens 1 and 2.
        uint256[2] memory validatorAmounts = [1500 * 10 ** decimals[0], 2000 * 10 ** decimals[1]];
        // stakerAmounts - keep divisible by 3 for delegate
        uint256[2] memory stakerAmounts = [300 * 10 ** decimals[0], 600 * 10 ** decimals[1]];
        for (uint256 i = 1; i < whitelistTokens.length; i++) {
            for (uint256 j = 0; j < validators.length; j++) {
                vm.startBroadcast(validators[j]);
                MyToken(whitelistTokens[i]).approve(address(vaults[i - 1]), type(uint256).max);
                bootstrap.deposit(whitelistTokens[i], validatorAmounts[i - 1]);
                vm.stopBroadcast();
            }
        }
        for (uint256 i = 1; i < whitelistTokens.length; i++) {
            for (uint256 j = 0; j < stakers.length; j++) {
                vm.startBroadcast(stakers[j]);
                MyToken(whitelistTokens[i]).approve(address(vaults[i - 1]), type(uint256).max);
                bootstrap.deposit(whitelistTokens[i], stakerAmounts[i - 1]);
                vm.stopBroadcast();
            }
        }
    }

    function stakeNST() private {
        vm.startBroadcast(nstDepositor);
        address myAddress = address(bootstrap.ownerToCapsule(vm.addr(nstDepositor)));
        if (myAddress == address(0)) {
            myAddress = bootstrap.createImuaCapsule();
        }
        console.log("ImuaCapsule address", myAddress);
        bootstrap.stake{value: 32 ether}(pubkey, signature, depositDataRoot);
        vm.stopBroadcast();
    }

    function registerValidators() private {
        string[3] memory ims = [
            // these addresses will accrue rewards but they are not needed to keep the chain
            // running.
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla",
            "im1wnw7zcl9fy04ax69uffumwkdxftfqsjyz0akf0",
            "im1rtg0cgw94ep744epyvanc0wdd5kedwqlw008ex"
        ];
        string[3] memory names = ["validator1", "validator2", "validator3"];
        // the mnemonics corresponding to the consensus public keys are given here. to recover,
        // echo "${MNEMONIC}" | imuad init localnet --chain-id imuachainlocalnet_232-1 --recover
        // the value in this script is this one
        // imuad keys consensus-pubkey-to-bytes --output json | jq -r .bytes
        bytes32[3] memory pubKeys = [
            // wonder quality resource ketchup occur stadium vicious output situate plug second
            // monkey harbor vanish then myself primary feed earth story real soccer shove like
            bytes32(0xF0F6919E522C5B97DB2C8255BFF743F9DFDDD7AD9FC37CB0C1670B480D0F9914),
            // carpet stem melt shove boring monster group hover afraid impulse give human
            // blanket notable repeat typical image menu know resist injury trick cancel robot
            bytes32(0x5CBB4508AD3F9C1D711314971211F991AC51B5EDDA2174866817D649E34EB691),
            // sugar vault poet soda excite puzzle news stool bonus harsh middle forget mosquito
            // wise sister language work muscle parade dad angry across emerge trade
            bytes32(0x4C9DE94E1F3225906602AE812E30F1BE56427126D60F2F6CB661B7F4FDA638DC)
        ];
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        for (uint256 i = 0; i < validators.length; i++) {
            vm.startBroadcast(validators[i]);
            bootstrap.registerValidator(ims[i], names[i], commission, pubKeys[i]);
            vm.stopBroadcast();
        }
    }

    function delegate() private {
        // validator delegations. i used these values so that we have a mix of validators
        // delegating amongst themselves and to other validators. i also set it up such that
        // the amount for each self delegation is non zero, although that is not validated
        // in the contract.
        uint256[3][3][2] memory validatorDelegations = [
            [
                [200 * 10 ** decimals[0], 50 * 10 ** decimals[0], 50 * 10 ** decimals[0]],
                [0 * 10 ** decimals[0], 300 * 10 ** decimals[0], 0 * 10 ** decimals[0]],
                [100 * 10 ** decimals[0], 100 * 10 ** decimals[0], 100 * 10 ** decimals[0]]
            ],
            [
                [400 * 10 ** decimals[1], 200 * 10 ** decimals[1], 0 * 10 ** decimals[1]],
                [50 * 10 ** decimals[1], 550 * 10 ** decimals[1], 0 * 10 ** decimals[1]],
                [120 * 10 ** decimals[1], 80 * 10 ** decimals[1], 400 * 10 ** decimals[1]]
            ]
        ];
        for (uint256 i = 1; i < whitelistTokens.length; i++) {
            for (uint256 j = 0; j < validators.length; j++) {
                uint256 delegator = validators[j];
                for (uint256 k = 0; k < validators.length; k++) {
                    uint256 amount = validatorDelegations[i - 1][j][k];
                    address validator = vm.addr(validators[k]);
                    string memory validatorIm = bootstrap.ethToImAddress(validator);
                    vm.startBroadcast(delegator);
                    if (amount != 0) {
                        bootstrap.delegateTo(validatorIm, whitelistTokens[i], amount);
                    }
                    vm.stopBroadcast();
                }
            }
        }
        // now i have N stakers, with N validators and 2 tokens.
        // i will take 1/3 and 2/3 of the deposit amounts for each token for each staker
        // respectively
        // find a random number for those amounts for each validators
        // op1 = random1, op2 = random2, op3 = 1/3 - random1 - random2
        for (uint256 i = 1; i < whitelistTokens.length; i++) {
            for (uint256 j = 0; j < stakers.length; j++) {
                uint256 delegator = stakers[j];
                address delegatorAddress = vm.addr(delegator);
                uint256 deposit = bootstrap.totalDepositAmounts(delegatorAddress, whitelistTokens[i]);
                uint256 stakerDelegationToDo = (deposit * i) / 3;
                for (uint256 k = 0; k < validators.length; k++) {
                    uint256 amount;
                    if (k == validators.length - 1) {
                        amount = stakerDelegationToDo;
                    } else {
                        amount = random(stakerDelegationToDo);
                    }
                    address validator = vm.addr(validators[k]);
                    string memory im = bootstrap.ethToImAddress(validator);
                    vm.startBroadcast(delegator);
                    bootstrap.delegateTo(im, whitelistTokens[i], amount);
                    stakerDelegationToDo -= amount;
                    vm.stopBroadcast();
                }
            }
        }
    }

    function run() external {
        console.log("Loading keys and addresses");
        setUp();
        console.log("Set up complete");
        deployTokens();
        console.log("Tokens deployed");
        deployContract();
        console.log("Contract deployed");
        approveAndDepositLST();
        console.log("Approved and deposited LSTs");
        stakeNST();
        console.log("Staked NST (will have to submit proof later to count the deposit)");
        registerValidators();
        console.log("Validators registered");
        delegate();
        console.log("Delegated; done!");

        for (uint256 i = 0; i < whitelistTokens.length; i++) {
            console.log("Token", i, " address", whitelistTokens[i]);
        }

        // finally save the bootstrap address
        string memory key = "deployments";
        key.serialize("beaconOracleAddress", address(beaconOracle));
        string memory start = key.serialize("bootstrapAddress", address(bootstrap));
        vm.writeFile("script/integration/deployments.json", start);
    }

    // Helper function to generate a random number within a range
    function random(uint256 _range) internal view returns (uint256) {
        // Basic random number generation; consider a more robust approach for production
        return (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % (_range - 1)) + 1;
    }

}
