import { ethers } from 'ethers';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

// Load environment variables from .env file
dotenv.config();

// Import UTXOGateway ABI - adjust path as needed
import utxoGatewayAbi from '../../out/UTXOGateway.sol/UTXOGateway.json';

/**
 * Bootstrap historical data in batches to avoid gas limit issues
 * This script splits large bootstrap datasets into manageable chunks
 */
const BATCH_SIZE = 250; // Maximum entries per batch
const DELAY_BETWEEN_BATCHES = 2000; // 2 seconds delay between batches

/**
 * Client Chain IDs enum matching the contract
 */
enum ClientChainID {
  NONE = 0,
  BITCOIN = 1,
  XRPL = 2,
}

/**
 * Bootstrap entry interface matching the Solidity struct
 */
interface BootstrapEntry {
  clientTxId: string;
  clientAddress: string;
  imuachainAddress: string;
}

/**
 * Execute bootstrap in batches for a given client chain
 * @param contractAddress - UTXOGateway contract address
 * @param clientChainId - Client chain ID (1 for Bitcoin, 2 for XRPL)
 * @param allBootstrapData - Complete bootstrap data array
 * @param signer - Ethereum signer (contract owner)
 */
async function bootstrapInBatches(
  contractAddress: string,
  clientChainId: ClientChainID,
  allBootstrapData: BootstrapEntry[],
  signer: ethers.Signer
): Promise<boolean> {
  console.log(`Starting bootstrap for client chain ${clientChainId}
Total entries: ${allBootstrapData.length}
Batch size: ${BATCH_SIZE}`);

  // Get contract instance using direct ethers instantiation
  const gateway = new ethers.Contract(contractAddress, utxoGatewayAbi.abi, signer);

  // Check initial nonce
  const initialNonce = await gateway.inboundNonce(clientChainId);
  console.log(`Initial inbound nonce: ${initialNonce.toString()}`);

  const totalBatches = Math.ceil(allBootstrapData.length / BATCH_SIZE);
  let processedEntries = 0;

  for (let batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
    const startIndex = batchIndex * BATCH_SIZE;
    const endIndex = Math.min(startIndex + BATCH_SIZE, allBootstrapData.length);
    const batch = allBootstrapData.slice(startIndex, endIndex);

    console.log(`\n--- Processing Batch ${batchIndex + 1}/${totalBatches} ---
Entries: ${startIndex + 1} to ${endIndex} (${batch.length} entries)`);

    try {
      // Get current nonce before transaction
      const currentNonce = await gateway.inboundNonce(clientChainId);

      // Estimate gas for the batch
      const gasEstimate = await gateway.bootstrapHistoricalData.estimateGas(clientChainId, batch);

      console.log(`Current nonce before batch: ${currentNonce.toString()}
Estimated gas: ${gasEstimate.toString()}`);

      // Execute bootstrap batch
      const tx = await gateway.bootstrapHistoricalData(clientChainId, batch, {
        gasLimit: Math.floor(Number(gasEstimate) * 1.2), // 20% buffer
      });

      console.log(`Transaction submitted: ${tx.hash}`);

      // Wait for confirmation
      const receipt = await tx.wait();
      console.log(`Transaction confirmed in block: ${receipt!.blockNumber}
Gas used: ${receipt!.gasUsed.toString()}`);

      // Update processed count
      processedEntries += batch.length;

      // Verify nonce increment
      const newNonce = await gateway.inboundNonce(clientChainId);
      console.log(`New nonce after batch: ${newNonce.toString()}`);

      // Check for bootstrap events
      const bootstrapEvents = receipt!.logs.filter((log: any) => {
        try {
          const decoded = gateway.interface.parseLog(log);
          return decoded!.name === 'BootstrapCompleted';
        } catch (e) {
          return false;
        }
      });

      if (bootstrapEvents.length > 0) {
        const event = gateway.interface.parseLog(bootstrapEvents[0]);
        console.log(`Bootstrap event: ${event!.args.entriesCount} entries, final nonce: ${event!.args.finalNonce}`);
      }

      console.log(`Batch ${batchIndex + 1} completed successfully!
Progress: ${processedEntries}/${allBootstrapData.length} entries processed`);
    } catch (error: any) {
      console.error(`Error processing batch ${batchIndex + 1}:`, error.message);

      // Check if it's a revert with specific error
      if (error.message.includes('TxTagAlreadyProcessed')) {
        console.error('Some transactions already processed. Check for duplicate clientTxIds.');
        return false;
      }

      // For gas-related errors, suggest reducing batch size
      if (error.message.includes('out of gas') || error.message.includes('gas limit')) {
        console.error('Gas limit exceeded. Consider reducing BATCH_SIZE.');
        return false;
      }

      throw error; // Re-throw for other errors
    }

    // Add delay between batches to avoid nonce issues
    if (batchIndex < totalBatches - 1) {
      console.log(`Waiting ${DELAY_BETWEEN_BATCHES}ms before next batch...`);
      await new Promise((resolve) => setTimeout(resolve, DELAY_BETWEEN_BATCHES));
    }
  }

  // Final verification
  const finalNonce = await gateway.inboundNonce(clientChainId);
  const expectedNonce = initialNonce + BigInt(allBootstrapData.length);

  console.log(`\n=== Bootstrap Completed ===
Initial nonce: ${initialNonce.toString()}
Final nonce: ${finalNonce.toString()}
Expected nonce: ${expectedNonce.toString()}
Total entries processed: ${processedEntries}`);

  if (finalNonce === expectedNonce) {
    console.log('✅ Bootstrap verification successful!');
    return true;
  } else {
    console.log('❌ Bootstrap verification failed - nonce mismatch!');
    return false;
  }
}

/**
 * Main function to load and import bootstrap data
 */
async function main(): Promise<void> {
  try {
    // Setup provider and signer
    const rpcUrl = process.env.RPC_URL || 'http://localhost:8546';
    const privateKey = process.env.PRIVATE_KEY;
    const contractAddress = process.env.UTXO_GATEWAY_CONTRACT_ADDRESS;

    // Debug: show which environment variables are loaded
    console.log(`Environment variables loaded:
RPC_URL: ${process.env.RPC_URL ? 'Set' : 'Not set'}
PRIVATE_KEY: ${process.env.PRIVATE_KEY ? 'Set' : 'Not set'}
UTXO_GATEWAY_CONTRACT_ADDRESS: ${process.env.UTXO_GATEWAY_CONTRACT_ADDRESS ? 'Set' : 'Not set'}`);

    if (!privateKey) {
      console.error('PRIVATE_KEY environment variable not set\nPlease set your private key before running this script');
      process.exit(1);
    }

    if (!contractAddress) {
      console.error('UTXO_GATEWAY_CONTRACT_ADDRESS environment variable not set\nPlease set the contract address before running this script');
      process.exit(1);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const signer = new ethers.Wallet(privateKey, provider);

    // Load and validate bootstrap data
    const bootstrapData = await loadBootstrapData();
    if (!validateBootstrapData(bootstrapData)) {
      console.error('Bootstrap data validation failed!');
      process.exit(1);
    }

    // Initialize and display configuration
    console.log(`=== Bootstrap Configuration ===
Signer address: ${await signer.getAddress()}
RPC URL: ${rpcUrl}
Contract address: ${contractAddress}
Bootstrap entries: ${bootstrapData.length}
================================\n`);

    // Execute bootstrap for Bitcoin chain
    const success = await bootstrapInBatches(contractAddress, ClientChainID.BITCOIN, bootstrapData, signer);

    if (success) {
      console.log('Bootstrap process completed successfully!');
    } else {
      console.error('Bootstrap process failed!');
      process.exit(1);
    }
  } catch (error) {
    console.error('Bootstrap failed:', error);
    process.exit(1);
  }
}

/**
 * Load bootstrap data from genesis folder
 * @param filePath - Path to the bootstrap data file (optional, defaults to genesis/bootstrap_data.json)
 * @returns - Array of bootstrap entries
 */
async function loadBootstrapData(filePath?: string): Promise<BootstrapEntry[]> {
  // Resolve from project root to support both ts-node and compiled runs
  const defaultPath = path.resolve(process.cwd(), 'genesis/btc_bootstrap_data.json');
  const dataPath = filePath || defaultPath;

  try {
    console.log(`Loading bootstrap data from: ${dataPath}`);
    const data = await fs.promises.readFile(dataPath, 'utf8');
    const bootstrapData = JSON.parse(data) as BootstrapEntry[];

    console.log(`Loaded ${bootstrapData.length} bootstrap entries`);
    return bootstrapData;
  } catch (error: any) {
    console.error(`Failed to load bootstrap data from ${dataPath}:`, error.message);
    throw new Error(`Bootstrap data file not found or invalid: ${dataPath}`);
  }
}

/**
 * Utility function to validate bootstrap data format
 * @param bootstrapData - Array of bootstrap entries
 * @returns - True if data format is valid
 */
function validateBootstrapData(bootstrapData: BootstrapEntry[]): boolean {
  if (!Array.isArray(bootstrapData) || bootstrapData.length === 0) {
    console.error('Bootstrap data must be a non-empty array');
    return false;
  }

  for (let i = 0; i < bootstrapData.length; i++) {
    const entry = bootstrapData[i];

    if (!entry.clientTxId || !entry.clientAddress || !entry.imuachainAddress) {
      console.error(`Invalid entry at index ${i}: missing required fields`);
      return false;
    }

    // Validate clientTxId format (32 bytes hex)
    if (!/^0x[a-fA-F0-9]{64}$/.test(entry.clientTxId)) {
      console.error(`Invalid clientTxId format at index ${i}: ${entry.clientTxId}`);
      return false;
    }

    // Validate clientAddress format (Bitcoin address as UTF-8 bytes)
    if (!/^0x[a-fA-F0-9]+$/.test(entry.clientAddress) || entry.clientAddress.length < 4) {
      console.error(`Invalid clientAddress format at index ${i}: ${entry.clientAddress}`);
      return false;
    }

    // Validate imuachainAddress format (20 bytes hex)
    if (!/^0x[a-fA-F0-9]{40}$/.test(entry.imuachainAddress)) {
      console.error(`Invalid imuachainAddress format at index ${i}: ${entry.imuachainAddress}`);
      return false;
    }
  }

  console.log(`✅ Bootstrap data validation passed for ${bootstrapData.length} entries`);
  return true;
}

// Export functions for use in other scripts
export { bootstrapInBatches, loadBootstrapData, validateBootstrapData, ClientChainID, BATCH_SIZE };

// Run main function if script is executed directly
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
