# **XRP Bootstrap Transaction Format Specification for Imua Staking**

## **Overview**

This specification defines the required transaction format for XRP bootstrap staking transactions in the Imua system using **GemWallet** or **Xumm Wallet**. During the bootstrap phase, all deposit transactions must strictly follow this format to be considered valid by the system. The key components include the **Vault address**, **Destination Tag**, and **Memo** field, which contains both the Imua EVM address and validator information for staking delegation.

---

## **Transaction Structure Requirements**

### **1. Vault Address**

- **Recipient**: The designated Vault address for XRP deposits.
- **Address**: `rVaultAddress` (Replace with the actual Vault address).
- **Amount**: Must be >= the minimum required amount for staking.

### **2. Destination Tag**

- **Value**: `9999` (Fixed value for all Imua staking deposits).
- **Purpose**: Used to identify the transaction as an Imua staking deposit.
- **Requirement**: Must be provided in all transactions.

### **3. Memo Field**

- **Format**: The memo payload is an 81-byte UTF-8 string containing Imua EVM address + validator address (during bootstrap phase)
- **Encoding Note**: On XRPL, `MemoType` / `MemoData` are represented as **hex strings** in JSON (`rippled` / explorers). Wallets (e.g. GemWallet) may let you enter the **plain text payload**, and will encode it to hex before submitting the transaction.
- **Purpose**: Maps the XRP deposit to the corresponding Imua EVM address and specifies the validator for delegation
- **Requirement**: Required for all bootstrap transactions
- **Structure**:
  - **MemoType**: Must be `4465736372697074696F6E` (hex for "Description")
  - **MemoData**: Hex string representing the UTF-8 bytes of the following 81-byte plain text payload (`memo_plain`):
    - First 40 characters: Imua EVM address (20 bytes as 40 hex characters, **without** `0x` prefix)
    - Last 41 characters: Validator address (bech32 format with `im` prefix)
- **Example**:
  - Imua EVM Address: `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
  - Validator Address: `im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8` (41 characters)
  - Plain text payload (`memo_plain`, 81 chars): `70997970C51812dc3A010C7d01b50e0d17dc79C8im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8`
  - MemoData (hex): `37303939373937304335313831326463334130313043376430316235306530643137646337394338696d31633578376d787068766761766a6875306175396a6a716e667163797370657674353666786538`

---

## **Bootstrap Phase Rules**

### **1. Bootstrap Requirements**

- **Bootstrap Phase**: During the bootstrap phase, all XRP deposits are treated as staking delegation transactions
- **Validator Registration**: The validator specified in the memo must be registered in the bootstrap contract
- **Memo Required**: The memo field is mandatory for all bootstrap transactions and must contain both Imua EVM address and validator address

### **2. Address Binding Rules**

- **Bidirectional One-to-One Binding**: The system enforces a bidirectional 1-1 binding:
  - One XRP address (sender) can only map to one Imua EVM address
  - One Imua EVM address can only be mapped from one XRP address (sender)
- **Earliest Valid Transaction Wins (First-Wins)**: For each XRP sender, the binding is established by the **earliest valid** deposit transaction observed by the bootstrap processor, ordered by:
  - `ledger_index` ascending (smaller ledger first)
  - then `TransactionIndex` ascending within the same ledger
  Once established, the binding is **immutable** and cannot be changed.
- **Consistency Check (Same Sender)**: Any subsequent deposit transaction from the same XRP sender that carries an Imua EVM address **different from the first bound address** will be treated as **invalid** (rejected/ignored) and will not affect the binding.
- **Uniqueness Check (Different Senders)**: Different XRP senders are **not allowed** to bind to the same Imua EVM address. If an Imua EVM address is already bound by an earlier valid transaction, any later deposit transaction attempting to bind that same Imua EVM address from a different sender will be treated as **invalid** (rejected/ignored).

### **3. Validator Requirements**

- **Registration Check**: The validator address must be registered in the bootstrap contract before the transaction can be accepted
- **Valid Format**: Validator address must be a valid bech32 address with 'im' prefix and exactly 41 characters long
- **Delegation**: All bootstrap transactions automatically delegate the staked amount to the specified validator

---

## **Validation Process**

The system validates XRP bootstrap transactions with the following steps:

1. **Transaction Validation**:

   - Verifies the transaction is validated on the XRP Ledger
   - Confirms transaction type is "Payment"
   - Checks transaction result is "tesSUCCESS"
   - Ensures the transaction has the required number of confirmations (default: 6)
2. **Address Validation**:

   - Confirms the destination address matches the designated Vault address
   - Verifies the transaction is not a self-transfer from the vault
   - Validates the transaction amount meets the minimum requirement (default: 50 XRP)
3. **Destination Tag Validation**:

   - Ensures the Destination Tag is exactly `9999`
4. **Memo Validation**:

   - Validates MemoType is `4465736372697074696F6E` ("Description" in hex)
   - Hex-decodes MemoData and checks the decoded UTF-8 payload length is exactly 81 bytes (40 + 41)
   - Validates Imua EVM address format (40 hex characters, valid Ethereum address)
   - Validates validator address format (41 characters, valid bech32 with 'im' prefix)
5. **Validator Registration Check**:

   - Queries the bootstrap contract to verify the validator is registered
   - Confirms the validator has a valid name and registration status
6. **Address Mapping Validation**:

   - For first-time XRP addresses: Establishes new bidirectional mapping
   - For existing XRP addresses: Validates consistency with previous mapping
   - Rejects transactions that attempt to change existing address bindings

---

## **Example Transactions**

### **Bootstrap Staking Transaction**

- **Vault Address**: `rVaultAddress`
- **Amount**: `50 XRP` (minimum 50 XRP)
- **Destination Tag**: `9999` (Required)
- **Memo**: Contains both Imua EVM address and validator address

### **Transaction JSON**

```json
{
  "TransactionType": "Payment",
  "Account": "rSenderAddress",
  "Destination": "rVaultAddress",
  "Amount": "100000000",
  "DestinationTag": 9999,
  "Memos": [
    {
      "Memo": {
        "MemoType": "4465736372697074696F6E",
        "MemoData": "37303939373937304335313831326463334130313043376430316235306530643137646337394338696d31633578376d787068766761766a6875306175396a6a716e667163797370657674353666786538"
      }
    }
  ]
}
```

### **Memo Data Breakdown**

- **MemoType**: `4465736372697074696F6E` (hex for "Description")
- **MemoData (hex)**: `37303939373937304335313831326463334130313043376430316235306530643137646337394338696d31633578376d787068766761766a6875306175396a6a716e667163797370657674353666786538`
- **Decoded plain text payload (`memo_plain`)**: `70997970C51812dc3A010C7d01b50e0d17dc79C8im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8`
  - **Imua EVM Address**: `70997970C51812dc3A010C7d01b50e0d17dc79C8` (40 characters, no `0x` prefix)
  - **Validator Address**: `im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8` (41 characters, bech32 format)

---

## **Implementation Notes**

### **Using GemWallet**

1. Open GemWallet and select **Send XRP**.
2. Enter the **Vault Address** as the recipient.
3. Set the **Amount** to at least 50 XRP (minimum required).
4. Set the **Destination Tag** to `9999` (Required).
5. In the **Memo** field:
   - **MemoType**: Enter `4465736372697074696F6E`
   - **Plain text payload (`memo_plain`)**: Enter your Imua EVM address (40 hex chars, no `0x`) + validator address (41 chars)
   - **Example**: `70997970C51812dc3A010C7d01b50e0d17dc79C8im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8`
6. Confirm and send the transaction.

### **Using Xumm Wallet**

1. Open Xumm Wallet and select **Send XRP**.
2. Enter the **Vault Address** as the recipient.
3. Set the **Amount** to at least 50 XRP (minimum required).
4. Set the **Destination Tag** to `9999` (Required).
5. In the **Memo** field:
   - **MemoType**: Enter `4465736372697074696F6E`
   - **Plain text payload (`memo_plain`)**: Enter your Imua EVM address (40 hex chars, no `0x`) + validator address (41 chars)
   - **Example**: `70997970C51812dc3A010C7d01b50e0d17dc79C8im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8`
6. Confirm and sign the transaction.

### **Important Notes**

- **No 0x Prefix**: Do not include the "0x" prefix in the Imua EVM address within the memo
- **Exact Length**: The decoded plain text payload (`memo_plain`) must be exactly 81 characters (40 + 41). On-chain JSON shows `MemoData` as hex (162 hex characters for this payload).
- **Validator Registration**: Ensure the validator is registered before sending the transaction
- **Address Consistency**: Use the same Imua EVM address for all transactions from the same XRP address

---

## **Transaction Validation Results**

- **Success**: The transaction is processed and the XRP amount is delegated to the specified validator on behalf of the Imua EVM address
- **Validation Failures**:
  - **Invalid Memo Format**: Transaction rejected due to incorrect memo structure or missing components
  - **Unregistered Validator**: Transaction rejected because the validator is not registered in the bootstrap contract
  - **Address Binding Conflict**: Transaction rejected due to inconsistent address mapping
  - **Insufficient Amount**: Transaction rejected if below the minimum staking requirement
  - **Invalid Destination Tag**: Transaction rejected if destination tag is not 9999

---

## **Conclusion**

This specification ensures a standardized and secure process for XRP bootstrap staking in the Imua system. During the bootstrap phase, all transactions must include both the Imua EVM address and validator information in the memo field. The **one-to-one address binding rule** guarantees the immutability of address mappings, while the **validator delegation mechanism** enables automatic staking distribution to registered validators, ensuring the integrity and security of the bootstrap staking process.
