# Client Address Representation for UTXOGateway

## Overview

This document describes how different blockchain address formats are represented within the UTXOGateway system. The gateway uses a standardized representation to handle various address formats across different UTXO-based blockchains.

## Generic Address Representation

### Storage Format

All client addresses are stored in the following format:

1. **clientAccountId** (`bytes32`): The address identifier data
2. **clientAccountType** (`uint8`): A type identifier for the address format

The UTXOGateway contract maintains a mapping between `clientAccountId` and `clientAccountType` internally, while only the `clientAccountId` is passed to Imuachain precompiles.

### Registration

When registering a client chain:
- All UTXO-based chains use a 32-byte address length
- This accommodates both 20-byte hashes and 32-byte hashes/keys
- 20-byte hashes are padded with zeros when necessary

### Processing Logic

1. UTXOGateway validates address data based on the `clientAccountType`
2. When calling Imuachain precompiles, only the `clientAccountId` is used as the staker ID (combined with client chain ID)
3. The precompiles treat the `clientAccountId` as a unique identifier for the staker, agnostic to the original address format
4. For peg-out operations, the gateway retrieves the associated `clientAccountType` to determine the correct address format for reconstruction

## Bitcoin-Specific Address Types

### Type Identifiers

| clientAccountType | Address Format | Description | Data Stored in clientAccountId |
|-------------------|----------------|-------------|--------------------------------|
| 1 | P2PKH | Legacy address (starts with "1") | 20-byte RIPEMD-160 hash of public key |
| 2 | P2SH | Script hash address (starts with "3") | 20-byte RIPEMD-160 hash of script |
| 3 | P2WPKH | SegWit v0 key hash (starts with "bc1q") | 20-byte RIPEMD-160 hash of public key |
| 4 | P2WSH | SegWit v0 script hash (starts with "bc1q") | 32-byte SHA-256 hash of script |
| 5 | P2TR | Taproot address (starts with "bc1p") | 32-byte x-coordinate of tweaked public key |

### Address Data Extraction

When processing Bitcoin transactions:

1. **Base58Check addresses** (P2PKH, P2SH):
   - Extract hash using `fromBase58Check` function
   - Store the returned 20-byte hash in `clientAccountId`
   - Set `clientAccountType` to 1 or 2 accordingly

2. **Bech32/Bech32m addresses** (P2WPKH, P2WSH, P2TR):
   - Extract data using `fromBech32` function
   - For P2WPKH: Store 20-byte hash in `clientAccountId`
   - For P2WSH/P2TR: Store full 32-byte hash/x-coordinate in `clientAccountId`
   - Set `clientAccountType` to 3, 4, or 5 accordingly

### Address Reconstruction

For peg-out operations:

1. **P2PKH** (type 1):
   - Use Base58Check encoding with version 0x00
   - `toBase58Check(clientAccountId[0:20], 0x00)`

2. **P2SH** (type 2):
   - Use Base58Check encoding with version 0x05
   - `toBase58Check(clientAccountId[0:20], 0x05)`

3. **P2WPKH** (type 3):
   - Use Bech32 encoding with version 0
   - `toBech32(clientAccountId[0:20], 0, "bc")`

4. **P2WSH** (type 4):
   - Use Bech32 encoding with version 0
   - `toBech32(clientAccountId, 0, "bc")`

5. **P2TR** (type 5):
   - Use Bech32m encoding with version 1
   - `toBech32(clientAccountId, 1, "bc")`

### Account Identity

The UTXOGateway system uses `clientAccountId` (bytes32) as the unique identifier for accounts:

1. For each client chain address, a hash or key data (up to 32 bytes) is extracted
2. This data uniquely identifies the controlling authority for that address
3. The `clientAccountId` is passed to Imuachain precompiles to identify the staker and their assets
4. The probability of two different authorities having the same `clientAccountId` is negligible due to the collision-resistant properties of the underlying cryptographic hash functions

The `clientAccountType` is stored alongside `clientAccountId` within the UTXOGateway contract but is used only for:
- Address format validation
- Address reconstruction during withdrawals
- Handling chain-specific address formats

### Important Considerations

1. Users must withdraw to the same address format they deposited from
2. Although different address formats for the same logical entity are theoretically possible, they are treated as separate accounts in the system
3. The precompile layer is agnostic to address format details, operating solely on the `clientAccountId`

## Future Chain Support

### Dogecoin

Dogecoin follows Bitcoin's address format with different version bytes:
- Map to types 1-3 as appropriate (P2PKH, P2SH, P2WPKH)
- Use chain-specific prefixes for address reconstruction

### Litecoin

Similar to Bitcoin with different version bytes and prefixes:
- Map to types 1-5 as appropriate
- Use chain-specific prefixes for address reconstruction

### Ripple (XRP)

For XRP addresses:
- Use clientAccountType values starting from 50
- Store the Account ID (20 bytes) in clientAccountId
- Adapt encoding/decoding for XRP's Base58 dictionary

## Implementation Notes

1. When implementing support for a new UTXO chain, define appropriate `clientAccountType` values
2. Ensure proper validation based on the expected data length for each type
3. Document the mapping between `clientAccountType` values and native address formats
4. For chains with address formats longer than 32 bytes, consider alternative representation strategies
5. The precompile integration relies on `clientAccountId` as the sole identifier for a staker, while format-specific details remain in the UTXOGateway contract