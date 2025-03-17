// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// This is used to import the CREATE3Factory contract as a dependency so that it can be easily used in scripts.
// @dev Suppress unused-import warning as this is intentionally imported for scripts
/* solhint-disable no-unused-import */
import {CREATE3Factory} from "create3-factory/src/CREATE3Factory.sol";
import {NonShortCircuitEndpointV2Mock} from "test/mocks/NonShortCircuitEndpointV2Mock.sol";
