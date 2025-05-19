const bitcoin = require('bitcoinjs-lib');
const ecc = require('tiny-secp256k1');
const { ECPairFactory } = require('ecpair');
const axios = require('axios');
const { expect } = require("chai");
const fs = require('fs');
const path = require('path');
const BitcoinClient = require("../utils/bitcoin-utils");

require("dotenv").config();

const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
const VIRTUAL_BTC_ADDR = "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB";
const BTC_ID = ethers.getBytes(VIRTUAL_BTC_ADDR);

const BITCOIN_FAUCET_PRIVATE_KEY = process.env.BITCOIN_FAUCET_PRIVATE_KEY;
const BITCOIN_ESPLORA_API_URL = process.env.BITCOIN_ESPLORA_API_URL;
const BITCOIN_VAULT_ADDRESS = process.env.BITCOIN_VAULT_ADDRESS;
const BITCOIN_STAKER_PRIVATE_KEY = process.env.BITCOIN_STAKER_PRIVATE_KEY;
const BITCOIN_TX_FEE = 1000n; // sats
const DUST_THRESHOLD = 546n; // sats

if (!BITCOIN_ESPLORA_API_URL || !BITCOIN_FAUCET_PRIVATE_KEY || !BITCOIN_VAULT_ADDRESS || !BITCOIN_STAKER_PRIVATE_KEY) {
    throw new Error('BITCOIN_ESPLORA_API_URL or TEST_ACCOUNT_THREE_PRIVATE_KEY or BITCOIN_VAULT_ADDRESS is not set');
}

const bitcoinClient = new BitcoinClient({
    esploraApiUrl: BITCOIN_ESPLORA_API_URL,
    faucetPrivateKey: BITCOIN_FAUCET_PRIVATE_KEY,
    txFee: Number(BITCOIN_TX_FEE),
    dustThreshold: Number(DUST_THRESHOLD)
});

describe("Bitcoin Staking E2E Test", function() {
    let utxoGateway;
    let assetsPrecompile;
    let staker;

    const depositAmountSats = 1000000n; // 0.01 BTC in satoshis as BigInt
    const CLIENT_CHAIN = {
        NONE: 0,
        BTC: 1,
    };

    before(async function() {
        // Load deployed contracts
        const deployedContracts = JSON.parse(
            fs.readFileSync(
                path.join(__dirname, '../../../script/deployments/deployedContracts.json'),
                'utf8'
            )
        );

        // construct staker wallet
        staker = new ethers.Wallet(BITCOIN_STAKER_PRIVATE_KEY);

        // Initialize contracts from deployed addresses
        utxoGateway = await ethers.getContractAt(
            "UTXOGateway",
            deployedContracts.imuachain.utxoGateway
        );
        assetsPrecompile = await ethers.getContractAt(
            "IAssets",
            ASSETS_PRECOMPILE_ADDRESS
        );

        // Verify UTXOGateway is properly set up
        const [success, authorized] = await assetsPrecompile.isAuthorizedGateway(utxoGateway.target);
        expect(success).to.be.true;
        expect(authorized).to.be.true;

        // Verify BTC staking is activated
        const [chainSuccess, registered] = await assetsPrecompile.isRegisteredClientChain(CLIENT_CHAIN.BTC);
        expect(chainSuccess).to.be.true;
        expect(registered).to.be.true;
    });

    it("should complete the full staking flow", async function() {
        // Get initial balance
        const [success, initialBalance] = await assetsPrecompile.getStakerBalanceByToken(
            CLIENT_CHAIN.BTC,
            ethers.getBytes(staker.address),
            BTC_ID
        );

        if (!success) {
            console.log('the staker has not staked before');
        }

        // Create and broadcast the Bitcoin transaction
        const txid = await bitcoinClient.createStakingTransaction(
            BITCOIN_STAKER_PRIVATE_KEY,
            BITCOIN_VAULT_ADDRESS,
            depositAmountSats
        );
        console.log('Staking transaction broadcasted. TXID:', txid);

        // Wait for Bitcoin confirmation
        console.log('Waiting for Bitcoin confirmation...');
        const confirmations = await bitcoinClient.waitForConfirmation(txid);
        console.log('Transaction confirmed with', confirmations, 'confirmations');

        // Wait for deposit to be processed
        console.log('Waiting for deposit to be processed...');
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error('Timeout waiting for deposit to be processed'));
            }, 120000);

            const checkDeposit = async () => {
                try {
                    // Check if the stake message has been processed
                    const isProcessed = await utxoGateway.isStakeMsgProcessed(
                        CLIENT_CHAIN.BTC,
                        ethers.getBytes('0x' + txid)  // Convert hex string to bytes32
                    );

                    console.log('Stake message processed:', isProcessed);

                    if (isProcessed) {
                        clearTimeout(timeout);
                        
                        // Verify final balance
                        const [finalSuccess, finalBalance] = await assetsPrecompile.getStakerBalanceByToken(
                            CLIENT_CHAIN.BTC,
                            ethers.getBytes(staker.address),
                            BTC_ID
                        );
                        
                        expect(finalSuccess).to.be.true;
                        const expectedIncrease = ethers.parseUnits('0.01', 8);
                        
                        expect(finalBalance[0]).to.equal(CLIENT_CHAIN.BTC);
                        expect(ethers.hexlify(finalBalance[1])).to.equal(ethers.hexlify(staker.address));
                        expect(ethers.hexlify(finalBalance[2])).to.equal(ethers.hexlify(BTC_ID));
                        expect(finalBalance[3] - (initialBalance ? initialBalance[3] : 0)).to.equal(expectedIncrease);
                        expect(finalBalance[7] - (initialBalance ? initialBalance[7] : 0)).to.equal(expectedIncrease);

                        console.log('Deposit processed successfully');
                        console.log('Initial balance:', initialBalance ? initialBalance[3] : 0);
                        console.log('Final balance:', finalBalance[3]);
                        
                        resolve();
                    } else {
                        // Check again in 1 second
                        setTimeout(checkDeposit, 1000);
                    }
                } catch (error) {
                    clearTimeout(timeout);
                    reject(error);
                }
            };

            checkDeposit();
        });
    }).timeout(300000);
});