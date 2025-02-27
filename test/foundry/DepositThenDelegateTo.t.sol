pragma solidity ^0.8.19;

import "../../src/core/ImuachainGateway.sol";

import "../../src/interfaces/precompiles/IDelegation.sol";
import {Action, GatewayStorage} from "../../src/storage/GatewayStorage.sol";

import "../mocks/AssetsMock.sol";
import "../mocks/DelegationMock.sol";
import "./ImuachainDeployer.t.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract DepositThenDelegateToTest is ImuachainDeployer {

    using AddressCast for address;

    // ImuachainGateway emits these two events after handling the request
    event LSTTransfer(
        bool isDeposit, bool indexed success, bytes32 indexed token, bytes32 indexed depositor, uint256 amount
    );
    event DelegationRequest(
        bool isDelegate,
        bool indexed accepted,
        bytes32 indexed token,
        bytes32 indexed delegator,
        string operator,
        uint256 amount
    );

    // emitted by the mock delegation contract
    event DelegateRequestProcessed(
        uint32 clientChainLzId,
        uint64 lzNonce,
        bytes assetsAddress,
        bytes stakerAddress,
        string operatorAddr,
        uint256 opAmount
    );

    function test_DepositThenDelegateTo() public {
        address delegator = players[0].addr;
        address relayer = players[1].addr;
        string memory operatorAddress = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";

        deal(delegator, 1e22);
        deal(address(imuachainGateway), 1e22);

        uint256 delegateAmount = 10_000;

        // before all operations we should add whitelist tokens
        test_AddWhitelistTokens();

        // ensure there is enough balance
        vm.startPrank(owner.addr);
        restakeToken.transfer(delegator, delegateAmount);
        vm.stopPrank();

        // // approve it
        vm.startPrank(delegator);
        restakeToken.approve(address(vault), delegateAmount);
        vm.stopPrank();

        (bytes32 requestId, bytes memory requestPayload) = _testRequest(delegator, operatorAddress, delegateAmount);
        _testRequestExecutionSuccess(requestId, requestPayload, delegator, relayer, operatorAddress, delegateAmount);
        _validateNonces();
    }

    function test_BalanceUpdatedWhen_DepositThenDelegateToResponseNotSuccess() public {
        address delegator = players[0].addr;
        address relayer = players[1].addr;
        string memory operatorAddress = "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla";

        deal(delegator, 1e22);
        deal(address(imuachainGateway), 1e22);

        uint256 delegateAmount = 10_000;

        // before all operations we should add whitelist tokens
        test_AddWhitelistTokens();

        // ensure there is enough balance
        vm.startPrank(owner.addr);
        restakeToken.transfer(delegator, delegateAmount);
        vm.stopPrank();

        // approve it
        vm.startPrank(delegator);
        restakeToken.approve(address(vault), delegateAmount);
        vm.stopPrank();

        (bytes32 requestId, bytes memory requestPayload) = _testRequest(delegator, operatorAddress, delegateAmount);
        _testRequestExecutionFailure(delegator, relayer, delegateAmount);
        // this cannot be called here because we have artificially failed the delegation and avoided the
        // inboundNonce increment on Imuachain
        // _validateNonces();
    }

    function _testRequest(address delegator, string memory operatorAddress, uint256 delegateAmount)
        private
        returns (bytes32 requestId, bytes memory requestPayload)
    {
        uint256 beforeBalanceDelegator = restakeToken.balanceOf(delegator);
        uint256 beforeBalanceVault = restakeToken.balanceOf(address(vault));

        requestPayload = abi.encodePacked(
            Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO,
            abi.encodePacked(bytes32(bytes20(delegator))),
            delegateAmount,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            bytes(operatorAddress)
        );
        uint256 requestNativeFee = clientGateway.quote(requestPayload);
        requestId = generateUID(outboundNonces[clientChainId], true);

        vm.expectEmit(address(restakeToken));
        emit IERC20.Transfer(delegator, address(vault), delegateAmount);

        vm.expectEmit(address(clientChainLzEndpoint));
        emit NewPacket(
            imuachainChainId,
            address(clientGateway),
            address(imuachainGateway).toBytes32(),
            outboundNonces[clientChainId],
            requestPayload
        );

        vm.expectEmit(address(clientGateway));
        emit MessageSent(
            Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO, requestId, outboundNonces[clientChainId]++, requestNativeFee
        );

        vm.startPrank(delegator);
        clientGateway.depositThenDelegateTo{value: requestNativeFee}(
            address(restakeToken), delegateAmount, operatorAddress
        );
        vm.stopPrank();

        // check that the balance changed
        uint256 afterBalanceDelegator = restakeToken.balanceOf(delegator);
        assertEq(afterBalanceDelegator, beforeBalanceDelegator - delegateAmount);
        uint256 afterBalanceVault = restakeToken.balanceOf(address(vault));
        assertEq(afterBalanceVault, beforeBalanceVault + delegateAmount);
    }

    // test that request is successfully executed on Imuachain
    function _testRequestExecutionSuccess(
        bytes32 requestId,
        bytes memory requestPayload,
        address delegator,
        address relayer,
        string memory operatorAddress,
        uint256 delegateAmount
    ) private {
        // deposit request is firstly handled and its event is firstly emitted
        vm.expectEmit(address(imuachainGateway));
        emit LSTTransfer(
            true, true, bytes32(bytes20(address(restakeToken))), bytes32(bytes20(delegator)), delegateAmount
        );

        // secondly delegate request is handled
        vm.expectEmit(DELEGATION_PRECOMPILE_ADDRESS);
        emit DelegateRequestProcessed(
            clientChainId,
            outboundNonces[clientChainId] - 1,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(delegator))),
            operatorAddress,
            delegateAmount
        );

        vm.expectEmit(address(imuachainGateway));
        emit DelegationRequest(
            true,
            true,
            bytes32(bytes20(address(restakeToken))),
            bytes32(bytes20(delegator)),
            operatorAddress,
            delegateAmount
        );

        vm.expectEmit(address(imuachainGateway));
        emit MessageExecuted(Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO, inboundNonces[imuachainChainId]++);

        vm.startPrank(relayer);
        imuachainLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[imuachainChainId] - 1),
            address(imuachainGateway),
            requestId,
            requestPayload,
            bytes("")
        );
        vm.stopPrank();

        uint256 actualDepositAmount = AssetsMock(ASSETS_PRECOMPILE_ADDRESS).getPrincipalBalance(
            clientChainId,
            // weirdly, the address(x).toBytes32() did not work here.
            // for reference, the results are
            // addressOg = 0x0000000000000000000000000000000000000001
            // toBytes32 = 0x0000000000000000000000000000000000000000000000000000000000000001
            // abiEncode = 0x0000000000000000000000000000000000000001000000000000000000000000
            // so, AddressCast left pads it while abi.encodePacked is right padding it.
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(delegator)))
        );
        assertEq(actualDepositAmount, delegateAmount);

        uint256 actualDelegateAmount = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getDelegateAmount(
            delegator, operatorAddress, clientChainId, address(restakeToken)
        );
        assertEq(actualDelegateAmount, delegateAmount);
    }

    function _testRequestExecutionFailure(address delegator, address relayer, uint256 delegateAmount) private {
        // Mock the delegation call to return false
        bytes memory delegateCalldata = abi.encodeWithSelector(
            IDelegation.delegate.selector,
            clientChainId,
            outboundNonces[clientChainId] - 1,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(delegator))),
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla",
            delegateAmount
        );
        vm.mockCall(DELEGATION_PRECOMPILE_ADDRESS, delegateCalldata, abi.encode(false));

        // Expect LSTTransfer event for successful deposit
        vm.expectEmit(address(imuachainGateway));
        emit LSTTransfer(
            true, true, bytes32(bytes20(address(restakeToken))), bytes32(bytes20(delegator)), delegateAmount
        );

        // Expect DelegationRequest event with 'accepted' as false
        vm.expectEmit(address(imuachainGateway));
        emit DelegationRequest(
            true,
            false,
            bytes32(bytes20(address(restakeToken))),
            bytes32(bytes20(delegator)),
            "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla",
            delegateAmount
        );

        // Execute the request
        bytes memory requestPayload = abi.encodePacked(
            Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO,
            abi.encodePacked(bytes32(bytes20(delegator))),
            delegateAmount,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            bytes("im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla")
        );
        bytes32 requestId = generateUID(outboundNonces[clientChainId] - 1, true);

        vm.expectEmit(address(imuachainGateway));
        emit MessageExecuted(Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO, inboundNonces[imuachainChainId]++);

        vm.startPrank(relayer);
        imuachainLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[imuachainChainId] - 1),
            address(imuachainGateway),
            requestId,
            requestPayload,
            bytes("")
        );
        vm.stopPrank();

        // Verify that the deposit was successful
        uint256 actualDepositAmount = AssetsMock(ASSETS_PRECOMPILE_ADDRESS).getPrincipalBalance(
            clientChainId,
            abi.encodePacked(bytes32(bytes20(address(restakeToken)))),
            abi.encodePacked(bytes32(bytes20(delegator)))
        );
        assertEq(actualDepositAmount, delegateAmount);

        // Verify that the delegation was not successful
        uint256 actualDelegateAmount = DelegationMock(DELEGATION_PRECOMPILE_ADDRESS).getDelegateAmount(
            delegator, "im13hasr43vvq8v44xpzh0l6yuym4kca98fhq3xla", clientChainId, address(restakeToken)
        );
        assertEq(actualDelegateAmount, 0);

        // Clear the mock to avoid affecting other tests
        vm.clearMockedCalls();
    }

}
