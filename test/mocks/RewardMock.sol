// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    AVSRewardDistributionInfo,
    IReward,
    OperatorRewardProportion,
    RegisterRewardTokenParams,
    RewardCoin,
    UndelegateRewardParams,
    WithdrawIMUATokenRewardParams,
    WithdrawRewardParams
} from "../../src/interfaces/precompiles/IReward.sol";

contract RewardMock is IReward {

    // Storage for rewards
    mapping(uint32 => mapping(bytes => mapping(bytes => uint256))) public rewardsOfAVS;
    mapping(uint32 => mapping(bytes => mapping(bytes => uint256))) public rewardsOfStaker;
    mapping(uint32 => mapping(bytes => mapping(bytes => uint256))) public outstandingRewards; // For claimReward
    mapping(uint32 => mapping(bytes => bool)) public registeredRewardTokens;
    mapping(address => mapping(uint32 => mapping(bytes => uint256))) public avsRewards; // For fundAVSReward

    /// @inheritdoc IReward
    function claimReward(uint32 clientChainLzID, bytes calldata stakerAddress) external returns (bool success) {
        // Move rewards from outstanding to withdrawable (simplified mock)
        // In real implementation, this would claim rewards from all AVSs
        // For mock, we just mark as claimed
        return true;
    }

    /// @inheritdoc IReward
    function withdrawReward(WithdrawRewardParams calldata params)
        external
        returns (bool success, uint256 actualWithdrawAmount)
    {
        require(params.assetAddress.length == 32, "invalid asset address");
        require(params.stakerAddress.length == 32, "invalid staker address");

        // If doClaim is true, claim rewards first (move from outstanding to withdrawable)
        if (params.doClaim) {
            // In real implementation, this would claim rewards from all AVSs
            // For mock, we simulate by moving outstanding rewards to staker rewards
            uint256 outstanding = outstandingRewards[params.clientChainLzID][params.assetAddress][params.stakerAddress];
            if (outstanding > 0) {
                rewardsOfStaker[params.clientChainLzID][params.assetAddress][params.stakerAddress] += outstanding;
                outstandingRewards[params.clientChainLzID][params.assetAddress][params.stakerAddress] = 0;
            }
        }

        uint256 availableReward = rewardsOfStaker[params.clientChainLzID][params.assetAddress][params.stakerAddress];

        if (params.opAmount == 0) {
            // Withdraw all available rewards
            actualWithdrawAmount = availableReward;
        } else {
            // Withdraw specified amount
            require(availableReward >= params.opAmount, "insufficient reward");
            actualWithdrawAmount = params.opAmount;
        }

        if (actualWithdrawAmount > 0) {
            rewardsOfStaker[params.clientChainLzID][params.assetAddress][params.stakerAddress] -= actualWithdrawAmount;
        }

        return (true, actualWithdrawAmount);
    }

    /// @inheritdoc IReward
    function withdrawIMUATokenReward(WithdrawIMUATokenRewardParams calldata params)
        external
        returns (bool success, uint256 actualWithdrawAmount, uint256 withdrawAmountFromDogfood)
    {
        require(params.stakerAddress.length == 32, "invalid staker address");
        require(params.receiptAddress.length == 32, "invalid receipt address");

        // Simplified mock - treat as regular withdrawReward
        bytes memory imuaTokenAddress = abi.encodePacked(bytes32(uint256(0))); // IMUA token address mock
        uint256 availableReward = rewardsOfStaker[params.clientChainLzID][imuaTokenAddress][params.stakerAddress];

        if (params.opAmount == 0) {
            actualWithdrawAmount = availableReward;
        } else {
            require(availableReward >= params.opAmount, "insufficient reward");
            actualWithdrawAmount = params.opAmount;
        }

        if (actualWithdrawAmount > 0) {
            rewardsOfStaker[params.clientChainLzID][imuaTokenAddress][params.stakerAddress] -= actualWithdrawAmount;
        }

        withdrawAmountFromDogfood = 0; // Mock doesn't track dogfood separately
        return (true, actualWithdrawAmount, withdrawAmountFromDogfood);
    }

    /// @inheritdoc IReward
    function setStakerRewardParams(
        uint32 clientChainLzID,
        bytes calldata stakerAddress,
        bool redelegateReward,
        string calldata redelegateOperator
    ) external returns (bool success) {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function undelegateReward(UndelegateRewardParams calldata params) external returns (bool success) {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function withdrawCommission(
        uint32 rewardAssetChainLzID,
        bytes calldata assetAddress,
        bytes calldata operatorAddress,
        uint256 opAmount
    ) external returns (bool success, uint256 actualWithdrawAmount) {
        // Mock implementation - simplified
        actualWithdrawAmount = opAmount;
        return (true, actualWithdrawAmount);
    }

    /// @inheritdoc IReward
    function withdrawIMUATokenCommission(
        bytes calldata operatorAddress,
        bytes calldata receiptAddress,
        uint256 opAmount
    ) external returns (bool success, uint256 actualWithdrawAmount, uint256 withdrawAmountFromDogfood) {
        // Mock implementation
        actualWithdrawAmount = opAmount;
        withdrawAmountFromDogfood = 0;
        return (true, actualWithdrawAmount, withdrawAmountFromDogfood);
    }

    /// @inheritdoc IReward
    function registerRewardToken(RegisterRewardTokenParams calldata params) external returns (bool success) {
        registeredRewardTokens[params.clientChainID][params.token] = true;
        return true;
    }

    /// @inheritdoc IReward
    function updateRewardToken(uint32 clientChainID, bytes calldata token, string calldata metaData)
        external
        returns (bool success)
    {
        require(registeredRewardTokens[clientChainID][token], "token not registered");
        return true;
    }

    /// @inheritdoc IReward
    function setAVSRewardDistribution(AVSRewardDistributionInfo calldata rewardDistribution)
        external
        returns (bool success)
    {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function setAVSEpochReward(RewardCoin[] calldata epochRewards) external returns (bool success) {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function setOperatorRewardProportions(OperatorRewardProportion[] calldata operatorRewardProportions)
        external
        returns (bool success)
    {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function setAVSRewardParams(bool isCustomRewardInflation, bool isCustomOperatorRatio)
        external
        returns (bool success)
    {
        // Mock implementation - just return success
        return true;
    }

    /// @inheritdoc IReward
    function fundAVSReward(
        uint32 rewardAssetChainLzID,
        address avsAddress,
        bytes calldata assetAddress,
        uint256 opAmount
    ) external returns (bool success) {
        require(assetAddress.length == 32, "invalid asset address");
        bytes32 avsBytes32 = bytes32(bytes20(avsAddress));
        rewardsOfAVS[rewardAssetChainLzID][assetAddress][abi.encodePacked(avsBytes32)] += opAmount;
        return true;
    }

    /// @inheritdoc IReward
    function isRegisteredRewardToken(uint32 clientChainID, bytes calldata token)
        external
        view
        returns (bool success, bool isRegistered)
    {
        return (true, registeredRewardTokens[clientChainID][token]);
    }

    function distributeReward(
        uint32 clientChainLzId,
        bytes calldata assetsAddress,
        bytes calldata avsId,
        bytes calldata staker,
        uint256 amount
    ) external returns (bool success, uint256 latestAssetState) {
        require(assetsAddress.length == 32, "invalid asset address");
        require(staker.length == 32, "invalid staker address");
        require(avsId.length == 32, "invalid avsId");
        require(rewardsOfAVS[clientChainLzId][assetsAddress][avsId] >= amount, "insufficient reward");
        rewardsOfAVS[clientChainLzId][assetsAddress][avsId] -= amount;
        rewardsOfStaker[clientChainLzId][assetsAddress][staker] += amount;
        return (true, rewardsOfAVS[clientChainLzId][assetsAddress][avsId]);
    }

    function getRewardAmountForAVS(uint32 clientChainLzId, bytes calldata assetsAddress, bytes calldata avsId)
        external
        view
        returns (uint256)
    {
        return rewardsOfAVS[clientChainLzId][assetsAddress][avsId];
    }

    function getRewardAmountForStaker(uint32 clientChainLzId, bytes calldata assetsAddress, bytes calldata staker)
        external
        view
        returns (uint256)
    {
        return rewardsOfStaker[clientChainLzId][assetsAddress][staker];
    }

}
