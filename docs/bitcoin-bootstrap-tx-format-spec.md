# Bitcoin Bootstrap Transaction Format Specification for Imuachain

## Overview

This specification defines the required transaction format for staking BTC during the Imuachain bootstrap phase.
All bootstrap staking transactions must strictly follow this format to be considered valid by the system.

## Transaction Structure Requirements

### Inputs

- Must have one or more inputs
- No inputs can be from the vault address
- First input's address is considered the depositor's Bitcoin address

### Outputs

Must include the following required outputs (in any order):

1. **Vault Output**
   - Recipient: Vault address
   - Amount: Must be >= minimum required amount
   - Exactly one vault output allowed

2. **OP_RETURN Output**
   - Contains future Imuachain address and validator address (required for bootstrap)
   - Format: `OP_RETURN <length> <20-byte Imuachain address> <41-byte validator address as UTF-8>`
   - Scriptpubkey format:
     - `6a`: OP_RETURN
     - Length byte: `3D` (61) for bootstrap stake (always includes validator)
     - First 20 bytes: Future Imuachain address in raw bytes
     - Next 41 bytes: Validator address in bech32 format as UTF-8 bytes
   - Examples:

     ```bash
     HEX: 6a3d7d8bf59ba2e0b64bc4620a08844d34e2c56f9c3c696d31336861737234337676713876343478707a68306c367975796d346b636139386638376a376163
     Display in wallet/explorer:
       - 20 bytes (Imuachain): 7d8bf59ba2e0b64bc4620a08844d34e2c56f9c3c
       - 41 bytes (Validator): im13hasr43vvq8v44xpzh0l6yuym4kca98f87j7ac
     ```

3. **Change Output(s)** (Optional)
   - Any additional outputs are allowed for change
   - Can send change back to sender or any other address

## Validation Rules

### Address Mapping Policy

#### First-time Stakes

- If the Bitcoin address has no previous bootstrap stakes:
  - The OP_RETURN output establishes the Bitcoin → Imuachain address mapping
  - This mapping is permanent and cannot be changed
  - The system will record this mapping during genesis generation

#### Subsequent Stakes

- If the Bitcoin address has previous bootstrap stakes:
  - OP_RETURN must contain the same Imuachain address as initially staked
  - Any mismatch will cause the transaction to be ignored during genesis
  - The stake will only be counted if the Imuachain address matches

#### Address Change Policy

- Address mappings are permanent and immutable
- To use a different Imuachain address:
  - Must use a new Bitcoin address
  - Must perform a new stake from that address
- No exceptions to this policy during bootstrap phase

### Transaction Validation

1. Must have at least one input
2. No input can be from the vault address
3. Must have exactly one vault output with sufficient amount
4. Must have exactly one OP_RETURN output
5. OP_RETURN payload must be exactly 61 bytes (20 + 41),
   resulting in a 63-byte scriptPubKey when the 0x6a opcode and length byte are included.
6. Validator address must be registered in bootstrap contract
7. For subsequent stakes from same Bitcoin address:
   - Imuachain address must match the first stake's address
   - Any mismatch invalidates the transaction for genesis

### Address Format Requirements

1. Imuachain address must be exactly 20 bytes
2. Validator address must be exactly 41 bytes in bech32 format
3. Validator address must be registered in bootstrap contract
4. Addresses must be properly encoded

## Genesis Generation Process

The system processes bootstrap transactions by:

1. Scanning vault's transaction history
2. Verifying transaction format compliance
3. Validating validator registration
4. Recording stake amount and delegation
5. Including in genesis state

## Important Notes

1. All bootstrap stakes must specify a validator
2. The format is stricter than post-bootstrap UTXOGateway format
3. Invalid transactions will be ignored during genesis generation
4. No immediate feedback on transaction validity
5. Stake amounts are determined by vault output value

## Future Compatibility

This format is designed to be compatible with post-bootstrap UTXOGateway with these differences:

**Bootstrap Phase:**

- Validator address is mandatory
- Format always includes both addresses
- Size is always 63 bytes (op code + length + 20 + 41)
- All stakes must be delegated to a validator

**Post-Bootstrap (UTXOGateway):**

- Operator address is optional
- Two possible formats:
  1. Deposit only: `OP_RETURN <length> <20-byte Imuachain address>`
  2. Deposit with delegation: `OP_RETURN <length> <20-byte Imuachain address> <41-byte operator address>`
- Size is either 22 bytes or 63 bytes
- Delegation to operator is optional
