import axios from 'axios';
import { address as addressUtils, networks } from 'bitcoinjs-lib';

export async function getTxIndexInBlock(txid: string, baseUrl: string): Promise<number> {
  try {
    // Get transaction block hash
    const txResponse = await axios.get(`${baseUrl}/tx/${txid}`);
    const blockHash = txResponse.data.status.block_hash;
    
    // Get all transactions in the block
    const blockResponse = await axios.get(`${baseUrl}/block/${blockHash}/txids`);
    const txids = blockResponse.data;
    
    // Find index of our transaction
    const index = txids.indexOf(txid);
    if (index === -1) {
      throw new Error(`Transaction ${txid} not found in block ${blockHash}`);
    }
    
    return index;
  } catch (error) {
    console.error(`Error getting tx index for ${txid}:`, error);
    throw error;
  }
}

export async function getBlockHeight(baseUrl: string): Promise<number> {
  try {
    const response = await axios.get(`${baseUrl}/blocks/tip/height`);
    return response.data;
  } catch (error) {
    console.error('Error getting block height:', error);
    throw error;
  }
}

// Simple retry function if needed
export async function withRetry<T>(
  operation: () => Promise<T>,
  maxAttempts: number = 3,
  delayMs: number = 1000
): Promise<T> {
  let lastError: Error | undefined;
  
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error as Error;
      if (attempt < maxAttempts) {
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
    }
  }
  
  throw lastError;
}

export function toVersionAndHash(address: string, network?: networks.Network): { version: number; hash: Uint8Array } {
  network = network || networks.bitcoin;

  // Try Base58 decoding first
  try {
    const decodeBase58 = addressUtils.fromBase58Check(address);
    if (decodeBase58.version === network.pubKeyHash || decodeBase58.version === network.scriptHash) {
      return {
        version: decodeBase58.version,
        hash: decodeBase58.hash,
      };
    }
  } catch (e) {
    // Base58 decoding failed, proceed to Bech32 decoding
  }

  // Try Bech32 decoding if Base58 decoding failed
  try {
    const decodeBech32 = addressUtils.fromBech32(address);
    if (decodeBech32.prefix !== network.bech32) {
      throw new Error(address + ' has an invalid prefix');
    }
    return {
      version: decodeBech32.version,
      hash: decodeBech32.data,
    };
  } catch (e) {
    // Bech32 decoding also failed
  }

  // If neither decoding succeeds, throw an error
  throw new Error(address + ' has no matching Script');
}