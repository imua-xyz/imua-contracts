const { ethers } = require("hardhat");

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
    XRPL = 2
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
    signer: any
): Promise<boolean> {
    console.log(`Starting bootstrap for client chain ${clientChainId}`);
    console.log(`Total entries: ${allBootstrapData.length}`);
    console.log(`Batch size: ${BATCH_SIZE}`);
    
    // Get contract instance
    const UTXOGateway = await ethers.getContractFactory("UTXOGateway");
    const gateway = UTXOGateway.attach(contractAddress).connect(signer);
    
    // Check initial nonce
    const initialNonce = await gateway.inboundNonce(clientChainId);
    console.log(`Initial inbound nonce: ${initialNonce}`);
    
    const totalBatches = Math.ceil(allBootstrapData.length / BATCH_SIZE);
    let processedEntries = 0;
    
    for (let batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
        const startIndex = batchIndex * BATCH_SIZE;
        const endIndex = Math.min(startIndex + BATCH_SIZE, allBootstrapData.length);
        const batch = allBootstrapData.slice(startIndex, endIndex);
        
        console.log(`\n--- Processing Batch ${batchIndex + 1}/${totalBatches} ---`);
        console.log(`Entries: ${startIndex + 1} to ${endIndex} (${batch.length} entries)`);
        
        try {
            // Get current nonce before transaction
            const currentNonce = await gateway.inboundNonce(clientChainId);
            console.log(`Current nonce before batch: ${currentNonce}`);
            
            // Estimate gas for the batch
            const gasEstimate = await gateway.estimateGas.bootstrapHistoricalData(
                clientChainId,
                batch
            );
            console.log(`Estimated gas: ${gasEstimate.toString()}`);
            
            // Execute bootstrap batch
            const tx = await gateway.bootstrapHistoricalData(
                clientChainId,
                batch,
                {
                    gasLimit: Math.floor(Number(gasEstimate) * 1.2) // 20% buffer
                }
            );
            
            console.log(`Transaction submitted: ${tx.hash}`);
            
            // Wait for confirmation
            const receipt = await tx.wait();
            console.log(`Transaction confirmed in block: ${receipt!.blockNumber}`);
            console.log(`Gas used: ${receipt!.gasUsed.toString()}`);
            
            // Update processed count
            processedEntries += batch.length;
            
            // Verify nonce increment
            const newNonce = await gateway.inboundNonce(clientChainId);
            console.log(`New nonce after batch: ${newNonce}`);
            
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
            
            console.log(`Batch ${batchIndex + 1} completed successfully!`);
            console.log(`Progress: ${processedEntries}/${allBootstrapData.length} entries processed`);
            
        } catch (error: any) {
            console.error(`Error processing batch ${batchIndex + 1}:`, error.message);
            
            // Check if it's a revert with specific error
            if (error.message.includes("TxTagAlreadyProcessed")) {
                console.error("Some transactions already processed. Check for duplicate clientTxIds.");
                return false;
            }
            
            // For gas-related errors, suggest reducing batch size
            if (error.message.includes("out of gas") || error.message.includes("gas limit")) {
                console.error("Gas limit exceeded. Consider reducing BATCH_SIZE.");
                return false;
            }
            
            throw error; // Re-throw for other errors
        }
        
        // Add delay between batches to avoid nonce issues
        if (batchIndex < totalBatches - 1) {
            console.log(`Waiting ${DELAY_BETWEEN_BATCHES}ms before next batch...`);
            await new Promise(resolve => setTimeout(resolve, DELAY_BETWEEN_BATCHES));
        }
    }
    
    // Final verification
    const finalNonce = await gateway.inboundNonce(clientChainId);
    const expectedNonce = initialNonce.add(allBootstrapData.length);
    
    console.log(`\n=== Bootstrap Completed ===`);
    console.log(`Initial nonce: ${initialNonce}`);
    console.log(`Final nonce: ${finalNonce}`);
    console.log(`Expected nonce: ${expectedNonce}`);
    console.log(`Total entries processed: ${processedEntries}`);
    
    if (finalNonce.eq(expectedNonce)) {
        console.log("✅ Bootstrap verification successful!");
        return true;
    } else {
        console.log("❌ Bootstrap verification failed - nonce mismatch!");
        return false;
    }
}

/**
 * Example usage function
 */
async function main(): Promise<void> {
    // Example bootstrap data structure
    const exampleBootstrapData: BootstrapEntry[] = [
        {
            clientTxId: "0x1234567890123456789012345678901234567890123456789012345678901234",
            clientAddress: "0x1234567890123456789012345678901234567890", // Example address bytes
            imuachainAddress: "0xAbcD1234567890123456789012345678901234567890"
        },
        // Add more entries...
    ];
    
    try {
        // Get deployer/owner account
        const [deployer] = await ethers.getSigners();
        console.log("Deployer address:", deployer.address);
        
        // Contract address - replace with actual deployed address
        const contractAddress = "0x..."; // TODO: Replace with actual contract address
        
        // Execute bootstrap for Bitcoin chain
        const success = await bootstrapInBatches(
            contractAddress,
            ClientChainID.BITCOIN,
            exampleBootstrapData,
            deployer
        );
        
        if (success) {
            console.log("Bootstrap process completed successfully!");
        } else {
            console.error("Bootstrap process failed!");
            process.exit(1);
        }
        
    } catch (error) {
        console.error("Bootstrap failed:", error);
        process.exit(1);
    }
}

/**
 * Utility function to validate bootstrap data format
 * @param bootstrapData - Array of bootstrap entries
 * @returns - True if data format is valid
 */
function validateBootstrapData(bootstrapData: BootstrapEntry[]): boolean {
    if (!Array.isArray(bootstrapData) || bootstrapData.length === 0) {
        console.error("Bootstrap data must be a non-empty array");
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
module.exports = {
    bootstrapInBatches,
    validateBootstrapData,
    ClientChainID,
    BATCH_SIZE
};

// Run main function if script is executed directly
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}