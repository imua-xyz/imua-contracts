pragma solidity ^0.8.19;

import "../../src/interfaces/precompiles/IAssets.sol";

contract PrecompileCallerMock {

    uint256 public balance;
    bool public lastDepositStatus;

    error PrecompileError();

    function deposit(uint256 amount) public {
        (bool success, bytes memory response) = ASSETS_PRECOMPILE_ADDRESS.call{gas: 216_147}(
            abi.encodeWithSelector(
                ASSETS_CONTRACT.depositLST.selector,
                uint32(101),
                abi.encodePacked(bytes32(bytes20(address(0xdAC17F958D2ee523a2206206994597C13D831ec7)))),
                abi.encodePacked(bytes32(bytes20(address(0x2)))),
                amount
            )
        );
        if (!success) {
            revert PrecompileError();
        }
        (bool _status, uint256 _balance) = abi.decode(response, (bool, uint256));
        balance = _balance;
        lastDepositStatus = _status;
    }

}
