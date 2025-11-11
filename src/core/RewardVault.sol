// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRewardVault} from "../interfaces/IRewardVault.sol";
import {Errors} from "../libraries/Errors.sol";
import {RewardVaultStorage} from "../storage/RewardVaultStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RewardVault is RewardVaultStorage, Initializable, IRewardVault {

    using SafeERC20 for IERC20;

    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    function _onlyGateway() internal view {
        if (msg.sender != gateway) {
            revert Errors.VaultCallerIsNotGateway();
        }
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRewardVault
    function initialize(address gateway_) external initializer {
        require(gateway_ != address(0), "Gateway address cannot be zero");
        gateway = gateway_;
    }

    /// @inheritdoc IRewardVault
    // slither-disable-next-line arbitrary-send-erc20
    function deposit(address token, address depositor, address avs, uint256 amount) external onlyGateway {
        IERC20(token).safeTransferFrom(depositor, address(this), amount);
        totalDepositedRewards[token][avs] += amount;

        emit RewardDeposited(token, avs, amount);
    }

    /// @inheritdoc IRewardVault
    function withdraw(address token, address withdrawer, address recipient, uint256 amount) external onlyGateway {
        if (withdrawableBalances[token][withdrawer] < amount) {
            revert Errors.InsufficientBalance();
        }
        withdrawableBalances[token][withdrawer] -= amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit RewardWithdrawn(token, withdrawer, recipient, amount);
    }

    /// @inheritdoc IRewardVault
    function unlockReward(address token, address withdrawer, uint256 amount) external onlyGateway {
        withdrawableBalances[token][withdrawer] += amount;

        emit RewardUnlocked(token, withdrawer, amount);
    }

    /// @inheritdoc IRewardVault
    function getWithdrawableBalance(address token, address withdrawer) external view returns (uint256) {
        return withdrawableBalances[token][withdrawer];
    }

    /// @inheritdoc IRewardVault
    function getTotalDepositedRewards(address token, address avs) external view returns (uint256) {
        return totalDepositedRewards[token][avs];
    }

}
