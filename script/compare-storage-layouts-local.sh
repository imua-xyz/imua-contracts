#!/usr/bin/env bash
# Reproduce the "Compare Storage Layouts" CI job locally to find which contract
# has a broken storage layout. Run from repo root.
#
# Prerequisites:
#   - forge (Foundry)
#   - jq, node, npm
#   - For full run (fetch deployed layouts): .env with CLIENT_CHAIN_RPC and ETHERSCAN_API_KEY set
#
# Usage:
#   1. Generate compiled layouts, run comparison (use existing or fetch deployed layouts):
#      - If *.deployed.json already exist in repo root (e.g. from CI artifacts), they are used.
#      - If any are missing, .env must define CLIENT_CHAIN_RPC and ETHERSCAN_API_KEY to fetch from chain.
#      ./script/compare-storage-layouts-local.sh
#   2. Only generate compiled layout files (no fetch, no comparison):
#      ./script/compare-storage-layouts-local.sh --compile-only
#
# When fetching from chain, CLIENT_CHAIN_RPC and ETHERSCAN_API_KEY (both required) are read from .env.
# Addresses come from script/deployments/deployedContracts.json (sepolia).

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Load .env if present (CLIENT_CHAIN_RPC, ETHERSCAN_API_KEY)
if [ -f ".env" ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

CONTRACTS=(Bootstrap ClientChainGateway Vault RewardVault ImuaCapsule ImuachainGateway)
COMPILE_ONLY=false
if [ "${1:-}" = "--compile-only" ]; then
  COMPILE_ONLY=true
fi

echo "==> Building with Forge..."
forge build

echo "==> Generating compiled storage layout files..."
for name in "${CONTRACTS[@]}"; do
  if [ "$name" = "ImuachainGateway" ]; then
    # ImuachainGateway.base.json is from base branch; we generate .compiled.json only here.
    # For base: checkout base, forge build, then: forge inspect --json src/core/ImuachainGateway.sol:ImuachainGateway storage-layout > ImuachainGateway.base.json
    out="ImuachainGateway.compiled.json"
  else
    out="${name}.compiled.json"
  fi
  forge inspect --json "src/core/${name}.sol:${name}" storage-layout > "$out"
  echo "    $out"
done

# ImuachainGateway.base.json: if not present, try generating from current (so at least compare runs; may fail if base differs)
if [ ! -f "ImuachainGateway.base.json" ]; then
  echo "    ImuachainGateway.base.json not found (normally from base branch). Copying compiled as base for local run."
  cp -f ImuachainGateway.compiled.json ImuachainGateway.base.json
fi

if [ "$COMPILE_ONLY" = true ]; then
  echo "==> Compiled layouts only. Done. Put deployed *.deployed.json in repo root and run: node script/compareLayouts.js"
  exit 0
fi

# Required deployed layout files for comparison (compareLayouts.js)
REQUIRED_DEPLOYED=(Bootstrap.deployed.json ClientChainGateway.deployed.json Vault.deployed.json RewardVault.deployed.json ImuaCapsule.deployed.json)
NEED_FETCH=false
for f in "${REQUIRED_DEPLOYED[@]}"; do
  if [ ! -f "$f" ]; then
    NEED_FETCH=true
    break
  fi
done

if [ "$NEED_FETCH" = false ]; then
  echo "==> Using existing deployed layout files in repo root."
else
  # Fetch deployed layouts from chain; require CLIENT_CHAIN_RPC and ETHERSCAN_API_KEY from .env
  if [ -z "${CLIENT_CHAIN_RPC:-}" ]; then
    echo "Error: CLIENT_CHAIN_RPC is not set. Set it in .env (e.g. Sepolia RPC URL)."
    exit 1
  fi
  if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo "Error: ETHERSCAN_API_KEY is not set. Set it in .env."
    exit 1
  fi

  echo "==> Fetching deployed storage layouts from chain (CLIENT_CHAIN_RPC)..."
  DEPLOYED="script/deployments/deployedContracts.json"
  if [ ! -f "$DEPLOYED" ]; then
    echo "Error: Missing $DEPLOYED. Cannot fetch deployed layouts."
    exit 1
  fi

  for key in Bootstrap ClientChainGateway Vault RewardVault ImuaCapsule; do
    case "$key" in
      Bootstrap)           jq_key='.sepolia.bootstrapLogic';;
      ClientChainGateway) jq_key='.sepolia.clientGatewayLogic';;
      Vault)              jq_key='.sepolia.vaultImplementation';;
      RewardVault)        jq_key='.sepolia.rewardVaultImplementation';;
      ImuaCapsule)        jq_key='.sepolia.capsuleImplementation';;
      *)                  jq_key=empty;;
    esac
    [ -z "$jq_key" ] && continue
    addr=$(jq -r "$jq_key // empty" "$DEPLOYED")
    if [ -z "$addr" ] || [ "$addr" = "null" ]; then
      echo "    Skip $key (no address in $DEPLOYED)"
      continue
    fi
    out="${key}.deployed.json"
    echo "    $key -> $addr"
    cast storage --json "$addr" --rpc-url "$CLIENT_CHAIN_RPC" --etherscan-api-key "$ETHERSCAN_API_KEY" > "$out"
  done
fi

echo "==> Running storage layout comparison (node script/compareLayouts.js)..."
npm install --no-save @openzeppelin/upgrades-core 2>/dev/null || true
node script/compareLayouts.js
exit $?
