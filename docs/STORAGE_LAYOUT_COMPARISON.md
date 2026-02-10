# Storage layout comparison (CI and local)

The **Compare Storage Layouts** workflow (`.github/workflows/compare-layouts.yml`) runs after Forge CI. It compares **compiled** storage layouts (from your branch) with **deployed** storage layouts (from chain) for upgradeable contracts. If layouts differ in an unsafe way, the job exits with **code 1**.

When running the local script to fetch deployed layouts from chain, **both** `CLIENT_CHAIN_RPC` and `ETHERSCAN_API_KEY` must be set in `.env`; the script loads `.env` and exits with an error if either is missing.

## How to find which contract has broken storage

### Option 1: Run the same command locally (recommended)

From the **repo root**:

```bash
# 1. Generate compiled layout files and run the comparison script
./script/compare-storage-layouts-local.sh
```

You must have the **deployed** layout JSONs in the repo root. Either:

- **From CI artifacts**: Download `compiled-layouts-<sha>` and `deployed-layouts-<sha>` from the Forge CI and Compare Storage Layouts workflow runs, unzip both into the repo root, then run:

  ```bash
  npm install @openzeppelin/upgrades-core
  node script/compareLayouts.js
  ```

- **From chain**: Set `CLIENT_CHAIN_RPC` and `ETHERSCAN_API_KEY` in `.env` (both required). The script loads `.env` and uses them to fetch deployed layouts and run the compare:

  ```bash
  # In .env (see .env.example):
  # CLIENT_CHAIN_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
  # ETHERSCAN_API_KEY=your_etherscan_key

  ./script/compare-storage-layouts-local.sh
  ```

The script and `compareLayouts.js` print which **pair** failed (e.g. `RewardVault.deployed.json` vs `RewardVault.compiled.json`) and the **report** from `@openzeppelin/upgrades-core` (e.g. "Variable `foo` was removed", "Layout change for slot X"), so you know exactly which contract and what changed.

### Option 2: Use CI logs

Re-run the **Compare Storage Layouts** workflow and open the log for the step **"Compare the layouts"**. It runs:

```bash
node script/compareLayouts.js
```

The first failing comparison is printed (e.g. `⚠️ Issues found in RewardVault.deployed.json and RewardVault.compiled.json`) followed by `report.explain()` — that identifies the contract and the incompatible change.

### Option 3: Generate only compiled layouts

To regenerate compiled layout files (e.g. after changing contracts) without fetching deployed or running the compare:

```bash
./script/compare-storage-layouts-local.sh --compile-only
```

Then set `CLIENT_CHAIN_RPC` and `ETHERSCAN_API_KEY` in `.env` and run the full script to fetch deployed layouts and compare, or put `*.deployed.json` in the repo root and run:

```bash
node script/compareLayouts.js
```

---

## Fix approach for broken storage

Upgradeable contracts must keep **storage layout compatible**: the new implementation must not change the meaning or order of existing storage slots.

**Rules:**

1. **Do not remove or reorder** existing state variables.
2. **Do not change the type** of existing state variables (same type, same size).
3. **New variables**: add only at the **end** of the contract (or after an explicit gap). In base/child inheritance, new storage in the child comes after the parent’s; changing the parent’s layout or order breaks the child.
4. **Reserved gap**: use a single gap array (e.g. `uint256[50] private __gap`) and reduce the gap size when adding new variables so the **total** number of slots does not change across upgrades.

**If the report says:**

- **"Variable X was removed"** → Restore the variable (or keep a gap of the same size in its place).
- **"Variable X was inserted" in the middle** → Move the new variable to the end (or into the gap) so slot order matches the previous implementation.
- **"Layout or type change"** → Revert the type or layout change; keep the same types and order as the deployed version.

After fixing, run `./script/compare-storage-layouts-local.sh` (or `node script/compareLayouts.js` with the same layout files) again until all comparisons pass.

**ImuaCapsule and gap consumption:** Adding a new variable by reducing the `__gap` (e.g. `isPectra` bool + `__gap` from `uint256[38]` to `uint256[37]`) is a valid upgrade pattern, but OpenZeppelin’s comparator treats it as “gap → incompatible type” and fails. For that reason, `script/compareLayouts.js` skips the storage check for the ImuaCapsule pair (`unsafeSkipStorageCheck`); the layout for that contract should be verified manually when changing it.
