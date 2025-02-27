const bitcoin = require('bitcoinjs-lib');
const ecc = require('tiny-secp256k1');
const { ECPairFactory } = require('ecpair');
const axios = require('axios');
const { expect } = require("chai");
const fs = require('fs');
const path = require('path');
require("dotenv").config();

const ECPair = ECPairFactory(ecc);

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

async function waitForBitcoinConfirmation(txid, confirmations = 1) {
    console.log(`Waiting for ${confirmations} confirmation(s) for tx: ${txid}`);
    
    while (true) {
        try {
            const response = await axios.get(`${BITCOIN_ESPLORA_API_URL}/api/tx/${txid}`);
            const tx = response.data;
            
            if (tx.status && tx.status.confirmed) {
                const blockInfoResponse = await axios.get(`${BITCOIN_ESPLORA_API_URL}/api/blocks/tip/height`);
                const currentHeight = parseInt(blockInfoResponse.data);
                const txHeight = tx.status.block_height;
                const currentConfirmations = currentHeight - txHeight + 1;

                console.log(`Transaction confirmations: ${currentConfirmations}`);
                
                if (currentConfirmations >= confirmations) {
                    console.log('Required confirmations reached');
                    return currentConfirmations;
                }
            } else {
                console.log('Transaction not yet confirmed...');
            }
        } catch (error) {
            console.log('Error checking transaction status:', error.message);
        }
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
}

async function fundBitcoinAddress(recipientAddress, amountSats) {
    if (!recipientAddress) {
        throw new Error('Recipient address is not set');
    }

    const faucetKeyPair = ECPair.fromPrivateKey(
        Buffer.from(BITCOIN_FAUCET_PRIVATE_KEY.replace('0x', ''), 'hex'),
        { network: bitcoin.networks.regtest, compressed: true }
    );

    const faucetPayment = bitcoin.payments.p2wpkh({
        pubkey: faucetKeyPair.publicKey,
        network: bitcoin.networks.regtest
    });

    console.log('Funding from:', faucetPayment.address);
    console.log('Funding to:', recipientAddress);
    console.log('Amount:', amountSats, 'sats');

    try {
        const response = await axios.get(`${BITCOIN_ESPLORA_API_URL}/api/address/${faucetPayment.address}/utxo`);
        const utxos = response.data;

        if (utxos.length === 0) {
            throw new Error('No UTXOs found in faucet');
        }

        const psbt = new bitcoin.Psbt({ network: bitcoin.networks.regtest });
        const requiredSats = amountSats + BITCOIN_TX_FEE;

        // Add inputs until we have enough for amount + fee
        let totalInputSats = 0n;
        for (const utxo of utxos) {
            psbt.addInput({
                hash: utxo.txid,
                index: utxo.vout,
                witnessUtxo: {
                    script: faucetPayment.output,
                    value: utxo.value
                }
            });
            
            totalInputSats += BigInt(utxo.value);
            if (totalInputSats >= requiredSats) break;
        }

        if (totalInputSats < requiredSats) {
            throw new Error(`Insufficient funds in faucet. Need ${requiredSats} sats (${amountSats} + ${BITCOIN_TX_FEE} fee), have ${totalInputSats} sats`);
        }

        // Add recipient output
        psbt.addOutput({
            address: recipientAddress,
            value: Number(amountSats)
        });

        // Add change output if above dust
        const changeSats = totalInputSats - amountSats - BITCOIN_TX_FEE;
        if (changeSats > DUST_THRESHOLD) {
            psbt.addOutput({
                address: faucetPayment.address,
                value: Number(changeSats)
            });
        }

        // Sign and broadcast
        psbt.signAllInputs(faucetKeyPair);
        psbt.finalizeAllInputs();
        const tx = psbt.extractTransaction();

        const broadcastResponse = await axios.post(
            `${BITCOIN_ESPLORA_API_URL}/api/tx`,
            tx.toHex(),
            { headers: { 'Content-Type': 'text/plain' } }
        );

        const txid = broadcastResponse.data;
        console.log('Funding transaction broadcasted:', txid);

        // Wait for confirmation
        await waitForBitcoinConfirmation(txid);
        console.log('Funding transaction confirmed');

        return txid;
    } catch (error) {
        console.error('Funding error:', error.message);
        throw error;
    }
}

async function createStakingTransaction(stakerPrivateKey, vaultAddress, depositAmountSats) {
    if (!stakerPrivateKey || !vaultAddress) {
        throw new Error('Required parameters are not set');
    }

    try {
        const keyPair = ECPair.fromPrivateKey(
            Buffer.from(stakerPrivateKey.replace('0x', ''), 'hex'),
            { network: bitcoin.networks.regtest, compressed: true }
        );

        const payment = bitcoin.payments.p2wpkh({
            pubkey: keyPair.publicKey,
            network: bitcoin.networks.regtest
        });

        const sourceAddress = payment.address;
        console.log('Staking from:', sourceAddress);
        console.log('Staking to vault:', vaultAddress);
        console.log('Amount:', depositAmountSats.toString(), 'sats');

        // Derive EVM address
        const wallet = new ethers.Wallet(stakerPrivateKey);
        const evmAddress = wallet.address.slice(2);
        console.log('EVM address:', '0x' + evmAddress);

        // Check balance and fund if needed
        const response = await axios.get(`${BITCOIN_ESPLORA_API_URL}/api/address/${sourceAddress}/utxo`);
        let utxos = response.data;
        let currentBalanceSats = utxos.reduce((sum, utxo) => sum + BigInt(utxo.value), 0n);
        const requiredSats = depositAmountSats + BITCOIN_TX_FEE;

        if (currentBalanceSats < requiredSats) {
            console.log(`Current balance: ${currentBalanceSats} sats`);
            console.log(`Required: ${requiredSats} sats (${depositAmountSats} + ${BITCOIN_TX_FEE} fee)`);
            const fundingAmountSats = requiredSats - currentBalanceSats;
            
            // Wait for funding transaction confirmation
            await fundBitcoinAddress(sourceAddress, fundingAmountSats);

            // Fetch updated UTXOs after funding is confirmed
            const updatedResponse = await axios.get(`${BITCOIN_ESPLORA_API_URL}/api/address/${sourceAddress}/utxo`);
            utxos = updatedResponse.data;
        }

        // Create staking transaction
        const psbt = new bitcoin.Psbt({ network: bitcoin.networks.regtest });

        // Add inputs until we have enough for deposit + fee
        let totalInputSats = 0n;
        for (const utxo of utxos) {
            psbt.addInput({
                hash: utxo.txid,
                index: utxo.vout,
                witnessUtxo: {
                    script: payment.output,
                    value: utxo.value
                }
            });
            
            totalInputSats += BigInt(utxo.value);
            if (totalInputSats >= requiredSats) break;
        }

        if (totalInputSats < requiredSats) {
            throw new Error(`Insufficient funds. Need ${requiredSats} sats (${depositAmountSats} + ${BITCOIN_TX_FEE} fee), have ${totalInputSats} sats`);
        }

        // Add outputs
        psbt.addOutput({
            script: bitcoin.script.compile([
                bitcoin.opcodes.OP_RETURN,
                Buffer.from(evmAddress, 'hex')
            ]),
            value: 0
        });

        psbt.addOutput({
            address: vaultAddress,
            value: Number(depositAmountSats)
        });

        const changeSats = totalInputSats - depositAmountSats - BITCOIN_TX_FEE;
        if (changeSats > DUST_THRESHOLD) {
            psbt.addOutput({
                address: sourceAddress,
                value: Number(changeSats)
            });
        }

        // Sign and broadcast
        psbt.signAllInputs(keyPair);
        psbt.finalizeAllInputs();
        const tx = psbt.extractTransaction();

        const broadcastResponse = await axios.post(
            `${BITCOIN_ESPLORA_API_URL}/api/tx`,
            tx.toHex(),
            { headers: { 'Content-Type': 'text/plain' } }
        );

        return broadcastResponse.data; // Return txid immediately after broadcast
    } catch (error) {
        console.error('Staking error:', error.message);
        throw error;
    }
}

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
        const txid = await createStakingTransaction(
            BITCOIN_STAKER_PRIVATE_KEY,
            BITCOIN_VAULT_ADDRESS,
            depositAmountSats
        );
        console.log('Staking transaction broadcasted. TXID:', txid);

        // Wait for Bitcoin confirmation
        console.log('Waiting for Bitcoin confirmation...');
        const confirmations = await waitForBitcoinConfirmation(txid);
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