# ClientChainGateway Documentation

The ClientChainGateway serves as the primary interface for stakers to interact with Imua. It functions as a LayerZero application capable of cross-chain messaging and manages both Vault and Capsule contracts.

## Overview

ClientChainGateway implements two types of restaking:
1. LST (Liquid Staking Token) Restaking
2. NST (Native Staking Token) Restaking

## LST Restaking Functions

### Deposit Operations
- `deposit(address token, uint256 amount)`
  - Deposits whitelisted tokens into Imua
  - Locks tokens in a Vault contract
  - Sends cross-chain message to Imuachain for accounting
  - Always considered successful on Imuachain
  - Requires relay fee in ETH for cross-chain message

- `depositThenDelegateTo(address token, uint256 amount, string operator)`
  - Combines deposit and delegate operations
  - Deposits tokens and immediately delegates to specified operator
  - More gas-efficient than separate calls
  - Delegation can fail if operator is not registered
  - Requires relay fee in ETH for cross-chain message

### Delegation Operations
- `delegateTo(string operator, address token, uint256 amount)`
  - Delegates previously deposited tokens to an operator
  - Requires prior deposit
  - Sends cross-chain message to Imuachain
  - Updates delegation accounting on Imuachain
  - Requires relay fee in ETH for cross-chain message

- `undelegateFrom(string operator, address token, uint256 amount)`
  - Undelegates tokens from an operator
  - Requires prior delegation
  - Sends cross-chain message to Imuachain
  - Initiates unbonding period
  - Requires relay fee in ETH for cross-chain message

### Withdrawal Operations
- `claimPrincipalFromImuachain(address token, uint256 principalAmount)`
  - Initiates withdrawal process from Imuachain
  - Sends cross-chain message to Imuachain
  - Awaits response to unlock balance in Vault
  - Does not transfer tokens to user
  - Requires relay fee in ETH for cross-chain message

- `withdrawPrincipal(address token, uint256 amount, address recipient)`
  - Transfers unlocked tokens from Vault to recipient
  - Must be called after successful `claimPrincipalFromImuachain`
  - No cross-chain message required
  - Direct transfer from Vault
  - No relay fee needed

## NST Restaking Functions

### Setup Operations
- `createImuaCapsule()`
  - Creates Capsule contract for staker
  - Used as withdrawal credentials
  - Required before staking to beacon chain
  - Returns capsule address
  - No relay fee needed

- `stake(bytes pubkey, bytes signature, bytes32 depositDataRoot)`
  - Stakes ETH to Ethereum beacon chain
  - Creates validator with ImuaCapsule as withdrawal credentials
  - Preparation step for NST restaking
  - Payable function accepting exactly 32 ETH for beacon chain staking
  - No relay fee needed

### Deposit Operations
- `verifyAndDepositNativeStake(bytes32[] validatorContainer, BeaconChainProofs.ValidatorContainerProof proof)`
  - Verifies beacon chain proof of withdrawal credentials
  - Confirms validator is using correct ImuaCapsule
  - Sends message to Imuachain to account for validator balance
  - Required for NST restaking activation
  - Requires relay fee in ETH for cross-chain message

### Withdrawal Operations
- `processBeaconChainWithdrawal(bytes32[] validatorContainer, BeaconChainProofs.ValidatorContainerProof validatorProof, bytes32[] withdrawalContainer, BeaconChainProofs.WithdrawalProof withdrawalProof)`
  - Processes beacon chain withdrawals
  - Verifies withdrawal proofs
  - Sends message to Imuachain to unlock ETH in Capsule
  - Similar to `claimPrincipalFromImuachain` for LSTs
  - Requires relay fee in ETH for cross-chain message

- `withdrawNonBeaconChainETHFromCapsule(address payable recipient, uint256 amountToWithdraw)`
  - Withdraws non-beacon chain ETH from Capsule
  - For ETH not related to beacon chain staking
  - Direct transfer from Capsule
  - No relay fee needed

## Common Workflows

### LST Deposit and Delegate
1. Call `deposit` or `depositThenDelegateTo`
2. If using separate calls, wait for deposit confirmation
3. Call `delegateTo` if needed
4. Tokens are now staked and delegated on Imua

### LST Withdrawal
1. Call `claimPrincipalFromImuachain`
2. Wait for cross-chain message confirmation
3. Call `withdrawPrincipal` to receive tokens

### NST Restaking
1. Call `createImuaCapsule`
2. Call `stake` to become validator
3. Call `verifyAndDepositNativeStake` with proofs
4. ETH is now restaked on Imua

### NST Withdrawal
1. Initiate withdrawal on beacon chain
2. Call `processBeaconChainWithdrawal` with proofs
3. ETH is unlocked in Capsule
4. Use `withdrawNonBeaconChainETHFromCapsule` if needed

## Notes
- All cross-chain operations require LayerZero fees in ETH
- `stake` function requires exactly 32 ETH for beacon chain staking
- Other payable functions only accept ETH for relay fees
- NST operations require valid beacon chain proofs
- Delegation requires registered operators on Imuachain
