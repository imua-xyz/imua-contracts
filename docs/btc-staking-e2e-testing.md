# BTC Staking E2E Testing Guide

This guide walks through setting up and testing the BTC staking functionality in a local development environment.

## Prerequisites

- Docker and Docker Compose
- Node.js (v16+)
- npm or yarn
- Git

## Setup Steps

### Start Bitcoin Regtest Node

1. First, clone and set up the Esplora explorer:

```bash
git clone https://github.com/imua-xyz/esplora.git
cd esplora
```

2. Start the Bitcoin regtest node, esplora, send test token to faucet and activate auto mining by running script:

```bash
./start-regtest.sh -h
Start a Bitcoin regtest node with automatic mining and fund a predefined test faucet

Usage: ./start-regtest.sh [amount_btc] [mining_interval_seconds]

Arguments:
  amount_btc                 Amount of BTC to send to faucet (default: 100)
  mining_interval_seconds    Block mining interval in seconds (default: 30)

Faucet Information (only for regtest):
  Private Key: 0xee01cfc3f08cdb020064f31ff1a993aa9ecc1d38e684665742faa705685532a6
  Address:     bcrt1qvj7e5av2eqrhhvle56f9aqtjpxgywwnt5tem5y

Example:
  ./start-regtest.sh 50 60
```

NOTICE: Some amount of test BTC would be sent to the faucet address with known private key

### Start Imuachain Node

1. Set up and start the Imuachain node:

```bash
# Clone the repository
git clone https://github.com/imua-xyz/imuachain.git
cd imuachain

# Switch to develop branch
git checkout develop

# Start local node
./local_node.sh
```

### Deploy UTXO Gateway Contract

1. Clone repo and set up the UTXO gateway contract:

```bash
git clone https://github.com/imua-xyz/imua-contracts.git
cd imua-contracts
npm run deploy:utxogateway
```

Before running the deployment command, please replace the URL path of `imuachain_localnet` in `hardhat.config.js` with the URL path of your set up Imuachain node, and also set the private key of the Imuachain account in `hardhat.config.js` in your local `.env` file. We need at least 3 accounts (`deployer` == `faucet`, `owner` and `witness1`) to execute the deployment script.

```javascript
imuachain_localnet: {
      url: "http://127.0.0.1:8545",
      chainId: 232,
      accounts: [
        process.env.LOCAL_IMUACHAIN_FUNDED_ACCOUNT_PRIVATE_KEY, // Deployer/Faucet: Requires minimum 3 eth balance
        process.env.TEST_ACCOUNT_ONE_PRIVATE_KEY, // Owner: the owner of the UTXOGateway contract
        process.env.TEST_ACCOUNT_TWO_PRIVATE_KEY, // Witness1: the only witness for current implementation, also needed by bridge
        process.env.TEST_ACCOUNT_THREE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_FOUR_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_FIVE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_SIX_PRIVATE_KEY,
      ]
    }
```

This would deploy UTXOGateway contract on Imuachain node and set it up:

- set deployed contract as authorized gateway
- set required proofs count
- set authorized witness and transfer tokens to it as fee
- activate BTC staking by registering Bitcoin chain and token

The final output would be stored under `script/deployments/utxogateway.json`

### Start UTXO Bridge

1. Clone the UTXO bridge service:

```bash
# Clone the repository
# TODO: transfer out to imua-xyz after upgrading the org plan
git clone https://github.com/imua-xyz/utxo-restaking.git
cd utxo-restaking
git checkout btc-restaking-v2
```

2. Configure the bridge service with address of deployed UTXOGateway contract, witness address and its private key and other required parameters:

```bash
# Copy .env.example to .env and set the required variables
cp .env.example .env
```

```env
BITCOIN_RPC // URL of the esplora API
VAULT_ADDRESS // Address of the BTC vault
MIN_CONFIRMATIONS // Minimum number of confirmations for a Bitcoin transaction
EXOCORE_RPC // URL of the Imuachain node
CONTRACT_ADDRESS // Address of the UTXOGateway contract
WITNESS_ADDRESS // Address of the witness
WALLET_PRIV_KEY // Private key of the signing wallet, should be the same as the witness for current implementation
```

NOTICE: We'd better set `MIN_CONFIRMATIONS` to 1 to avoid timeouts

3. Start the bridge service:

```bash
# Start bridge services
docker-compose up
```

### Run E2E Tests

1. Go back to the imua-contracts directory and run the BTC staking E2E test:

```bash
npx hardhat test test/integration/btc-staking-e2e.test.js
```

Before running the test, please configure the test environment variables in your local `.env` file with required parameters like the secret key of BTC faucet and others.

```env
BITCOIN_FAUCET_PRIVATE_KEY // Private key of the BTC faucet
BITCOIN_ESPLORA_API_URL // URL of the esplora API
BITCOIN_STAKER_PRIVATE_KEY // Private key of the staker
BITCOIN_TX_FEE // Transaction fee for BTC deposit
DUST_THRESHOLD // Dust threshold for BTC deposit
```

This test would simulate the process of building a valid Bitcoin deposit transaction, broadcasting it to the Bitcoin network and waiting for it to be confirmed, and finally checking staker's balance on Imuachain.
