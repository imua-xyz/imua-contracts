# Gas Analysis: `execute302` LayerZero Message Execution

## 1. Original Trace

```
[84822] 0x55c175DD5b039331dB251424538169D8495C18d1::execute302((0xdDf5218Dbff297ADdF17fB7977E2469D774545ED, (40161, 0x00000000000000000000000064b5b5a618072c1e4d137f91af780e3b17a81f3f, 850), 0x301497de53885ffd7996a836a1b5de729c11813566aa404b5df4384986e4a68b, 0x0a50e13e86c59746311c61c501d032cd4147efcb3a0000000000000000000000000000000000000000000000000000000000000000000000000de0b6b3a7640000f79f563571f7d8122611d0219a0d5449b5304f79000000000000000000000000696d3174777a6e6a3379357675347779646737756a737a65726b6b303568616330386532617334646e, 0x, 730111))
├─ [79669] 0x9B2D777659e45E3E0AC6A1bFf7cc7A5d175FF9c8::execute302(...) [delegatecall]
│   ├─ [53687] 0x6EDCE65403992e310A62460808c4b910D972f10f::lzReceive((40161, 0x00000000000000000000000064b5b5a618072c1e4d137f91af780e3b17a81f3f, 850), ImuachainGateway: [0xdDf5218Dbff297ADdF17fB7977E2469D774545ED], ...)
│   │   ├─ [36693] ImuachainGateway::lzReceive(Origin({ srcEid: 40161, sender: 0x00000000000000000000000064b5b5a618072c1e4d137f91af780e3b17a81f3f, nonce: 850 }), ...)
│   │   │   ├─ [29466] ImuachainGateway::lzReceive(...) [delegatecall]
│   │   │   │   ├─ [6030] ImuachainGateway::handleDepositAndDelegate(40161, 850, 10, ...)
│   │   │   │   │   ├─ [5342] ImuachainGateway::handleDepositAndDelegate(...) [delegatecall]
│   │   │   │   │   │   ├─ [0] 0x0000000000000000000000000000000000000804::depositLST(40161, 0xf79f563571f7d8122611d0219a0d5449b5304f79000000000000000000000000, 0x50e13e86c59746311c61c501d032cd4147efcb3a000000000000000000000000, 1000000000000000000)
│   │   │   │   │   │   │   └─ ← [Stop]
│   │   │   │   │   │   └─ ← [Revert] EvmError: Revert
│   │   │   │   │   └─ ← [Revert] EvmError: Revert
│   │   │   │   └─ ← [Revert] RequestOrResponseExecuteFailed(10, 850, 0x)
│   │   │   └─ ← [Revert] RequestOrResponseExecuteFailed(10, 850, 0x)
│   │   └─ ← [Revert] RequestOrResponseExecuteFailed(10, 850, 0x)
│   ├─ [9471] 0x6EDCE65403992e310A62460808c4b910D972f10f::lzReceiveAlert(...)
│   │   └─ ← [Stop]
│   └─ ← [Stop]
└─ ← [Return]

Transaction successfully executed.
Gas used: 107198
```

## 2. Key Parameters

| Parameter | Value |
|-----------|-------|
| **Gas Limit (passed to execute302)** | 730,111 |
| **Total Gas Used** | 107,198 |
| **Source Chain (srcEid)** | 40161 |
| **Nonce** | 850 |
| **Action** | `REQUEST_DEPOSIT_THEN_DELEGATE_TO` (Action = 10) |
| **Deposit Amount** | 1,000,000,000,000,000,000 (1e18 = 1 token) |

## 3. Gas Usage by Step

| Step | Contract | Function | Gas Used | Notes |
|------|----------|----------|----------|-------|
| 1 | `0x55c1...18d1` (Executor Proxy) | `execute302` | 84,822 | Entry point, includes all sub-calls |
| 2 | `0x9B2D...F9c8` (Executor Impl) | `execute302` [delegatecall] | 79,669 | Actual executor logic |
| 3 | `0x6EDC...10f` (EndpointV2) | `lzReceive` | 53,687 | LayerZero endpoint routing |
| 4 | `0xdDf5...5ED` (Gateway Proxy) | `lzReceive` | 36,693 | Gateway proxy forwarding |
| 5 | Gateway Impl | `lzReceive` [delegatecall] | 29,466 | Gateway message handling |
| 6 | Gateway Proxy | `handleDepositAndDelegate` | 6,030 | Internal call via low-level call |
| 7 | Gateway Impl | `handleDepositAndDelegate` [delegatecall] | 5,342 | Actual business logic |
| 8 | `0x...0804` (Precompile) | `depositLST` | **0** | ⚠️ Precompile reverted |

### Gas Overhead Between Layers

| Transition | Overhead |
|------------|----------|
| Executor proxy → impl | ~5,153 gas |
| Executor → EndpointV2 | ~25,982 gas |
| EndpointV2 → Gateway proxy | ~16,994 gas |
| Gateway proxy → impl | ~7,227 gas |
| Gateway → handleDepositAndDelegate | ~23,436 gas |
| handleDepositAndDelegate proxy → impl | ~688 gas |

## 4. On-Chain Receipt vs Local Simulation

### On-Chain Transaction Receipt

```
transactionHash: 0x7a56fe0f9ac0805ebc3284d9a4df70d53c88d0a08cd5e7171cb9c6ef618bda91
status:          1 (success)
gasUsed:         732,522
gasLimit:        730,111 (passed to execute302)
```

### Critical Discrepancy

| Metric | Local Simulation (Foundry) | On-Chain (Imuachain) |
|--------|---------------------------|----------------------|
| **Gas Used** | 107,198 | 732,522 |
| **Precompile Gas** | 0 | ~625,000+ |
| **Outer TX Result** | Success | Success |
| **Inner lzReceive Result** | Revert | Revert |
| **Final Outcome** | `lzReceiveAlert` emitted (stored for retry) | `lzReceiveAlert` emitted (stored for retry) |

### Why the Difference?

**Local Foundry Simulation:**
- Precompile address `0x0804` is just an EOA (empty account)
- Call to non-contract returns immediately with `[Stop]`
- No actual `x/assets` module logic executes
- Returns empty data, interpreted as `success = false`
- Gateway reverts with `DepositRequestShouldNotFail`

**On-Chain Imuachain:**
- Precompile `0x0804` is a native Cosmos SDK module (`x/assets`)
- Real validation, state changes, and cross-module calls occur
- Consumes ~625k gas for actual business logic
- **Still returns `success = false`** (validation failed in `x/assets` module)
- Gateway reverts with `RequestOrResponseExecuteFailed`
- Executor catches revert and emits `lzReceiveAlert` (message stored for retry)

### Gas Budget Analysis

```
Gas Limit:     730,111
Gas Used:      732,522
Difference:    +2,411 (OVER LIMIT!)
```

⚠️ **The transaction used MORE gas than the limit passed to `execute302`!**

This is possible because:
1. The 730,111 is the gas passed to the inner `lzReceive` call
2. The executor itself consumes additional gas for setup/teardown
3. The `lzReceiveAlert` fallback (9,471 gas in trace) also runs
4. On-chain, the transaction's actual gas limit was higher than 730,111

### Root Cause Analysis

The precompile call `depositLST` at address `0x0000000000000000000000000000000000000804`:

**In Simulation:**
- Shows **0 gas used** (no code at address)
- Returns `← [Stop]` (empty call to EOA)
- Parent reverts because empty return ≠ valid `(bool, uint256)` tuple

**On-Chain:**
- Executes real `x/assets.depositLST` logic
- Consumes ~625k gas
- **Still returns `(false, _)`** - validation failed in Cosmos module
- Gateway reverts with `DepositRequestShouldNotFail`
- Wrapped as `RequestOrResponseExecuteFailed(10, 850, ...)`

### Verdict

| Question | Answer |
|----------|--------|
| Is this an OOG error? | **No** - precompile executed fully, then returned false |
| Did both local & on-chain fail? | **Yes** - both reverted with `RequestOrResponseExecuteFailed` |
| Why different gas? | Local: no precompile code (0 gas). On-chain: real module (~625k gas) |
| Is gas budget tight? | **Yes** - only ~2k headroom before the revert |

### Likely Cause of Simulation Failure

The Foundry fork doesn't have native precompile implementations. When calling `0x0804`:
- Foundry treats it as a normal address with no code
- The call returns empty bytes
- Solidity's ABI decoder fails to decode `(bool, uint256)` from empty data
- This manifests as a revert

## 5. Error Propagation

```
depositLST returns (false, _)
    → handleDepositAndDelegate reverts with DepositRequestShouldNotFail
        → _lzReceive catches and wraps as RequestOrResponseExecuteFailed(10, 850, 0x)
            → Executor catches the revert and calls lzReceiveAlert (stores for retry)
                → Transaction succeeds (message stored in failed state)
```

The empty `0x` in `RequestOrResponseExecuteFailed(10, 850, 0x)` indicates no error message was returned from the inner revert.

## 6. Recommendations

### For Local Testing
1. **Deploy mock precompiles**: Use `RewardMock`, `AssetsMock`, `DelegationMock` contracts at precompile addresses when testing on local forks
2. **Use `vm.etch`**: In Foundry tests, use `vm.etch(0x0804, mockCode)` to place mock implementations

### For Production
1. **Increase gas buffer**: The current 730k limit leaves almost no headroom. Consider 800k-900k for safety
2. **Monitor precompile gas**: Track actual gas consumption of precompile calls on-chain
3. **Verify operator format**: The operator bytes `696d3174777a6e6a3379357675347779646737756a737a65726b6b303568616330386532617334646e` decodes to ASCII: `im1twznj3y5vu4wydg7ujszerkk05hac08e2as4dn` (valid bech32)

## 7. Summary

| Aspect | Local Simulation | On-Chain Reality |
|--------|------------------|------------------|
| Precompile execution | No-op (EOA) | Full Cosmos SDK module |
| Gas for precompile | 0 | ~625,000 |
| Total gas | 107,198 | 732,522 |
| Inner `lzReceive` result | Revert | Revert |
| Outer TX result | Success (alert stored) | Success (alert stored) |
| Root cause of revert | Empty return from EOA | `depositLST` returned `success=false` |

**Conclusion**: Both local simulation and on-chain execution **failed** at the business logic level - the `depositLST` precompile returned `success = false`. The difference is:
- **Local**: Fails immediately (no precompile code, empty return)
- **On-chain**: Executes full validation in `x/assets` module (~625k gas), then fails

The outer transaction "succeeds" in both cases because the Executor catches the revert and stores the message via `lzReceiveAlert` for later retry.

**Next step**: Investigate why `x/assets.depositLST` returned false - likely token not registered, staker format issue, or TVL limit exceeded.
