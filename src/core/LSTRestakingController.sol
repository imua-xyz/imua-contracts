pragma solidity ^0.8.19;

import {ClientChainGatewayStorage} from "../storage/ClientChainGatewayStorage.sol";
import {ILSTRestakingController} from "../interfaces/ILSTRestakingController.sol";
import {IVault} from "../interfaces/IVault.sol";
import {BaseRestakingController} from "./BaseRestakingController.sol";

import {PausableUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/PausableUpgradeable.sol";

abstract contract LSTRestakingController is 
    PausableUpgradeable, 
    ILSTRestakingController, 
    BaseRestakingController
{
    function deposit(address token, uint256 amount) external payable whenNotPaused {
        require(whitelistTokens[token], "Controller: token is not whitelisted");
        require(amount > 0, "Controller: amount should be greater than zero");

        IVault vault = tokenVaults[token];
        require(address(vault) != address(0), "Controller: no vault added for this token");

        vault.deposit(msg.sender, amount);

        registeredRequests[outboundNonce + 1] = abi.encode(token, msg.sender, amount);
        registeredRequestActions[outboundNonce + 1] = Action.REQUEST_DEPOSIT;

        bytes memory actionArgs = abi.encodePacked(bytes32(bytes20(token)), bytes32(bytes20(msg.sender)), amount);
        _sendMsgToExocore(Action.REQUEST_DEPOSIT, actionArgs);
    }

    function withdrawPrincipleFromExocore(address token, uint256 principleAmount) external payable whenNotPaused {
        require(whitelistTokens[token], "Controller: token is not whitelisted");
        require(principleAmount > 0, "Controller: amount should be greater than zero");

        IVault vault = tokenVaults[token];
        if (address(vault) == address(0)) {
            revert VaultNotExist();
        }

        registeredRequests[outboundNonce + 1] = abi.encode(token, msg.sender, principleAmount);
        registeredRequestActions[outboundNonce + 1] = Action.REQUEST_WITHDRAW_PRINCIPLE_FROM_EXOCORE;

        bytes memory actionArgs =
            abi.encodePacked(bytes32(bytes20(token)), bytes32(bytes20(msg.sender)), principleAmount);
        _sendMsgToExocore(Action.REQUEST_WITHDRAW_PRINCIPLE_FROM_EXOCORE, actionArgs);
    }

    function withdrawRewardFromExocore(address token, uint256 rewardAmount) external payable whenNotPaused {
        require(whitelistTokens[token], "Controller: token is not whitelisted");
        require(rewardAmount > 0, "Controller: amount should be greater than zero");

        IVault vault = tokenVaults[token];
        if (address(vault) == address(0)) {
            revert VaultNotExist();
        }

        registeredRequests[outboundNonce + 1] = abi.encode(token, msg.sender, rewardAmount);
        registeredRequestActions[outboundNonce + 1] = Action.REQUEST_WITHDRAW_REWARD_FROM_EXOCORE;

        bytes memory actionArgs = abi.encodePacked(bytes32(bytes20(token)), bytes32(bytes20(msg.sender)), rewardAmount);
        _sendMsgToExocore(Action.REQUEST_WITHDRAW_REWARD_FROM_EXOCORE, actionArgs);
    }

    function updateUsersBalances(UserBalanceUpdateInfo[] calldata info) public whenNotPaused {
        require(msg.sender == address(this), "Controller: caller must be client chain gateway itself");
        for (uint256 i = 0; i < info.length; i++) {
            UserBalanceUpdateInfo memory userBalanceUpdate = info[i];
            for (uint256 j = 0; j < userBalanceUpdate.tokenBalances.length; j++) {
                TokenBalanceUpdateInfo memory tokenBalanceUpdate = userBalanceUpdate.tokenBalances[j];
                require(whitelistTokens[tokenBalanceUpdate.token], "Controller: token is not whitelisted");

                IVault vault = tokenVaults[tokenBalanceUpdate.token];
                if (address(vault) == address(0)) {
                    revert VaultNotExist();
                }

                if (tokenBalanceUpdate.lastlyUpdatedPrincipleBalance > 0) {
                    vault.updatePrincipleBalance(
                        userBalanceUpdate.user, tokenBalanceUpdate.lastlyUpdatedPrincipleBalance
                    );
                }

                if (tokenBalanceUpdate.lastlyUpdatedRewardBalance > 0) {
                    vault.updateRewardBalance(userBalanceUpdate.user, tokenBalanceUpdate.lastlyUpdatedRewardBalance);
                }

                if (tokenBalanceUpdate.unlockPrincipleAmount > 0 || tokenBalanceUpdate.unlockRewardAmount > 0) {
                    vault.updateWithdrawableBalance(
                        userBalanceUpdate.user,
                        tokenBalanceUpdate.unlockPrincipleAmount,
                        tokenBalanceUpdate.unlockRewardAmount
                    );
                }
            }
        }
    }
}
