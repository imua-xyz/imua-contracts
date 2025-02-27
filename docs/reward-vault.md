# Reward Vault Design Document

## 1. Overview

The Reward Vault is a crucial component of IMUA, designed to securely custody reward tokens distributed by Imuachain. It supports permissionless reward token deposits on behalf of AVS (Actively Validated Service) providers and allows stakers to claim their rewards after verification by Imuachain. The Reward Vault is managed by the Gateway contract, which acts as an intermediary for all operations.

The Reward Vault is implemented using the beacon proxy pattern for upgradeability, and a single instance of the Reward Vault is deployed when the ClientChainGateway is initialized.

## 2. Design Principles

2.1. Permissionless Reward System:
    - The Reward Vault should handle standard ERC20 tokens without requiring prior whitelisting or governance approval.
    - Depositors should be able to deposit rewards in any standard ERC20 token on behalf of AVS providers without restrictions.

2.2. Imuachain as Source of Truth: Imuachain maintains the record of reward balances and handles reward distribution/accounting for each staker. The Reward Vault only tracks withdrawable balances after claim approval.

2.3. Separation of Concerns: The Reward Vault is distinct from principal vaults, maintaining a clear separation between staked principals and earned rewards.

2.4. Security: Despite its permissionless nature, the Reward Vault must maintain high security standards to protect users' rewards.

2.5. Gateway-Managed Operations: All interactions with the Reward Vault are managed through the Gateway contract, ensuring consistency with the existing architecture.

2.6. Upgradeability: The Reward Vault uses the beacon proxy pattern to allow for future upgrades while maintaining a consistent address for all interactions.

## 3. Architecture

### 3.1. Smart Contract: RewardVault.sol

Key Functions:
- `deposit(address token, address avs, uint256 amount)`: Allows the Gateway to deposit reward tokens on behalf of an AVS. Increases the total deposited rewards for the specified token and AVS.
- `unlockReward(address token, address staker, uint256 amount)`: Allows the Gateway to unlock rewards for a staker after claim approval from Imuachain.
- `withdraw(address token, address withdrawer, address recipient, uint256 amount)`: Allows the Gateway to withdraw claimed rewards for a staker.
- `getWithdrawableBalance(address token, address staker)`: Returns the withdrawable balance of a specific reward token for a staker.
- `getTotalDepositedRewards(address token, address avs)`: Returns the total deposited rewards of a specific token for an AVS.

Implementation:
- The RewardVault contract is implemented as an upgradeable contract using the beacon proxy pattern.
- A single instance of the RewardVault is deployed and initialized when the ClientChainGateway is deployed and initialized.

### 3.2. Smart Contract: ClientChainGateway.sol (existing contract, modified)

New Functions:
- `submitReward(address token, uint256 amount, address avs)`: Receives reward submissions and calls RewardVault's `deposit`.
- `claimRewardFromImuachain(address token, uint256 amount)`: Initiates a claim request to Imuachain.
- `withdrawReward(address token, address recipient, uint256 amount)`: Calls RewardVault's `withdraw` to transfer claimed rewards to the staker.

Additional Responsibility:
- Deploys and initializes a single instance of the RewardVault during its own initialization process.

### 3.3. Data Structures

#### 3.3.1. Withdrawable Balances Mapping (in RewardVault.sol)

```solidity
mapping(address => mapping(address => uint256)) public withdrawableBalances;
```

This nested mapping tracks withdrawable reward balances:
- First key: Token address
- Second key: Staker address
- Value: Withdrawable balance amount

#### 3.3.2. Total Deposited Rewards Mapping (in RewardVault.sol)

```solidity
mapping(address => mapping(address => uint256)) public totalDepositedRewards;
```

This nested mapping tracks the total deposited rewards for each token and AVS:
- First key: Token address
- Second key: AVS address
- Value: Total deposited amount

### 3.4. Beacon Proxy Pattern

The Reward Vault uses the beacon proxy pattern for upgradeability:

```solidity
contract RewardVaultBeacon {
    address public implementation;
    address public owner;

    constructor(address _implementation) {
        implementation = _implementation;
        owner = msg.sender;
    }

    function upgrade(address newImplementation) external {
        require(msg.sender == owner, "Not authorized");
        implementation = newImplementation;
    }
}

contract RewardVaultProxy {
    address private immutable _beacon;

    constructor(address beacon) {
        _beacon = beacon;
    }

    fallback() external payable {
        address impl = RewardVaultBeacon(_beacon).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
```

## 4. Key Processes

### 4.1. Reward Submission

1. Depositor calls `submitReward` on the Gateway, specifying the token, amount, and AVS ID.
2. Gateway calls RewardVault's `deposit`, which:
   a. Transfers the specified amount of tokens from the depositor to itself.
   b. Increases the total deposited rewards for the specified token and AVS in the `totalDepositedRewards` mapping.
   c. Emits a `RewardDeposited` event.
3. Gateway sends a message to Imuachain to account for the deposited rewards.
4. Imuachain processes the request and emits a `RewardOperationResult` event to indicate the result of the submission.

### 4.2. Reward Distribution and Accounting

1. Imuachain handles the distribution and accounting of rewards to stakers based on their staking activities and the rewards submitted.
2. Imuachain maintains the record of each staker's earned rewards.

### 4.3. Reward Claiming and Withdrawal

1. Staker calls `claimRewardFromImuachain` on the Gateway.
2. Gateway sends a claim request to Imuachain.
3. Imuachain verifies the request and sends a response back to the Gateway, emitting a `RewardOperation` event.
4. If the claim is approved, Gateway calls RewardVault's `unlockReward`, which:
   a. Increases the staker's withdrawable balance for the specified token.
   b. Emits a `RewardUnlocked` event.
5. At any time after unlocking, the staker can call `withdrawReward` on the Gateway.
6. Gateway calls RewardVault's `withdraw`, which:
   a. Transfers the tokens from the vault to the staker's address.
   b. Decreases the staker's withdrawable balance.
   c. Emits a `RewardWithdrawn` event.

## 5. Security Considerations

5.1. Access Control: 
- Only the Gateway should be able to call RewardVault's functions.
- Any address should be able to call `ClientChainGateway.submitReward`.
- Only stakers should be able to call `ClientChainGateway.claimRewardFromImuachain` for their own rewards.

5.2. Token Compatibility: While the system is permissionless, it is designed to work with standard ERC20 tokens to ensure consistent behavior and accounting.

5.3. Upgradeability: 
- The beacon proxy pattern allows for upgrading the RewardVault implementation while maintaining a consistent address.
- Upgrades should be carefully managed and go through a thorough governance process to ensure security and prevent potential vulnerabilities.

## 6. Gas Optimization

6.1. Batch Operations: Consider implementing functions for batch reward submissions and claims to reduce gas costs.

## 7. Upgradability

The Reward Vault should be implemented as an upgradeable contract using the OpenZeppelin Upgrades plugin. The contract owner, which will be a multisig wallet controlled by the protocol governors, will have the ability to upgrade the contract. This allows for future improvements and bug fixes while maintaining transparency and security.

## 8. Events

Emit events for all significant actions in the RewardVault contract:
- `RewardDeposited(address indexed token, address indexed avs, uint256 amount)`
- `RewardUnlocked(address indexed token, address indexed staker, uint256 amount)`
- `RewardWithdrawn(address indexed token, address indexed staker, uint256 amount)`

The ClientChainGateway contract will emit the following event (as previously defined):
- `RewardOperation(bool isSubmitReward, bool indexed success, bytes32 indexed token, bytes32 indexed avsOrWithdrawer, uint256 amount)`

## 9. Future Considerations

9.1. Emergency Withdrawal: Consider an emergency withdrawal function for unclaimed rewards, accessible only by governance in case of critical issues.

9.2. AVS Reward Tracking: Implement a function to report the total deposited rewards across all tokens for a given AVS, which could be useful for AVS providers to track their reward distribution.

9.3. Multiple Reward Vaults: While currently a single Reward Vault is deployed, the beacon proxy pattern allows for easy deployment of multiple Reward Vaults if needed in the future, all sharing the same implementation but with separate storage.