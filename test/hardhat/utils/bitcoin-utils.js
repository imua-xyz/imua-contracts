const bitcoin = require('bitcoinjs-lib');
const ecc = require('tiny-secp256k1');
const { ECPairFactory } = require('ecpair');
const axios = require('axios');
const { ethers } = require('hardhat');

const ECPair = ECPairFactory(ecc);

class BitcoinClient {
  constructor(config) {
    this.esploraApiUrl = config.esploraApiUrl;
    this.faucetPrivateKey = config.faucetPrivateKey;
    this.network = bitcoin.networks.regtest;
    this.txFee = BigInt(config.txFee || 1000); // Default 1000 sats
    this.dustThreshold = BigInt(config.dustThreshold || 546); // Default 546 sats
    
    // Initialize faucet key pair
    this.faucetKeyPair = ECPair.fromPrivateKey(
      Buffer.from(this.faucetPrivateKey.replace('0x', ''), 'hex'),
      { network: this.network, compressed: true }
    );
    
    this.faucetPayment = bitcoin.payments.p2wpkh({
      pubkey: this.faucetKeyPair.publicKey,
      network: this.network
    });
    
    console.log('Bitcoin client initialized with faucet address:', this.faucetPayment.address);
  }
  
  /**
   * Fund a Bitcoin address with the specified amount
   * @param {string} recipientAddress - The Bitcoin address to fund
   * @param {bigint} amountSats - The amount to send in satoshis
   * @returns {Promise<string>} - The transaction ID
   */
  async fundAddress(recipientAddress, amountSats) {
    if (!recipientAddress) {
      throw new Error('Recipient address is not set');
    }

    console.log('Funding from:', this.faucetPayment.address);
    console.log('Funding to:', recipientAddress);
    console.log('Amount:', amountSats.toString(), 'sats');

    try {
      const response = await axios.get(`${this.esploraApiUrl}/api/address/${this.faucetPayment.address}/utxo`);
      const utxos = response.data;

      if (utxos.length === 0) {
        throw new Error('No UTXOs found in faucet');
      }

      const psbt = new bitcoin.Psbt({ network: this.network });
      const requiredSats = amountSats + this.txFee;

      // Add inputs until we have enough for amount + fee
      let totalInputSats = 0n;
      for (const utxo of utxos) {
        psbt.addInput({
          hash: utxo.txid,
          index: utxo.vout,
          witnessUtxo: {
            script: this.faucetPayment.output,
            value: utxo.value
          }
        });
        
        totalInputSats += BigInt(utxo.value);
        if (totalInputSats >= requiredSats) break;
      }

      if (totalInputSats < requiredSats) {
        throw new Error(`Insufficient funds in faucet. Need ${requiredSats} sats (${amountSats} + ${this.txFee} fee), have ${totalInputSats} sats`);
      }

      // Add recipient output
      psbt.addOutput({
        address: recipientAddress,
        value: Number(amountSats)
      });

      // Add change output if above dust
      const changeSats = totalInputSats - amountSats - this.txFee;
      if (changeSats > this.dustThreshold) {
        psbt.addOutput({
          address: this.faucetPayment.address,
          value: Number(changeSats)
        });
      }

      // Sign and broadcast
      psbt.signAllInputs(this.faucetKeyPair);
      psbt.finalizeAllInputs();
      const tx = psbt.extractTransaction();

      const broadcastResponse = await axios.post(
        `${this.esploraApiUrl}/api/tx`,
        tx.toHex(),
        { headers: { 'Content-Type': 'text/plain' } }
      );

      const txid = broadcastResponse.data;
      console.log('Funding transaction broadcasted:', txid);

      return txid;
    } catch (error) {
      console.error('Funding error:', error.message);
      throw error;
    }
  }

  /**
   * Create a staking transaction
   * @param {string} stakerPrivateKey - The private key of the staker
   * @param {string} vaultAddress - The vault address to stake to
   * @param {bigint} depositAmountSats - The amount to stake in satoshis
   * @param {string} validatorAddress - The validator address (optional)
   * @returns {Promise<string>} - The transaction ID
   */
  async createStakingTransaction(stakerPrivateKey, vaultAddress, depositAmountSats, validatorAddress = null) {
    if (!stakerPrivateKey || !vaultAddress) {
      throw new Error('Required parameters are not set');
    }

    try {
      const keyPair = ECPair.fromPrivateKey(
        Buffer.from(stakerPrivateKey.replace('0x', ''), 'hex'),
        { network: this.network, compressed: true }
      );

      const payment = bitcoin.payments.p2wpkh({
        pubkey: keyPair.publicKey,
        network: this.network
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
      const response = await axios.get(`${this.esploraApiUrl}/api/address/${sourceAddress}/utxo`);
      let utxos = response.data;
      let currentBalanceSats = utxos.reduce((sum, utxo) => sum + BigInt(utxo.value), 0n);
      const requiredSats = depositAmountSats + this.txFee;

      if (currentBalanceSats < requiredSats) {
        console.log(`Current balance: ${currentBalanceSats} sats`);
        console.log(`Required: ${requiredSats} sats (${depositAmountSats} + ${this.txFee} fee)`);
        const fundingAmountSats = requiredSats - currentBalanceSats;
        
        // Wait for funding transaction confirmation
        const fundingTxId = await this.fundAddress(sourceAddress, fundingAmountSats);
        await this.waitForConfirmation(fundingTxId);

        // Fetch updated UTXOs after funding is confirmed
        const updatedResponse = await axios.get(`${this.esploraApiUrl}/api/address/${sourceAddress}/utxo`);
        utxos = updatedResponse.data;
      }

      // Create staking transaction
      const psbt = new bitcoin.Psbt({ network: this.network });

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
        throw new Error(`Insufficient funds. Need ${requiredSats} sats (${depositAmountSats} + ${this.txFee} fee), have ${totalInputSats} sats`);
      }

      // Add outputs
      let opReturnData = evmAddress;
      if (validatorAddress) {
        opReturnData += Buffer.from(validatorAddress).toString('hex');
      }

      psbt.addOutput({
        script: bitcoin.script.compile([
          bitcoin.opcodes.OP_RETURN,
          Buffer.from(opReturnData, 'hex')
        ]),
        value: 0
      });

      psbt.addOutput({
        address: vaultAddress,
        value: Number(depositAmountSats)
      });

      const changeSats = totalInputSats - depositAmountSats - this.txFee;
      if (changeSats > this.dustThreshold) {
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
        `${this.esploraApiUrl}/api/tx`,
        tx.toHex(),
        { headers: { 'Content-Type': 'text/plain' } }
      );

      return broadcastResponse.data; // Return txid immediately after broadcast
    } catch (error) {
      console.error('Staking error:', error.message);
      throw error;
    }
  }

  /**
   * Wait for a transaction to be confirmed
   * @param {string} txid - The transaction ID to wait for
   * @param {number} confirmations - The number of confirmations to wait for
   * @returns {Promise<number>} - The number of confirmations
   */
  async waitForConfirmation(txid, confirmations = 1) {
    console.log(`Waiting for ${confirmations} confirmation(s) for tx: ${txid}`);
    
    while (true) {
      try {
        const response = await axios.get(`${this.esploraApiUrl}/api/tx/${txid}`);
        const tx = response.data;
        
        if (tx.status && tx.status.confirmed) {
          const blockInfoResponse = await axios.get(`${this.esploraApiUrl}/api/blocks/tip/height`);
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

  /**
   * Generate a random Bitcoin key pair
   * @returns {Object} - The key pair object
   */
  generateKeyPair() {
    const keyPair = ECPair.makeRandom({ network: this.network });
    const payment = bitcoin.payments.p2wpkh({
      pubkey: keyPair.publicKey,
      network: this.network
    });
    
    return {
      privateKey: `0x${keyPair.privateKey.toString('hex')}`,
      address: payment.address,
      keyPair
    };
  }
}

module.exports = BitcoinClient; 