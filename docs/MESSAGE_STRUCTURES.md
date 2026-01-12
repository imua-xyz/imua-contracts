# ImuachainGateway Message Structures

This document describes the payload structures for all message types handled by `ImuachainGateway.sol`.

## Overview

All messages follow the format:
```
message = abi.encodePacked(Action, payload)
```

Where:
- `Action` is a `uint8` enum value
- `payload` is the action-specific data encoded as bytes

## Message Types

### 1. REQUEST_DEPOSIT_LST (Action = 2)

**Handler:** `handleLSTTransfer`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to deposit
    bytes32 token        // Right-padded token address (20 bytes + 12 zero bytes)
)
```

**Total Payload Size:** 96 bytes (32 + 32 + 32)

**Example:**
```typescript
const payload = ethers.solidityPacked(
    ["bytes32", "uint256", "bytes32"],
    [
        rightPadAddress("0x1234..."),  // staker
        BigInt(1000),                  // amount
        rightPadAddress("0xabcd...")   // token
    ]
);
```

---

### 2. REQUEST_WITHDRAW_LST (Action = 4)

**Handler:** `handleLSTTransfer`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to withdraw
    bytes32 token        // Right-padded token address (20 bytes + 12 zero bytes)
)
```

**Total Payload Size:** 96 bytes (32 + 32 + 32)

**Note:** Same structure as `REQUEST_DEPOSIT_LST`, distinguished by the Action enum value.

---

### 3. REQUEST_DEPOSIT_NST (Action = 3)

**Handler:** `handleNSTTransfer`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to deposit
    bytes validatorID    // Variable-length validator ID
)
```

**Total Payload Size:** 64+ bytes (32 + 32 + variable)

**Validator ID Length:**
- Ethereum: 32 bytes (validatorIndex as uint256)
- Solana: 32 bytes (pubkey)
- Sui: 96 bytes (pubkey)

**Example:**
```typescript
const validatorIDBytes = ethers.getBytes(validatorID); // hex string
const payload = ethers.solidityPacked(
    ["bytes32", "uint256", "bytes"],
    [
        rightPadAddress("0x1234..."),  // staker
        BigInt(1000),                  // amount
        validatorIDBytes               // validatorID (variable length)
    ]
);
```

---

### 4. REQUEST_WITHDRAW_NST (Action = 5)

**Handler:** `handleNSTTransfer`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount       // Amount to withdraw
)
```

**Total Payload Size:** 64 bytes (32 + 32)

**Example:**
```typescript
const payload = ethers.solidityPacked(
    ["bytes32", "uint256"],
    [
        rightPadAddress("0x1234..."),  // staker
        BigInt(500)                    // amount
    ]
);
```

---

### 5. REQUEST_DELEGATE_TO (Action = 8)

**Handler:** `handleDelegation`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to delegate
    bytes32 token,       // Right-padded token address (20 bytes + 12 zero bytes)
    bytes operator       // Bech32 operator address (exactly 41 bytes as UTF-8)
)
```

**Total Payload Size:** 137 bytes (32 + 32 + 32 + 41)

**Operator Address:**
- Must be a valid Imuachain bech32 address (e.g., `im1...`)
- Exactly 41 characters when encoded as UTF-8 bytes
- Format: `im` prefix + 39 character base32-encoded address

**Example:**
```typescript
const operatorBytes = ethers.toUtf8Bytes("im1abc123..."); // 41 bytes
const payload = ethers.solidityPacked(
    ["bytes32", "uint256", "bytes32", "bytes"],
    [
        rightPadAddress("0x1234..."),  // staker
        BigInt(1000),                  // amount
        rightPadAddress("0xabcd..."),   // token
        operatorBytes                  // operator (41 bytes)
    ]
);
```

---

### 6. REQUEST_UNDELEGATE_FROM (Action = 9)

**Handler:** `handleDelegation`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to undelegate
    bytes32 token,       // Right-padded token address (20 bytes + 12 zero bytes)
    bytes operator,      // Bech32 operator address (exactly 41 bytes as UTF-8)
    uint8 instantUnbond  // 0x00 for false, 0x01 for true (1 byte)
)
```

**Total Payload Size:** 138 bytes (32 + 32 + 32 + 41 + 1)

**Example:**
```typescript
const operatorBytes = ethers.toUtf8Bytes("im1abc123..."); // 41 bytes
const instantUnbondByte = instantUnbond ? "0x01" : "0x00";
const payload = ethers.solidityPacked(
    ["bytes32", "uint256", "bytes32", "bytes", "uint8"],
    [
        rightPadAddress("0x1234..."),  // staker
        BigInt(500),                  // amount
        rightPadAddress("0xabcd..."),   // token
        operatorBytes,                 // operator (41 bytes)
        instantUnbondByte              // instantUnbond (1 byte)
    ]
);
```

---

### 7. REQUEST_DEPOSIT_THEN_DELEGATE_TO (Action = 10)

**Handler:** `handleDepositAndDelegate`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 depositor,   // Right-padded EVM address (20 bytes + 12 zero bytes)
    uint256 amount,      // Amount to deposit and delegate
    bytes32 token,       // Right-padded token address (20 bytes + 12 zero bytes)
    bytes operator       // Bech32 operator address (variable length as UTF-8)
)
```

**Total Payload Size:** 96+ bytes (32 + 32 + 32 + variable)

**Note:** This action performs both deposit and delegate in a single transaction. The operator address can be variable length (typically 41 bytes for bech32).

**Example:**
```typescript
const operatorBytes = ethers.toUtf8Bytes("im1abc123...");
const payload = ethers.solidityPacked(
    ["bytes32", "uint256", "bytes32", "bytes"],
    [
        rightPadAddress("0x1234..."),  // depositor
        BigInt(1000),                  // amount
        rightPadAddress("0xabcd..."),   // token
        operatorBytes                  // operator (variable length)
    ]
);
```

---

### 8. REQUEST_ASSOCIATE_OPERATOR (Action = 12)

**Handler:** `handleOperatorAssociation`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker,      // Right-padded EVM address (20 bytes + 12 zero bytes)
    bytes operator       // Bech32 operator address (variable length as UTF-8)
)
```

**Total Payload Size:** 32+ bytes (32 + variable)

**Example:**
```typescript
const operatorBytes = ethers.toUtf8Bytes("im1abc123...");
const payload = ethers.solidityPacked(
    ["bytes32", "bytes"],
    [
        rightPadAddress("0x1234..."),  // staker
        operatorBytes                  // operator (variable length)
    ]
);
```

---

### 9. REQUEST_DISSOCIATE_OPERATOR (Action = 13)

**Handler:** `handleOperatorAssociation`

**Payload Structure:**
```
payload = abi.encodePacked(
    bytes32 staker       // Right-padded EVM address (20 bytes + 12 zero bytes)
)
```

**Total Payload Size:** 32 bytes

**Example:**
```typescript
const payload = ethers.solidityPacked(
    ["bytes32"],
    [
        rightPadAddress("0x1234...")   // staker
    ]
);
```

---

## Helper Functions

### Address Right-Padding

EVM addresses (20 bytes) must be right-padded to 32 bytes for use in `bytes32` fields:

```typescript
function rightPadAddress(addr: string): string {
    const cleanAddr = addr.replace(/^0x/i, "");
    if (cleanAddr.length !== 40) {
        throw new Error(`Invalid address length: ${addr}`);
    }
    return "0x" + cleanAddr + "0".repeat(24); // 20 bytes + 12 zero bytes
}
```

### Operator Address Encoding

Bech32 operator addresses must be converted to UTF-8 bytes:

```typescript
const operatorBytes = ethers.toUtf8Bytes("im1abc123...");
// For 41-character bech32 addresses, this produces exactly 41 bytes
```

---

## Message Dependencies

Some message types require prerequisites to be executed on-chain first:

| Message Type | Prerequisites |
|-------------|---------------|
| `REQUEST_DELEGATE_TO` | `REQUEST_DEPOSIT_LST` |
| `REQUEST_UNDELEGATE_FROM` | `REQUEST_DEPOSIT_LST`, `REQUEST_DELEGATE_TO` |
| `REQUEST_WITHDRAW_LST` | `REQUEST_DEPOSIT_LST`, `REQUEST_DELEGATE_TO`, `REQUEST_UNDELEGATE_FROM` |
| `REQUEST_WITHDRAW_NST` | `REQUEST_DEPOSIT_NST` |
| `REQUEST_DISSOCIATE_OPERATOR` | `REQUEST_ASSOCIATE_OPERATOR` |

---

## Action Enum Values

```solidity
enum Action {
    RESPOND = 0,
    REQUEST_ADD_WHITELIST_TOKEN = 1,
    REQUEST_DEPOSIT_LST = 2,
    REQUEST_DEPOSIT_NST = 3,
    REQUEST_WITHDRAW_LST = 4,
    REQUEST_WITHDRAW_NST = 5,
    REQUEST_SUBMIT_REWARD = 6,
    REQUEST_CLAIM_REWARD = 7,
    REQUEST_DELEGATE_TO = 8,
    REQUEST_UNDELEGATE_FROM = 9,
    REQUEST_DEPOSIT_THEN_DELEGATE_TO = 10,
    REQUEST_MARK_BOOTSTRAP = 11,
    REQUEST_ASSOCIATE_OPERATOR = 12,
    REQUEST_DISSOCIATE_OPERATOR = 13
}
```

---

## Notes

1. **Address Encoding:** All EVM addresses must be right-padded to 32 bytes when used in `bytes32` fields.

2. **Operator Addresses:** Bech32 operator addresses are encoded as UTF-8 bytes. For standard Imuachain addresses (41 characters), this results in exactly 41 bytes.

3. **Validator IDs:** NST validator IDs have variable length depending on the source chain (Ethereum: 32 bytes, Solana: 32 bytes, Sui: 96 bytes).

4. **Response Messages:** Some actions return responses (e.g., `REQUEST_WITHDRAW_LST` returns `abi.encodePacked(lzNonce, success)`), while others return empty bytes.

5. **Nonce Management:** Each message must use a unique nonce per source chain and sender address. The gateway tracks inbound nonces to prevent replay attacks.

---

## References

- `ImuachainGateway.sol` - Main gateway contract
- `GatewayStorage.sol` - Action enum and storage definitions
- `test-delegation-gas-bound.ts` - Test script with example implementations
