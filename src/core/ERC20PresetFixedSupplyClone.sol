// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/presets/ERC20PresetFixedSupply.sol)
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20PresetFixedSupplyUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/presets/ERC20PresetFixedSupplyUpgradeable.sol";

contract ERC20PresetFixedSupplyClone is Initializable, OwnableUpgradeable, ERC20PresetFixedSupplyUpgradeable {

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name, string memory symbol, address owner)
        // to change the name again, change this to reinitializer(2) or higher
        // deploy a new impl, switch to new impl, call initialize with new name
        external
        initializer
    {
        // no initial mint because we are copying the balances manually.
        __ERC20PresetFixedSupply_init(name, symbol, 0, owner);
        // the owner is required for initial minting of balances
        // it can be renounced once done, but for testnet, we aren't
        // doing it.
        _transferOwnership(owner);
    }

    function copyBalances(address[] calldata holders, uint256[] calldata balances, bool[] calldata burns)
        external
        onlyOwner
    {
        require(
            holders.length == balances.length,
            "ERC20PresetFixedSupplyClone: holders and balances must have the same length"
        );
        require(
            holders.length == burns.length, "ERC20PresetFixedSupplyClone: holders and burns must have the same length"
        );
        for (uint256 i = 0; i < holders.length; i++) {
            if (balances[i] == 0) {
                continue;
            }
            if (holders[i] == address(0)) {
                continue;
            }
            if (burns[i]) {
                _burn(holders[i], balances[i]);
            } else {
                _mint(holders[i], balances[i]);
            }
        }
    }

}
