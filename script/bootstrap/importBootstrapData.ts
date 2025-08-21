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
  // Get contract instance using direct ethers instantiation
  const gateway = new ethers.Contract(contractAddress, utxoGatewayAbi.abi, signer);

  // Check initial nonce
  const initialNonce = await gateway.inboundNonce(clientChainId);
  const totalBatches = Math.ceil(allBootstrapData.length / BATCH_SIZE);

  console.log(`🚀 Bootstrap Start: ${totalBatches} batches, initial nonce: ${initialNonce.toString()}\n`);

  let processedEntries = 0;

  for (let batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
    const startIndex = batchIndex * BATCH_SIZE;
    const endIndex = Math.min(startIndex + BATCH_SIZE, allBootstrapData.length);
    const batch = allBootstrapData.slice(startIndex, endIndex);

    console.log(`[Batch ${batchIndex + 1}/${totalBatches}] Processing entries ${startIndex + 1}-${endIndex} (${batch.length} entries)`);

    try {
      // Get current nonce and estimate gas
      const currentNonce = await gateway.inboundNonce(clientChainId);
      const gasEstimate = await gateway.bootstrapHistoricalData.estimateGas(clientChainId, batch);

      console.log(`[Batch ${batchIndex + 1}] Pre-call - Nonce: ${currentNonce.toString()} | Gas Estimate: ${gasEstimate.toString()}`);

      // Execute bootstrap batch
      const tx = await gateway.bootstrapHistoricalData(clientChainId, batch, {
        gasLimit: Math.floor(Number(gasEstimate) * 1.2), // 20% buffer
      });

      // Wait for confirmation
      const receipt = await tx.wait();
      processedEntries += batch.length;

      // Verify nonce increment
      const newNonce = await gateway.inboundNonce(clientChainId);

      console.log(`[Batch ${batchIndex + 1}] Success - TX: ${tx.hash} | Block: ${receipt!.blockNumber} | Gas Used: ${receipt!.gasUsed.toString()} | New Nonce: ${newNonce.toString()}`);

      // Check for bootstrap events (optional detailed logging)
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
        console.log(`[Batch ${batchIndex + 1}] Event - Entries: ${event!.args.entriesCount} | Final Nonce: ${event!.args.finalNonce}`);
      }

      console.log(`[Progress] ${processedEntries}/${allBootstrapData.length} entries processed (${((processedEntries / allBootstrapData.length) * 100).toFixed(1)}%)\n`);
    } catch (error: any) {
      console.error(`Error processing batch ${batchIndex + 1}:`, error.message);

      // Check for specific error types and provide guidance
      if (error.message.includes('TxTagAlreadyProcessed')) {
        console.error('Error: Some transactions already processed. Check for duplicate clientTxIds.');
        return false;
      } else if (error.message.includes('out of gas') || error.message.includes('gas limit')) {
        console.error('Error: Gas limit exceeded. Consider reducing BATCH_SIZE.');
        return false;
      }

      throw error; // Re-throw for other errors
    }

    // Add delay between batches to avoid nonce issues
    if (batchIndex < totalBatches - 1) {
      console.log(`[Delay] Waiting ${DELAY_BETWEEN_BATCHES}ms before next batch...`);
      await new Promise((resolve) => setTimeout(resolve, DELAY_BETWEEN_BATCHES));
    }
  }

  // Final verification
  const finalNonce = await gateway.inboundNonce(clientChainId);
  const expectedNonce = initialNonce + BigInt(allBootstrapData.length);

  const verificationResult = finalNonce === expectedNonce ? '✅ Bootstrap verification successful!' : '❌ Bootstrap verification failed - nonce mismatch!';

  console.log(`=== Bootstrap Complete ===
Initial Nonce: ${initialNonce.toString()} | Final Nonce: ${finalNonce.toString()} | Expected: ${expectedNonce.toString()}
Total Processed: ${processedEntries}/${allBootstrapData.length} entries
${verificationResult}
==========================\n`);

  return finalNonce === expectedNonce;
}

/**
 * Get client chain configuration from command line arguments
 */
function getClientChainConfig(): { chainId: ClientChainID; dataFile: string; chainName: string } {
  const args = process.argv.slice(2);
  const chainArg = args.find(arg => arg.startsWith('--chain='))?.split('=')[1]?.toLowerCase();

  switch (chainArg) {
    case 'btc':
    case 'bitcoin':
      return {
        chainId: ClientChainID.BITCOIN,
        dataFile: 'btc_bootstrap_data.json',
        chainName: 'Bitcoin'
      };
    case 'xrp':
    case 'xrpl':
      return {
        chainId: ClientChainID.XRPL,
        dataFile: 'xrp_bootstrap_data.json',
        chainName: 'XRPL'
      };
    default:
      console.error(`Invalid or missing chain argument. Usage:
  npm run bootstrap:btc   # For Bitcoin
  npm run bootstrap:xrp   # For XRPL

Or use:
  ts-node script/bootstrap/importBootstrapData.ts --chain=btc
  ts-node script/bootstrap/importBootstrapData.ts --chain=xrp`);
      process.exit(1);
  }
}

/**
 * Main function to load and import bootstrap data
 */
async function main(): Promise<void> {
  try {
    // Get chain configuration
    const { chainId, dataFile, chainName } = getClientChainConfig();

    // Setup provider and signer
    const rpcUrl = process.env.RPC_URL || 'http://localhost:8546';
    const privateKey = process.env.PRIVATE_KEY;
    const contractAddress = process.env.UTXO_GATEWAY_CONTRACT_ADDRESS;


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

    // Load and validate bootstrap data for the specified chain
    const bootstrapData = await loadBootstrapData(path.resolve(process.cwd(), `genesis/${dataFile}`));
    if (!validateBootstrapData(bootstrapData)) {
      console.error('Bootstrap data validation failed!');
      process.exit(1);
    }

    // Initialize and display configuration
    console.log(`=== Bootstrap Configuration ===
Chain: ${chainName} (ID: ${chainId}) | Data File: ${dataFile}
Contract: ${contractAddress}
Bootstrap Entries: ${bootstrapData.length}
=============================\n`);

    // Execute bootstrap for the specified chain
    const success = await bootstrapInBatches(contractAddress, chainId, bootstrapData, signer);

    if (success) {
      console.log(`${chainName} bootstrap process completed successfully!`);
    } else {
      console.error(`${chainName} bootstrap process failed!`);
      process.exit(1);
    }
  } catch (error) {
    console.error('Bootstrap failed:', error);
    process.exit(1);
  }
}

/**
 * Load bootstrap data from genesis folder
 * @param filePath - Path to the bootstrap data file
 * @returns - Array of bootstrap entries
 */
async function loadBootstrapData(filePath: string): Promise<BootstrapEntry[]> {
  try {
    console.log(`Loading bootstrap data from: ${filePath}`);
    const data = await fs.promises.readFile(filePath, 'utf8');
    const bootstrapData = JSON.parse(data) as BootstrapEntry[];

    console.log(`Loaded ${bootstrapData.length} bootstrap entries`);
    return bootstrapData;
  } catch (error: any) {
    console.error(`Failed to load bootstrap data from ${filePath}:`, error.message);
    throw new Error(`Bootstrap data file not found or invalid: ${filePath}`);
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
