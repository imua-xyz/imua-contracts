pragma solidity ^0.8.19;

import {Bootstrap} from "../src/core/Bootstrap.sol";
import {Vault} from "../src/core/Vault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";

import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

import "forge-std/Script.sol";

// This script does not intentionally inherit from BaseScript, since
// that script has boilerplate that is not needed here.
contract RegisterValidatorsAndDelegate is Script {

    uint256 primaryKey;
    // registration data for validators
    uint256[] validatorKeys;
    string[] imAddresses;
    string[] names;
    bytes32[] consKeys;
    // rpc settings
    string clientChainRPCURL;
    uint256 clientChain;
    // addresses of contracts
    address bootstrapAddr;
    address tokenAddr;
    // each subarray sums to deposits, and each item is the delegation amount
    uint256[4][4] amounts = [
        [1500 * 1e18, 250 * 1e18, 250 * 1e18, 0 * 1e18],
        [300 * 1e18, 1500 * 1e18, 0 * 1e18, 200 * 1e18],
        [0 * 1e18, 0 * 1e18, 2500 * 1e18, 500 * 1e18],
        [1000 * 1e18, 0 * 1e18, 0 * 1e18, 2000 * 1e18]
    ];

    function setUp() public {
        primaryKey = vm.envUint("TEST_ACCOUNT_THREE_PRIVATE_KEY");
        validatorKeys = vm.envUint("VALIDATOR_KEYS", ",");
        imAddresses = vm.envString("IM_ADDRESSES", ",");
        names = vm.envString("NAMES", ",");
        consKeys = vm.envBytes32("CONS_KEYS", ",");

        clientChainRPCURL = vm.envString("CLIENT_CHAIN_RPC");
        clientChain = vm.createSelectFork(clientChainRPCURL);

        require(
            validatorKeys.length == imAddresses.length && validatorKeys.length == names.length
                && validatorKeys.length == consKeys.length,
            "Validator registration data length mismatch"
        );

        string memory deployedContracts = vm.readFile("script/deployments/deployedBootstrapOnly.json");
        bootstrapAddr = stdJson.readAddress(deployedContracts, ".clientChain.bootstrap");
        require(bootstrapAddr != address(0), "Bootstrap address should not be empty");
        tokenAddr = stdJson.readAddress(deployedContracts, ".clientChain.erc20Token");
        require(tokenAddr != address(0), "Token address should not be empty");
    }

    function run() public {
        vm.selectFork(clientChain);
        IValidatorRegistry.Commission memory commission = IValidatorRegistry.Commission(0, 1e18, 1e18);
        Bootstrap bootstrap = Bootstrap(bootstrapAddr);
        ERC20PresetFixedSupply token = ERC20PresetFixedSupply(tokenAddr);
        address vaultAddr = address(bootstrap.tokenToVault(tokenAddr));
        for (uint256 i = 0; i < validatorKeys.length; i++) {
            uint256 pk = validatorKeys[i];
            address addr = vm.addr(pk);
            console.log(i, addr);
            string memory imAddr = imAddresses[i];
            string memory name = names[i];
            bytes32 consKey = consKeys[i];
            vm.startBroadcast(pk);
            // register validator
            bootstrap.registerValidator(imAddr, name, commission, consKey);
            vm.stopBroadcast();
            // give them the balance
            vm.startBroadcast(primaryKey);
            uint256 depositAmount = 0;
            for (uint256 j = 0; j < amounts[i].length; j++) {
                depositAmount += amounts[i][j];
            }
            if (token.balanceOf(addr) < depositAmount) {
                token.transfer(addr, depositAmount);
            }
            vm.stopBroadcast();
            // approve
            vm.startBroadcast(pk);
            token.approve(vaultAddr, type(uint256).max);
            // transfer
            bootstrap.deposit(tokenAddr, depositAmount);
            vm.stopBroadcast();
        }
        for (uint256 i = 0; i < validatorKeys.length; i++) {
            uint256 pk = validatorKeys[i];
            vm.startBroadcast(pk);
            for (uint256 j = 0; j < validatorKeys.length; j++) {
                uint256 amount = amounts[i][j];
                if (amount == 0) {
                    continue;
                }
                // i is the transaction sender and j is the validator
                string memory imAddr = imAddresses[j];
                bootstrap.delegateTo(imAddr, tokenAddr, amount);
            }
            vm.stopBroadcast();
        }
    }

}
