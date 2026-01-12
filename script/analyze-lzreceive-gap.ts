import { ethers } from "ethers";
import axios from "axios";
import * as dotenv from "dotenv";
import { promises as fs } from "fs";
import path from "path";

dotenv.config();

// Configuration
const EXOSCAN_API_BASE = "https://explorer-api.exoscan.org/api/v2";
const RPC_URL = process.env.IMUACHAIN_TESTNET_RPC || process.env.IMUACHAIN_RPC;

if (!RPC_URL) {
  console.warn("Warning: RPC_URL not set. Trace fetching may fail.");
}

// Constants
const ENDPOINT_ADDRESS = "0x6EDCE65403992e310A62460808c4b910D972f10f"; // LayerZero Endpoint V2
const OAPP_LZ_RECEIVE_SELECTOR = "0x13137d65"; // lzReceive on OApp (ImuachainGateway)
const ENDPOINT_LZ_RECEIVE_SELECTOR = "0x0c0c389e"; // lzReceive on Endpoint

interface GasData {
  txHash: string;
  blockNumber: number;
  blockTimestamp: number;
  nonce: number;
  guid: string;
  messageType: string;
  actionValue: number;
  executionType: string;
  txGasLimit: string;
  endpointLzReceiveGasUsed: number;
  assetsPrecompileGasUsed?: number;
  delegationPrecompileGasUsed?: number;
  totalPrecompileGasUsed: number;
}

interface GapAnalysis {
  txHash: string;
  messageType: string;
  nonce: number;
  endpointGas: number;
  gatewayGas: number;
  gap: number;
  gapPercentage: number;
  success: boolean;
  error?: string;
}

interface TraceCall {
  from: string;
  to: string;
  gas: string;
  gasUsed: string;
  input: string;
  output: string;
  type: string;
  value: string;
  calls?: TraceCall[];
}

interface TraceResult {
  calls?: TraceCall[];
  from: string;
  gas: string;
  gasUsed: string;
  input: string;
  output: string;
  to: string;
  type: string;
  value: string;
}

function parseCSV(csvContent: string): GasData[] {
  const lines = csvContent.trim().split("\n");
  if (lines.length < 2) return [];
  
  const headers = lines[0].split(",");
  const records: GasData[] = [];
  
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    
    const values = line.split(",");
    const record: any = {};
    
    for (let j = 0; j < headers.length; j++) {
      const header = headers[j];
      const value = values[j] || "";
      
      // Convert numeric columns
      if (header === "blockNumber" || 
          header === "blockTimestamp" ||
          header === "nonce" ||
          header === "actionValue" ||
          header === "endpointLzReceiveGasUsed" ||
          header === "assetsPrecompileGasUsed" ||
          header === "delegationPrecompileGasUsed" ||
          header === "totalPrecompileGasUsed") {
        const num = parseInt(value, 10);
        record[header] = isNaN(num) ? undefined : num;
      } else {
        record[header] = value;
      }
    }
    
    records.push(record as GasData);
  }
  
  return records;
}

async function fetchRawTrace(txHash: string): Promise<TraceResult | null> {
  try {
    const url = `${EXOSCAN_API_BASE}/transactions/${txHash}/raw-trace`;
    const response = await axios.get<TraceResult>(url, {
      headers: { accept: "application/json" },
      timeout: 10000, // 10 second timeout
    });
    return response.data;
  } catch (error) {
    if (axios.isAxiosError(error)) {
      if (error.response?.status === 404) {
        // Trace pruned/not available
        return null;
      } else {
        console.warn(`Warning: unable to fetch trace for tx ${txHash}: ${error.response?.status} ${error.message}`);
      }
    } else {
      console.warn(`Warning: unable to fetch trace for tx ${txHash}: ${(error as Error).message}`);
    }
    return null;
  }
}

function findEndpointLzReceiveCall(call: TraceCall): TraceCall | null {
  // Check if this call is to the endpoint address with the lzReceive selector
  if (call.to.toLowerCase() === ENDPOINT_ADDRESS.toLowerCase() && 
      call.input.startsWith(ENDPOINT_LZ_RECEIVE_SELECTOR)) {
    return call;
  }
  
  // Recursively search in nested calls
  if (call.calls) {
    for (const nestedCall of call.calls) {
      const found = findEndpointLzReceiveCall(nestedCall);
      if (found) {
        return found;
      }
    }
  }
  
  return null;
}

function findGatewayLzReceiveCall(endpointCall: TraceCall, gatewayAddress?: string): TraceCall | null {
  // Search nested calls for the endpoint calling the OApp's lzReceive
  // This matches the clean implementation from analyze-gas-usage.ts findOAppReceiveCall
  if (endpointCall.calls) {
    for (const call of endpointCall.calls) {
      // If gatewayAddress is provided, check both address and selector (like RECEIVER_ADDRESS in analyze-gas-usage.ts)
      // Otherwise, check selector and exclude endpoint address
      const addressMatches = gatewayAddress 
        ? call.to.toLowerCase() === gatewayAddress.toLowerCase()
        : call.to.toLowerCase() !== ENDPOINT_ADDRESS.toLowerCase();
      
      if (addressMatches && call.input.startsWith(OAPP_LZ_RECEIVE_SELECTOR)) {
        return call;
      }
      // Recursively search in case there are intermediate proxy/wrapper calls
      const found = findGatewayLzReceiveCall(call, gatewayAddress);
      if (found) return found;
    }
  }
  
  return null;
}

function detectGatewayAddress(call: TraceCall): string | null {
  // Find first OApp lzReceive call to detect gateway address
  if (call.input.startsWith(OAPP_LZ_RECEIVE_SELECTOR)) {
    return call.to.toLowerCase();
  }
  
  if (call.calls) {
    for (const nestedCall of call.calls) {
      const address = detectGatewayAddress(nestedCall);
      if (address) {
        return address;
      }
    }
  }
  
  return null;
}

async function analyzeGap(
  gasData: GasData,
  gatewayAddress?: string
): Promise<GapAnalysis> {
  // Fetch trace - we get ALL gas values from trace, not from CSV
  const trace = await fetchRawTrace(gasData.txHash);
  if (!trace) {
    return {
      txHash: gasData.txHash,
      messageType: gasData.messageType,
      nonce: gasData.nonce,
      endpointGas: 0,
      gatewayGas: 0,
      gap: 0,
      gapPercentage: 0,
      success: false,
      error: "Trace not available"
    };
  }
  
  // Find endpoint lzReceive call in trace
  const endpointCall = findEndpointLzReceiveCall(trace as TraceCall);
  if (!endpointCall) {
    return {
      txHash: gasData.txHash,
      messageType: gasData.messageType,
      nonce: gasData.nonce,
      endpointGas: 0,
      gatewayGas: 0,
      gap: 0,
      gapPercentage: 0,
      success: false,
      error: "Endpoint lzReceive call not found in trace"
    };
  }
  
  // Get endpoint gas from trace
  const endpointGas = parseInt(endpointCall.gasUsed, 16);
  
  // Find gateway lzReceive call (within endpoint call's nested calls)
  const gatewayCall = findGatewayLzReceiveCall(endpointCall, gatewayAddress);
  if (!gatewayCall) {
    return {
      txHash: gasData.txHash,
      messageType: gasData.messageType,
      nonce: gasData.nonce,
      endpointGas,
      gatewayGas: 0,
      gap: 0,
      gapPercentage: 0,
      success: false,
      error: "Gateway lzReceive call not found in trace"
    };
  }
  
  // Get gateway gas from trace
  const gatewayGas = parseInt(gatewayCall.gasUsed, 16);
  
  // Validate: gateway gas should be less than endpoint gas since it's nested
  // If they're equal or gateway is larger, something is wrong
  if (gatewayGas >= endpointGas) {
    return {
      txHash: gasData.txHash,
      messageType: gasData.messageType,
      nonce: gasData.nonce,
      endpointGas,
      gatewayGas,
      gap: 0,
      gapPercentage: 0,
      success: false,
      error: `Invalid gas values: gatewayGas (${gatewayGas}) >= endpointGas (${endpointGas}). Possible wrong call match.`
    };
  }
  
  // Calculate gap: endpoint gas - gateway gas
  const gap = endpointGas - gatewayGas;
  const gapPercentage = endpointGas > 0 ? (gap / endpointGas) * 100 : 0;
  
  return {
    txHash: gasData.txHash,
    messageType: gasData.messageType,
    nonce: gasData.nonce,
    endpointGas,
    gatewayGas,
    gap,
    gapPercentage,
    success: true
  };
}

function calculateStats(analyses: GapAnalysis[]) {
  const successful = analyses.filter(a => a.success);
  if (successful.length === 0) {
    return null;
  }
  
  const gaps = successful.map(a => a.gap);
  const gapPercentages = successful.map(a => a.gapPercentage);
  
  const sortedGaps = [...gaps].sort((a, b) => a - b);
  const sortedPercentages = [...gapPercentages].sort((a, b) => a - b);
  
  return {
    total: analyses.length,
    successful: successful.length,
    failed: analyses.length - successful.length,
    gap: {
      min: Math.min(...gaps),
      max: Math.max(...gaps),
      avg: Math.round(gaps.reduce((sum, g) => sum + g, 0) / gaps.length),
      p50: sortedGaps[Math.floor(sortedGaps.length * 0.5)],
      p95: sortedGaps[Math.floor(sortedGaps.length * 0.95)],
      p99: sortedGaps[Math.floor(sortedGaps.length * 0.99)],
    },
    gapPercentage: {
      min: Math.min(...gapPercentages),
      max: Math.max(...gapPercentages),
      avg: Math.round((gapPercentages.reduce((sum, g) => sum + g, 0) / gapPercentages.length) * 100) / 100,
      p50: sortedPercentages[Math.floor(sortedPercentages.length * 0.5)],
      p95: sortedPercentages[Math.floor(sortedPercentages.length * 0.95)],
      p99: sortedPercentages[Math.floor(sortedPercentages.length * 0.99)],
    }
  };
}

function calculateStatsByMessageType(analyses: GapAnalysis[]) {
  const byType: Record<string, GapAnalysis[]> = {};
  
  for (const analysis of analyses) {
    if (!byType[analysis.messageType]) {
      byType[analysis.messageType] = [];
    }
    byType[analysis.messageType].push(analysis);
  }
  
  const statsByType: Record<string, any> = {};
  for (const [messageType, typeAnalyses] of Object.entries(byType)) {
    statsByType[messageType] = calculateStats(typeAnalyses);
  }
  
  return statsByType;
}

async function main() {
  console.log("=== LZReceive Gas Gap Analysis ===\n");

  // Read CSV file
  const csvPath = path.resolve(process.cwd(), "gas-analysis-results.csv");
  console.log(`Reading CSV from ${csvPath}...`);
  
  const csvContent = await fs.readFile(csvPath, "utf-8");
  const records = parseCSV(csvContent);

  console.log(`Loaded ${records.length} records`);

  // Get gateway address from environment or detect from first successful trace
  let gatewayAddress = process.env.GATEWAY_ADDRESS;
  if (gatewayAddress) {
    console.log(`Using gateway address from env: ${gatewayAddress}`);
  } else {
    console.log("No gateway address provided. Will detect from first successful trace...");
  }

  // Analyze each transaction
  console.log("\nAnalyzing transactions...");
  const analyses: GapAnalysis[] = [];
  let processed = 0;
  let successCount = 0;
  let failCount = 0;
  const LOG_INTERVAL = 10; // Log gap values every N successful analyses
  let firstFailureLogged = false; // Track if we've logged detailed debug info for first failure

  // Process in batches to avoid overwhelming the API
  const BATCH_SIZE = 10;
  const DELAY_MS = 500; // Delay between batches

  for (let i = 0; i < records.length; i += BATCH_SIZE) {
    const batch = records.slice(i, Math.min(i + BATCH_SIZE, records.length));
    
    const batchPromises = batch.map(async (record) => {
      const analysis = await analyzeGap(record, gatewayAddress);
      
      // Auto-detect gateway address from first successful trace
      if (analysis.success && !gatewayAddress) {
        const trace = await fetchRawTrace(record.txHash);
        if (trace) {
          const endpointCall = findEndpointLzReceiveCall(trace as TraceCall);
          if (endpointCall) {
            const detected = detectGatewayAddress(endpointCall);
            if (detected) {
              gatewayAddress = detected;
              console.log(`\n✓ Detected gateway address: ${gatewayAddress}`);
            }
          }
        }
      }
      
      if (analysis.success) {
        successCount++;
        // Log gap values periodically
        if (successCount % LOG_INTERVAL === 0) {
          console.log(`  [${successCount} successful] Gap: ${analysis.gap.toLocaleString()} gas (${analysis.gapPercentage.toFixed(2)}%) | Endpoint: ${analysis.endpointGas.toLocaleString()} | Gateway: ${analysis.gatewayGas.toLocaleString()} | Type: ${analysis.messageType} | Nonce: ${analysis.nonce}`);
        }
      } else {
        failCount++;
        // Log first few failures to understand the issue
        if (failCount <= 5) {
          console.log(`  ❌ Failed [${failCount}]: ${analysis.error || "Unknown error"}`);
          console.log(`      txHash: ${analysis.txHash}`);
          console.log(`      Type: ${analysis.messageType} | Nonce: ${analysis.nonce}`);
          console.log(`      EndpointGas (from CSV): ${analysis.endpointGas} | GatewayGas (from trace): ${analysis.gatewayGas}`);
        }
        
        // Debug first failure in detail
        if (!firstFailureLogged && failCount === 1) {
          console.log(`\n  🔍 Debugging first failure...`);
          console.log(`  Full txHash: ${record.txHash}`);
          console.log(`  CSV endpointLzReceiveGasUsed: ${record.endpointLzReceiveGasUsed}`);
          const trace = await fetchRawTrace(record.txHash);
          if (trace) {
            console.log(`  Trace root: to=${trace.to}, input starts with: ${trace.input.substring(0, 10)}`);
            if (trace.calls && trace.calls.length > 0) {
              console.log(`  Root has ${trace.calls.length} nested calls`);
              const endpointCall = findEndpointLzReceiveCall(trace as TraceCall);
              if (endpointCall) {
                const endpointGasFromTrace = parseInt(endpointCall.gasUsed, 16);
                console.log(`  ✓ Found endpoint call: to=${endpointCall.to}, gasUsed=${endpointCall.gasUsed} (${endpointGasFromTrace} decimal)`);
                console.log(`  CSV says endpointGas: ${record.endpointLzReceiveGasUsed}, Trace says: ${endpointGasFromTrace}`);
                if (endpointCall.calls) {
                  console.log(`  Endpoint call has ${endpointCall.calls.length} nested calls`);
                  for (let j = 0; j < Math.min(3, endpointCall.calls.length); j++) {
                    const call = endpointCall.calls[j];
                    const callGas = parseInt(call.gasUsed, 16);
                    console.log(`    Call ${j}: to=${call.to}, input starts with: ${call.input.substring(0, 10)}, gasUsed=${call.gasUsed} (${callGas} decimal)`);
                  }
                    const gatewayCall = findGatewayLzReceiveCall(endpointCall, gatewayAddress);
                    if (gatewayCall) {
                      const gatewayGasFromTrace = parseInt(gatewayCall.gasUsed, 16);
                      console.log(`  ✓ Found gateway call: to=${gatewayCall.to}, gasUsed=${gatewayCall.gasUsed} (${gatewayGasFromTrace} decimal)`);
                      console.log(`  Gap calculation (from trace): ${endpointGasFromTrace} - ${gatewayGasFromTrace} = ${endpointGasFromTrace - gatewayGasFromTrace}`);
                      console.log(`  Note: CSV endpointLzReceiveGasUsed=${record.endpointLzReceiveGasUsed} (for reference only, not used in calculation)`);
                    } else {
                      console.log(`  ✗ Could not find gateway call in endpoint's nested calls`);
                    }
                } else {
                  console.log(`  ⚠️  Endpoint call has no nested calls`);
                }
              } else {
                console.log(`  ✗ Could not find endpoint call in trace`);
              }
            } else {
              console.log(`  ⚠️  Trace has no nested calls`);
            }
          } else {
            console.log(`  ✗ Could not fetch trace`);
          }
          firstFailureLogged = true;
        }
      }
      return analysis;
    });
    
    const batchResults = await Promise.all(batchPromises);
    analyses.push(...batchResults);
    processed += batch.length;
    
    console.log(`Processed ${processed}/${records.length} transactions (${successCount} successful, ${failCount} failed)`);
    
    // Delay between batches
    if (i + BATCH_SIZE < records.length) {
      await new Promise(resolve => setTimeout(resolve, DELAY_MS));
    }
  }
  
  if (gatewayAddress) {
    console.log(`\nUsing gateway address: ${gatewayAddress}`);
  }

  // Analyze failure reasons
  const errorTypes: Record<string, number> = {};
  for (const analysis of analyses) {
    if (!analysis.success && analysis.error) {
      errorTypes[analysis.error] = (errorTypes[analysis.error] || 0) + 1;
    }
  }
  
  if (Object.keys(errorTypes).length > 0) {
    console.log("\n=== Failure Analysis ===");
    console.log("Error types and counts:");
    for (const [error, count] of Object.entries(errorTypes)) {
      console.log(`  ${error}: ${count}`);
    }
  }

  // Calculate overall statistics
  console.log("\n=== Overall Statistics ===");
  const overallStats = calculateStats(analyses);
  if (overallStats) {
    console.log(`Total transactions: ${overallStats.total}`);
    console.log(`Successful analyses: ${overallStats.successful}`);
    console.log(`Failed analyses: ${overallStats.failed}`);
    console.log(`\nGap Statistics (gas units):`);
    console.log(`  Min: ${overallStats.gap.min.toLocaleString()}`);
    console.log(`  Max: ${overallStats.gap.max.toLocaleString()}`);
    console.log(`  Avg: ${overallStats.gap.avg.toLocaleString()}`);
    console.log(`  P50: ${overallStats.gap.p50.toLocaleString()}`);
    console.log(`  P95: ${overallStats.gap.p95.toLocaleString()}`);
    console.log(`  P99: ${overallStats.gap.p99.toLocaleString()}`);
    console.log(`\nGap Statistics (percentage):`);
    console.log(`  Min: ${overallStats.gapPercentage.min.toFixed(2)}%`);
    console.log(`  Max: ${overallStats.gapPercentage.max.toFixed(2)}%`);
    console.log(`  Avg: ${overallStats.gapPercentage.avg.toFixed(2)}%`);
    console.log(`  P50: ${overallStats.gapPercentage.p50.toFixed(2)}%`);
    console.log(`  P95: ${overallStats.gapPercentage.p95.toFixed(2)}%`);
    console.log(`  P99: ${overallStats.gapPercentage.p99.toFixed(2)}%`);
  } else {
    console.log("No successful analyses to calculate statistics.");
  }

  // Calculate statistics by message type
  console.log("\n=== Statistics by Message Type ===");
  const statsByType = calculateStatsByMessageType(analyses);
  for (const [messageType, stats] of Object.entries(statsByType)) {
    if (stats) {
      console.log(`\n${messageType}:`);
      console.log(`  Successful: ${stats.successful}/${stats.total}`);
      if (stats.successful > 0) {
        console.log(`  Gap Avg: ${stats.gap.avg.toLocaleString()} gas (${stats.gapPercentage.avg.toFixed(2)}%)`);
        console.log(`  Gap P95: ${stats.gap.p95.toLocaleString()} gas (${stats.gapPercentage.p95.toFixed(2)}%)`);
        console.log(`  Gap P99: ${stats.gap.p99.toLocaleString()} gas (${stats.gapPercentage.p99.toFixed(2)}%)`);
      }
    }
  }

  // Save detailed results to CSV
  const outputPath = path.resolve(process.cwd(), "lzreceive-gap-analysis.csv");
  const csvHeader = "txHash,messageType,nonce,endpointGas,gatewayGas,gap,gapPercentage,success,error\n";
  const csvRows = analyses.map(a => 
    `${a.txHash},${a.messageType},${a.nonce},${a.endpointGas},${a.gatewayGas},${a.gap},${a.gapPercentage.toFixed(2)},${a.success},${a.error || ""}`
  ).join("\n");
  
  await fs.writeFile(outputPath, csvHeader + csvRows);
  console.log(`\n✓ Detailed results saved to ${outputPath}`);

  // Save summary statistics to JSON
  const summaryPath = path.resolve(process.cwd(), "lzreceive-gap-summary.json");
  const summary = {
    overall: overallStats,
    byMessageType: statsByType,
    generatedAt: new Date().toISOString()
  };
  await fs.writeFile(summaryPath, JSON.stringify(summary, null, 2));
  console.log(`✓ Summary statistics saved to ${summaryPath}`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
