# Bitcoin Genesis Generation for Imuachain

## Overview

This document outlines the process of generating the Imuachain genesis state from Bitcoin transactions. The process involves scanning the Bitcoin blockchain for valid stake transactions, validating them, and generating a genesis state that can be used to initialize the Imuachain blockchain.

## Process Flow

1. **Scan Bitcoin Blockchain**: Identify transactions sent to a designated vault address
2. **Validate Transactions**: Ensure transactions meet the required format and criteria
3. **Extract Stake Information**: Parse transaction data to extract stake details
4. **Generate Genesis State**: Create a complete genesis state for Imuachain initialization

## Transaction Format Specification

### Valid Stake Transaction Requirements

A valid Bitcoin stake transaction must:

1. Be confirmed with at least N confirmations (configurable, default: 6)
2. Not originate from the vault address
3. Contain exactly one output to the vault address with amount ≥ minimum stake (configurable, default: 0.1 BTC)
4. Contain exactly one OP_RETURN output with the following format:
   - Prefix: `6a3D` (OP_RETURN with length followed by 61 bytes of data)
   - First 20 bytes: Imuachain address (hex format)
   - Remaining 41 bytes: Validator address (bech32 format with 'im' prefix)
5. Have the validator registered in the bootstrap contract

### Transaction Data Extraction

From each valid transaction, we extract:

- Transaction ID (`txid`)
- Block height
- Transaction index in block
- Bitcoin sender address
- Imuachain address (from OP_RETURN)
- Validator address (from OP_RETURN)
- Stake amount (BTC sent to vault)
- Timestamp

## Genesis State Generation

The genesis state is generated with the following modules:

### 1. Assets Module

- **Client Chain**: Bitcoin chain configuration
  - Name: "Bitcoin"
  - Layer Zero Chain ID: 101 (configurable)
  - Finalization blocks: 6 (configurable)

- **Tokens**: BTC token configuration
  - Virtual address: 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB
  - Symbol: "BTC"
  - Decimals: 8

- **Deposits**: For each stake transaction
  - Staker ID: `{evm_address_set_by_staker}_{chain_id_hex}`
  - Asset ID: `{btc_virtual_address}_{chain_id_hex}`
  - Amount: Stake amount
  - Withdrawable amount: 0 (all stakes must be delegated to a validator)
  - Deposits are grouped first by staker_id and then by asset_id

- **Operator Assets**: For each validator
  - Operator: Validator address
  - Total amount: Sum of all stakes for this validator
  - Total share: Equal to total amount
  - Operator share: 0 (operators don't have their own stake in bootstrap)

### 2. Delegation Module

- **Associations**: Empty for Bitcoin genesis
  - Unlike EVM-based chains, Bitcoin stakers don't have direct associations with validators
  - All associations are created through the stake transaction OP_RETURN data

- **Delegation States**: For each stake
  - Key: `{staker_id}/{asset_id}/{validator_address}`
  - Undelegatable share: Stake amount
  - Wait undelegation amount: 0

- **Stakers by Operator**: Groups stakers by validator
  - Key: `{validator_address}/{asset_id}`
  - Stakers: Array of staker IDs

### 3. Dogfood Module

- **Parameters**:
  - Asset IDs: Array containing BTC asset ID
  - Max validators: Configurable via environment variable (default: 100)

- **Validator Set**: For top N validators by power
  - Public key: Validator address
  - Power: Calculated based on BTC price in USD
  - Only top N validators by power are included, where N is max_validators

- **Last Total Power**: Sum of all included validator powers

### 4. Oracle Module

- **Tokens**: BTC token configuration for oracle
  - Name: "BTC"
  - Chain ID: 1 (Bitcoin mainnet)
  - Contract address: BTC virtual address
  - Asset ID: `{btc_virtual_address}_{chain_id_hex}`
  - Decimal: 8

- **Staker List Assets**: List of all stakers by asset
  - Asset ID: BTC asset ID
  - Staker addresses: Array of Bitcoin addresses

- **Staker Info Assets**: Detailed staker information
  - Staker address: Bitcoin address
  - Validator pubkey list: Array containing validator address
  - Balance list: Initial deposit with ACTION_DEPOSIT change type

## Validation and Sorting

To ensure deterministic output:

1. All arrays are sorted (typically by ID or key)
2. Validators are sorted by power (descending)
3. In case of equal power, validators are sorted lexicographically by public key (using `localeCompare`)

## Security Considerations

1. **Transaction Validation**: Strict validation prevents invalid stakes
2. **Validator Registration**: Only registered validators are accepted
3. **Minimum Stake**: Enforces minimum stake amount
4. **Confirmation Requirement**: Ensures transactions are confirmed
5. **Address Format Validation**: Validates both Bitcoin and Imuachain addresses

## Configuration Parameters

The genesis generation process is configurable with the following parameters:

1. **BTC Vault Address**: The Bitcoin address receiving stake transactions
2. **Minimum Confirmations**: Required confirmations for transactions (default: 6)
3. **Minimum Stake Amount**: Minimum BTC required (default: 0.1 BTC)
4. **Bootstrap Contract Address**: Address of the validator registry contract
5. **Chain ID**: Imuachain chain ID (default: "imua-1")
6. **Layer Zero Chain ID**: Bitcoin's Layer Zero chain ID (default: 101)
7. **Max Validators**: Maximum number of validators to include (default: 100)
8. **BTC Price USD**: BTC price in USD for voting power calculation
