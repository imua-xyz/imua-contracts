// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract EndpointMock {
    uint32 public eid;
    mapping(address => address) public delegates;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    function lzReceive(
        address _receiver,
        uint32 _srcEid,
        bytes32 _sender,
        uint64 _nonce,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable {
        // We call the receiver's lzReceive (selector 0x13137d65)
        (bool success, bytes memory reason) = _receiver.call{value: msg.value}(
            abi.encodeWithSelector(
                0x13137d65,
                _srcEid, _sender, _nonce,
                _guid,
                _message,
                msg.sender,
                _extraData
            )
        );
        if (!success) {
            // Revert with the error from the inner call
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

