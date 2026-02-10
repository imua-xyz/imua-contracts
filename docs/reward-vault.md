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
- `deposit(address token, address avs, uint256 amount)`: Allows the Gateway to deposit reward tokens on behalf of an AVS. Increases the locked reward balance for the token.
- `unlockReward(address token, address staker, uint256 amount)`: Allows the Gateway to unlock rewards for a staker after claim approval from Imuachain. Decreases the locked reward balance and increases the staker's withdrawable balance.
- `withdraw(address token, address withdrawer, address recipient, uint256 amount)`: Allows the Gateway to withdraw claimed rewards for a staker.
- `getWithdrawableBalance(address token, address staker)`: Returns the withdrawable balance of a specific reward token for a staker.
- `getLockedRewards(address token)`: Returns the locked reward balance for a token (amount deposited but not yet unlocked).

Implementation:
- The RewardVault contract is implemented as an upgradeable contract using the beacon proxy pattern.
- A single instance of the RewardVault is deployed and initialized when the ClientChainGateway is deployed and initialized.

### 3.2. Smart Contract: ClientChainGateway.sol (existing contract, modified)

New Functions:
- `fundAVSReward(address token, uint256 amount, address avs)`: Receives reward funding and calls RewardVault's `deposit`.
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

#### 3.3.2. Locked Rewards Mapping (in RewardVault.sol)

```solidity
mapping(address => uint256) public lockedRewards;
```

This mapping tracks the locked reward balance for each token:
- Key: Token address
- Value: Locked reward amount (increases on deposit, decreases on unlock)

The locked rewards represent the amount of tokens that have been deposited but not yet unlocked for withdrawal. This provides real-time tracking of the vault's locked balance, enabling efficient vault health checks and invariant validation.

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

### 4.1. Reward Funding

1. Depositor calls `fundAVSReward` on the Gateway, specifying the token, amount, and AVS ID.
2. Gateway calls RewardVault's `deposit`, which:
   a. Transfers the specified amount of tokens from the depositor to itself.
   b. Increases the locked reward balance for the token in the `lockedRewards` mapping.
   c. Emits a `RewardDeposited` event.
3. Gateway sends a message to Imuachain to account for the deposited rewards.
4. Imuachain processes the request and emits a `RewardOperationResult` event to indicate the result of the funding.

### 4.2. Reward Distribution and Accounting

1. Imuachain handles the distribution and accounting of rewards to stakers based on their staking activities and the rewards funded.
2. Imuachain maintains the record of each staker's earned rewards.

### 4.3. Reward Claiming and Withdrawal (Current Behavior)

The current implementation supports the case where the staker and the reward token are on the **same client chain**. In this model:

1. The staker (identified by `(clientChainId, stakerAddress)`) calls `claimRewardFromImuachain(address token, uint256 amount)` on the `ClientChainGateway` of their client chain.
2. The gateway sends a claim request to Imuachain, including the client chain id, the staker’s address, and the reward token address.
3. Imuachain processes the claim, computes the claimable amount, and sends a `REQUEST_CLAIM_REWARD` response **back to the same client chain** via `ImuachainGateway`, emitting a `RewardOperation` event.
4. If the claim is successful, `ImuachainGateway` invokes `REWARD_CONTRACT.withdrawReward` with `rewardAssetChainLzID` set to the **same** `clientChainLzID`. The returned `actualWithdrawAmount` is then forwarded to the client chain via dedicated bridge.
5. `ClientChainGateway` receives the response, looks up the original `(clientChainId, stakerAddress, assetAddress)` request, and calls `RewardVault.unlockReward(assetAddress, stakerAddress, actualWithdrawAmount)`, which:
   - Decreases the locked reward balance for the token.
   - Increases the staker's withdrawable balance for that token.
   - Emits a `RewardUnlocked` event.
6. At any time after unlocking, the staker calls `withdrawReward(address token, address recipient, uint256 amount)` on the `ClientChainGateway`.
7. `ClientChainGateway` calls `RewardVault.withdraw(token, staker, recipient, amount)`, which:
   - Checks `withdrawableBalances[token][staker]` is sufficient.
   - Decreases the staker’s withdrawable balance.
   - Transfers `amount` of `token` from the local `RewardVault` to `recipient`.
   - Emits a `RewardWithdrawn` event.

> **Limitation:** In this version, `clientChainLzID` and `rewardAssetChainLzID` are always set to the **same value**, meaning rewards are only withdrawn on the **originating client chain**. Scenarios where a staker on chain A earns rewards on chain B (e.g., an Ethereum staker earning SOL on Solana) are **not yet supported** end-to-end.

### 4.4. Future Extensions for Generic Cross-Chain Rewards

To support the general case where a staker on one chain earns rewards on a different chain, the protocol can evolve along (at least) two directions:

#### 4.4.1. Option 1 – Explicit Reward Destination in `claimRewardFromImuachain`

Extend the client-chain claim interface to carry explicit reward-destination information:

- Add parameters to `claimRewardFromImuachain` (in `BaseRestakingController` / `ClientChainGateway`), for example:
  - `uint32 rewardAssetChainLzID` – the LayerZero chain id where the reward asset is custodied (e.g., Solana).
  - `bytes assetAddress` – the reward token address on the destination chain.
  - `bytes recipient` – the destination-chain recipient address (e.g., a Solana pubkey).

Updated flow:

1. Staker on chain A calls `claimRewardFromImuachain(token, amount, rewardAssetChainLzID, assetAddress, recipient)`.
2. `ClientChainGateway` encodes and forwards `(clientChainLzID_A, stakerAddress_A, rewardAssetChainLzID, assetAddress, recipient, amount)` to `ImuachainGateway` via `REQUEST_CLAIM_REWARD`.
3. `ImuachainGateway.handleRewardOperation` passes `rewardAssetChainLzID` and `assetAddress` into `IReward.WithdrawRewardParams`, so Imuachain can withdraw rewards on the appropriate chain.
4. `ImuachainGateway` sends the claim result to the `ClientChain` that hosts the reward asset (not necessarily the original staking chain).
5. The destination chain’s gateway receives the response and calls its local `RewardVault.unlockReward(assetAddress, recipient, actualWithdrawAmount)`, crediting the correct recipient on the reward chain.
6. The recipient on the reward chain calls `withdrawReward(assetAddress, recipient, amount)` on that chain’s gateway, which in turn calls its local `RewardVault.withdraw`.

#### 4.4.2. Option 2 – Imuachain-Native Reward Recipients and Push-Based Unlocks

An alternative (or complementary) approach is to decouple reward ownership from the client-chain address:

- When staking, the user registers an **Imuachain address** as their canonical reward recipient (e.g., via a new `associateRewardAddress` call on `ClientChainGateway` or directly on Imuachain).
- Imuachain tracks rewards by `(imuaAddress, rewardAssetChainLzID, assetAddress)` rather than by `(clientChainId, stakerAddress, assetAddress)`.

In this model:

1. Rewards accrue on Imuachain for the user’s `imuaAddress`, regardless of which client chain they used to stake.
2. When the user wants to realize rewards on a destination chain B, they:
   - Either call a new API (e.g., `withdrawRewardToChain(uint32 rewardAssetChainLzID, bytes assetAddress, bytes recipient)`) on `ImuachainGateway` or `ClientChainGateway`, or
   - Imuachain autonomously initiates a `REQUEST_CLAIM_REWARD`/unlock to the appropriate `UTXOGateway` / `ClientChainGateway` on the destination chain.
3. `ImuachainGateway` uses the `rewardAssetChainLzID` and `assetAddress` fields in `IReward.WithdrawRewardParams` to withdraw rewards on the target chain and sends a message to that chain’s gateway, which then calls its local `RewardVault` to credit and/or withdraw to the specified `recipient`.

This “push-based” model enables true omni-chain reward distribution while keeping Imuachain as the single source of truth for reward accounting.

## 5. Security Considerations

5.1. Access Control: 
- Only the Gateway should be able to call RewardVault's functions.
- Any address should be able to call `ClientChainGateway.fundAVSReward`.
- Only stakers should be able to call `ClientChainGateway.claimRewardFromImuachain` for their own rewards.

5.2. Token Compatibility: While the system is permissionless, it is designed to work with standard ERC20 tokens to ensure consistent behavior and accounting.

5.3. Upgradeability: 
- The beacon proxy pattern allows for upgrading the RewardVault implementation while maintaining a consistent address.
- Upgrades should be carefully managed and go through a thorough governance process to ensure security and prevent potential vulnerabilities.

## 6. Gas Optimization

6.1. Batch Operations: Consider implementing functions for batch reward funding and claims to reduce gas costs.

## 7. Upgradability

The Reward Vault should be implemented as an upgradeable contract using the OpenZeppelin Upgrades plugin. The contract owner, which will be a multisig wallet controlled by the protocol governors, will have the ability to upgrade the contract. This allows for future improvements and bug fixes while maintaining transparency and security.

## 8. Events

Emit events for all significant actions in the RewardVault contract:
- `RewardDeposited(address indexed token, address indexed avs, uint256 amount)`
- `RewardUnlocked(address indexed token, address indexed staker, uint256 amount)`
- `RewardWithdrawn(address indexed token, address indexed staker, uint256 amount)`

The ClientChainGateway contract will emit the following event (as previously defined):
- `RewardOperation(bool isFundReward, bool indexed success, bytes32 indexed token, bytes32 indexed avsOrWithdrawer, uint256 amount)` — `isFundReward` is true for fund-AVS-reward operations, false for claim-reward operations.

## 9. Future Considerations

9.1. **Emergency Withdrawal**: Consider an emergency withdrawal function for unclaimed rewards, accessible only by governance in case of critical issues.

9.2. **AVS Reward Tracking**: While the current implementation tracks locked rewards per token (not per AVS), historical deposit data can be derived from `RewardDeposited` events if per-AVS analytics are needed.

9.3. **Multiple Reward Vaults**: While currently a single Reward Vault is deployed per client chain, the beacon proxy pattern allows for easy deployment of multiple RewardVault instances (e.g., per reward asset or per AVS), each with its own storage but shared implementation.

9.4. **Generic Cross-Chain Rewards**: As described in §4.4, future iterations may:
   - Add `rewardAssetChainLzID` / `assetAddress` / `recipient` parameters to client-chain claim APIs to support explicit cross-chain reward destinations.
   - Introduce Imuachain-native reward recipients and push-based unlock flows from `ImuachainGateway` to arbitrary client chains, enabling stakers on one chain to receive rewards on different chains.