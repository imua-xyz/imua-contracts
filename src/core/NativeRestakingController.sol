pragma solidity ^0.8.19;

import {ClientChainGatewayStorage} from "../storage/ClientChainGatewayStorage.sol";
import {ITSSReceiver} from "../interfaces/ITSSReceiver.sol";
import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IExoCapsule} from "../interfaces/IExoCapsule.sol";
import {ExoCapsule} from "./ExoCapsule.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {OAppSenderUpgradeable, MessagingFee, MessagingReceipt} from "../lzApp/OAppSenderUpgradeable.sol";
import {ECDSA} from "@openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {OptionsBuilder} from "@layerzero-v2/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import {BaseRestakingController} from "./BaseRestakingController.sol";

abstract contract NativeRestakingController is 
    PausableUpgradeable, 
    OAppSenderUpgradeable, 
    INativeRestakingController,
    BaseRestakingController
{
    using ValidatorContainer for bytes32[];
    using WithdrawalContainer for bytes32[];

    function createExoCapsule() external whenNotPaused {
        require(address(ownerToCapsule[msg.sender]) == address(0), "NativeRestakingController: message sender has already created the capsule");

        IExoCapsule capsule = new ExoCapsule(ETH_STAKING_DEPOSIT_CONTRACT_ADDRESS, address(this));
        capsule.initialize(msg.sender);
        ownerToCapsule[msg.sender] = capsule;
        isExoCapsule[capsule] = true;

        emit CapsuleCreated(msg.sender, address(capsule));
    }

    function depositBeaconChainValidator(
        bytes32[] calldata validatorContainer, 
        IExoCapsule.ValidatorContainerProof calldata proof
    ) external whenNotPaused {
        IExoCapsule capsule = ownerToCapsule[msg.sender];
        if (address(capsule) == address(0)) {
            revert CapsuleNotExistForOwner(msg.sender);
        }

        capsule.verifyPartialWithdrawalProof(validatorContainer, proof);

        uint256 depositValue = uint256(validatorContainer.getEffectiveBalance()) * GWEI_TO_WEI;
        registeredRequests[outboundNonce + 1] = abi.encode(VIRTUAL_STAKED_ETH_ADDRESS, msg.sender, depositValue);
        registeredRequestActions[outboundNonce + 1] = Action.REQUEST_DEPOSIT;

        bytes memory actionArgs = abi.encodePacked(
            bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)), 
            bytes32(bytes20(msg.sender)), 
            depositValue
        );
        
        _sendMsgToExocore(Action.REQUEST_DEPOSIT, actionArgs);
    }
}