// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "../test/mocks/AssetsMock.sol";
import "../test/mocks/DelegationMock.sol";

import "../src/interfaces/precompiles/IAssets.sol";
import "../src/interfaces/precompiles/IDelegation.sol";

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import "forge-std/StdJson.sol";

import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";

import {Origin} from "../src/lzApp/OAppReceiverUpgradeable.sol";

contract SimulateReceive is Script, StdCheats {

    using stdJson for string;

    function run() public {
        // https://scan-testnet.layerzero-api.com/v1/messages/tx/<hash>
        string memory json = vm.readFile("./scanApiResponse.json");
        uint32 srcEid = uint32(json.readUint(".data[0].pathway.srcEid"));
        require(srcEid != 0, "srcEid should not be empty");
        require(srcEid <= type(uint16).max, "srcEid must fit in uint16");
        // always monkey-patch a precompile, since with LZ we need them
        // TODO: AssetsMock may still complain about a few things.
        // casting to 'uint16' is safe because we verify the srcEid fits within uint16 above
        // forge-lint: disable-next-line(unsafe-typecast)
        deployCodeTo("AssetsMock.sol", abi.encode(uint16(srcEid)), ASSETS_PRECOMPILE_ADDRESS);
        deployCodeTo("DelegationMock.sol", DELEGATION_PRECOMPILE_ADDRESS);
        address senderAddress = json.readAddress(".data[0].pathway.sender.address");
        require(senderAddress != address(0), "senderAddress should not be empty");
        uint64 nonce = uint64(json.readUint(".data[0].pathway.nonce"));
        require(nonce != 0, "nonce should not be empty");
        bytes32 sender = addressToBytes32(senderAddress);
        require(sender != bytes32(0), "sender should not be empty");
        address receiver = json.readAddress(".data[0].pathway.receiver.address");
        require(receiver != address(0), "receiver should not be empty");
        bytes32 guid = json.readBytes32(".data[0].guid");
        require(guid != bytes32(0), "guid should not be empty");
        bytes memory payload = json.readBytes(".data[0].source.tx.payload");
        require(payload.length != 0, "payload should not be empty");

        Origin memory origin = Origin({srcEid: srcEid, sender: sender, nonce: nonce});
        bytes memory extraData = "";
        vm.startBroadcast();
        bytes memory encoded = abi.encodeWithSelector(
            IOAppCore(receiver).endpoint().lzReceive.selector, origin, receiver, guid, payload, extraData
        );
        console.logBytes(encoded);
        IOAppCore(receiver).endpoint().lzReceive(origin, receiver, guid, payload, extraData);
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

}
