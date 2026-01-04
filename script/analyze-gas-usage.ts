import { ethers } from "ethers";
import axios from "axios";
import * as dotenv from "dotenv";
import { promises as fs } from "fs";
import path from "path";

dotenv.config();

// Configuration
const SENDER_ADDRESS = "0x64b5b5a618072c1e4d137f91af780e3b17a81f3f";
const SENDER_EID = 40161;
const RECEIVER_ADDRESS = "0xddf5218dbff297addf17fb7977e2469d774545ed";
const RECEIVER_EID = 40259;
const LAYERZERO_SCAN_API_BASE = "https://scan-testnet.layerzero-api.com/v1";
const EXOSCAN_API_BASE = "https://explorer-api.exoscan.org/api/v2";
const RPC_URL = process.env.IMUACHAIN_TESTNET_RPC;

if (!RPC_URL) {
  throw new Error("IMUACHAIN_TESTNET_RPC must be set in .env");
}

// Constants
const ENDPOINT_ADDRESS = "0x6EDCE65403992e310A62460808c4b910D972f10f";
const ASSETS_PRECOMPILE = "0x0000000000000000000000000000000000000804";
const DELEGATION_PRECOMPILE = "0x0000000000000000000000000000000000000805";
const OAPP_LZ_RECEIVE_SELECTOR = "0x13137d65"; // lzReceive on OApp
const ENDPOINT_LZ_RECEIVE_SELECTOR = "0x0c0c389e"; // lzReceive on Endpoint
const EXECUTE_302_SELECTOR = "0x761f7480"; // execute302 on Endpoint

// Action enum mapping (from GatewayStorage.sol)
const Action = {
  0: "RESPOND",
  1: "REQUEST_ADD_WHITELIST_TOKEN",
  2: "REQUEST_DEPOSIT_LST",
  3: "REQUEST_DEPOSIT_NST",
  4: "REQUEST_WITHDRAW_LST",
  5: "REQUEST_WITHDRAW_NST",
  6: "REQUEST_SUBMIT_REWARD",
  7: "REQUEST_CLAIM_REWARD",
  8: "REQUEST_DELEGATE_TO",
  9: "REQUEST_UNDELEGATE_FROM",
  10: "REQUEST_DEPOSIT_THEN_DELEGATE_TO",
  11: "REQUEST_MARK_BOOTSTRAP",
  12: "REQUEST_ASSOCIATE_OPERATOR",
  13: "REQUEST_DISSOCIATE_OPERATOR",
} as Record<number, string>;

interface MessageData {
  pathway: {
    srcEid: number;
    dstEid: number;
    sender: {
      address: string;
    };
    receiver: {
      address: string;
    };
    nonce: number;
  };
  source: {
    tx: {
      payload: string;
      resolvedPayload: string;
    };
  };
  destination: {
    status: string;
    tx?: {
      txHash: string;
      blockNumber: number;
      blockTimestamp: number;
    };
  };
  guid: string;
}

interface ApiResponse {
  data: MessageData[];
  nextToken?: string;
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
  calls: TraceCall[];
  from: string;
  gas: string;
  gasUsed: string;
  input: string;
  output: string;
  to: string;
  type: string;
  value: string;
}

interface GasAnalysis {
  txHash: string;
  blockNumber: number;
  blockTimestamp: number;
  nonce: number;
  guid: string;
  messageType: string;
  actionValue: number;
  executionType: "execute302" | "endpoint_lzReceive";
  txGasLimit: string;
  endpointLzReceiveGasUsedDecimal: number;
  oappLzReceiveGasUsedDecimal: number;
  protocolOverheadGasDecimal: number;
  assetsPrecompileGasUsedDecimal?: number;
  delegationPrecompileGasUsedDecimal?: number;
  totalPrecompileGasUsed: number;
  rawTrace?: TraceResult;
}

const DELIVERED_STATUS_NAMES = new Set([
  "DELIVERED",
  "SUCCESS",
  "SUCCEEDED"
]);

function normalizeStatusName(message: MessageData): string {
  return (message.destination?.status || "").toUpperCase();
}

function isDeliveredStatus(message: MessageData): boolean {
  return DELIVERED_STATUS_NAMES.has(normalizeStatusName(message));
}

function matchesTargetPathway(message: MessageData): boolean {
  const senderMatch = 
    message.pathway.sender.address.toLowerCase() === SENDER_ADDRESS.toLowerCase() &&
    message.pathway.srcEid === SENDER_EID;
  
  const receiverMatch = 
    message.pathway.receiver.address.toLowerCase() === RECEIVER_ADDRESS.toLowerCase() &&
    message.pathway.dstEid === RECEIVER_EID;
  
  return senderMatch && receiverMatch;
}

async function fetchMessages(nextToken?: string, limit: number = 100): Promise<ApiResponse> {
  const url = `${LAYERZERO_SCAN_API_BASE}/messages/oapp/${RECEIVER_EID}/${RECEIVER_ADDRESS}`;
  const params: any = { limit };
  if (nextToken) {
    params.nextToken = nextToken;
  }
  
  console.log(`Fetching messages${nextToken ? ` (nextToken: ${nextToken.substring(0, 20)}...)` : ""}...`);
  
  const response = await axios.get<ApiResponse>(url, { params });
  return response.data;
}

async function fetchAllMessages(): Promise<MessageData[]> {
  const allMessages: MessageData[] = [];
  let nextToken: string | undefined = undefined;
  let hasMorePages = true;
  let pageCount = 0;
  
  console.log("Fetching all messages from LayerZero Scan...");
  console.log(`Target pathway: ${SENDER_ADDRESS} (EID ${SENDER_EID}) -> ${RECEIVER_ADDRESS} (EID ${RECEIVER_EID})\n`);
  
  let totalFetched = 0;
  let totalFiltered = 0;
  
  while (hasMorePages) {
    pageCount++;
    let response: ApiResponse;
    try {
      response = await fetchMessages(nextToken);
    } catch (error) {
      if (axios.isAxiosError(error) && error.response?.status === 404) {
        console.log("Reached final page from LayerZero Scan (404).");
        break;
      }
      throw error;
    }
    
    const messages = [...response.data].reverse();
    totalFetched += messages.length;
    let pageFiltered = 0;
    
    for (const message of messages) {
      if (!matchesTargetPathway(message)) {
        pageFiltered++;
        continue;
      }
      
      allMessages.push(message);
    }
    
    totalFiltered += pageFiltered;
    if (pageFiltered > 0) {
      console.log(`  Page ${pageCount}: ${messages.length} messages fetched, ${pageFiltered} filtered, ${messages.length - pageFiltered} processed`);
    }
    
    if (response.nextToken) {
      nextToken = response.nextToken;
      hasMorePages = true;
    } else {
      hasMorePages = false;
    }
    
    if (pageCount > 100) {
      console.warn("Reached page limit (100), stopping search");
      break;
    }
  }
  
  allMessages.sort((a, b) => a.pathway.nonce - b.pathway.nonce);
  
  console.log(`\nTotal: ${totalFetched} messages fetched, ${totalFiltered} filtered, ${allMessages.length} matching target pathway`);
  
  return allMessages;
}

async function fetchRawTrace(txHash: string): Promise<TraceResult | null> {
  try {
    const url = `${EXOSCAN_API_BASE}/transactions/${txHash}/raw-trace`;
    const response = await axios.get<TraceResult>(url, {
      headers: { accept: "application/json" },
    });
    return response.data;
  } catch (error) {
    if (axios.isAxiosError(error)) {
      if (error.response?.status === 404) {
        // Trace pruned/not available - this is expected for old messages, silently skip
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

async function getTransactionReceipt(provider: ethers.Provider, txHash: string): Promise<ethers.TransactionReceipt | null> {
  try {
    return await provider.getTransactionReceipt(txHash);
  } catch (error) {
    console.warn(`Warning: unable to fetch receipt for tx ${txHash}: ${(error as Error).message}`);
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

function findOAppReceiveCall(endpointCall: TraceCall): TraceCall | null {
  // Search nested calls for the endpoint calling the OApp's lzReceive
  if (endpointCall.calls) {
    for (const call of endpointCall.calls) {
      if (call.to.toLowerCase() === RECEIVER_ADDRESS.toLowerCase() && 
          call.input.startsWith(OAPP_LZ_RECEIVE_SELECTOR)) {
        return call;
      }
      // Recursively search in case there are intermediate proxy/wrapper calls
      const found = findOAppReceiveCall(call);
      if (found) return found;
    }
  }
  
  return null;
}

function findPrecompileCalls(call: TraceCall, precompileAddress: string): TraceCall[] {
  const results: TraceCall[] = [];
  
  if (call.to.toLowerCase() === precompileAddress.toLowerCase()) {
    results.push(call);
  }
  
  if (call.calls) {
    for (const nestedCall of call.calls) {
      results.push(...findPrecompileCalls(nestedCall, precompileAddress));
    }
  }
  
  return results;
}

function decodeActionFromPayload(payload: string): { action: number; actionName: string } {
  try {
    // Payload is hex string, first byte is the action
    if (!payload || payload === "0x" || payload.length < 4) {
      return { action: -1, actionName: "UNKNOWN" };
    }
    
    // Remove 0x prefix and get first byte (2 hex chars = 1 byte)
    const firstByte = payload.substring(2, 4);
    const action = parseInt(firstByte, 16);
    const actionName = Action[action] || `UNKNOWN_${action}`;
    
    return { action, actionName };
  } catch (error) {
    console.warn(`Warning: unable to decode action from payload: ${(error as Error).message}`);
    return { action: -1, actionName: "UNKNOWN" };
  }
}

function determineExecutionType(trace: TraceResult): "execute302" | "endpoint_lzReceive" {
  // Check if root call is to Endpoint.lzReceive (selector: 0x0c0c389e) or execute302 (0x761f7480)
  if (trace.input.startsWith(EXECUTE_302_SELECTOR)) {
    return "execute302";
  }
  if (trace.input.startsWith(ENDPOINT_LZ_RECEIVE_SELECTOR)) {
    return "endpoint_lzReceive";
  }
  
  // Check nested calls
  if (trace.calls) {
    for (const call of trace.calls) {
      if (call.input && call.input.startsWith(EXECUTE_302_SELECTOR)) {
        return "execute302";
      }
      if (call.input && call.input.startsWith(ENDPOINT_LZ_RECEIVE_SELECTOR)) {
        return "endpoint_lzReceive";
      }
    }
  }
  
  return "execute302"; // Default
}

async function analyzeMessageGas(
  provider: ethers.Provider,
  message: MessageData
): Promise<GasAnalysis | null> {
  if (!message.destination?.tx?.txHash) {
    console.warn(`Message ${message.pathway.nonce} has no destination tx hash, skipping`);
    return null;
  }
  
  const txHash = message.destination.tx.txHash;
  const blockNumber = message.destination.tx.blockNumber;
  const blockTimestamp = message.destination.tx.blockTimestamp;
  
  console.log(`\nAnalyzing message nonce ${message.pathway.nonce}, tx: ${txHash}`);
  
  // Fetch raw trace from Exoscan API
  const trace = await fetchRawTrace(txHash);
  if (!trace) {
    // Trace may be pruned for old messages - silently skip
    return null;
  }
  
  // Get transaction receipt and transaction for gas limit
  const receipt = await getTransactionReceipt(provider, txHash);
  if (!receipt) {
    console.warn(`  Failed to fetch receipt for ${txHash}`);
    return null;
  }
  
  // Get transaction to access gasLimit
  let txGasLimit = "0";
  try {
    const tx = await provider.getTransaction(txHash);
    if (tx) {
      txGasLimit = tx.gasLimit.toString();
    }
  } catch (error) {
    console.warn(`  Failed to fetch transaction for ${txHash}, using receipt gasUsed as fallback`);
    txGasLimit = receipt.gasUsed.toString();
  }
  
  // 1. Find the Endpoint lzReceive gas (the outermost call we care about)
  const endpointCall = findEndpointLzReceiveCall(trace as TraceCall);
  
  if (!endpointCall) {
    console.warn(`  Could not find endpoint lzReceive call in trace`);
    return null;
  }
  
  // 2. Find the OApp gas (Work done specifically by Gateway)
  const oappCall = findOAppReceiveCall(endpointCall);
  if (!oappCall) {
    console.warn(`  Could not find OApp lzReceive call in trace`);
  }

  const endpointGas = parseInt(endpointCall.gasUsed, 16);
  const oappGas = oappCall ? parseInt(oappCall.gasUsed, 16) : endpointGas;
  const protocolOverhead = endpointGas - oappGas;

  // Find precompile calls within the OApp execution
  const assetsCalls = findPrecompileCalls(oappCall || endpointCall, ASSETS_PRECOMPILE);
  const delegationCalls = findPrecompileCalls(oappCall || endpointCall, DELEGATION_PRECOMPILE);
  
  // Decode action from payload
  const payload = message.source.tx.resolvedPayload || message.source.tx.payload;
  const { action, actionName } = decodeActionFromPayload(payload);
  
  // Determine execution type
  const executionType = determineExecutionType(trace);
  
  // Calculate total precompile gas
  const assetsGas = assetsCalls.reduce((sum, call) => sum + parseInt(call.gasUsed, 16), 0);
  const delegationGas = delegationCalls.reduce((sum, call) => sum + parseInt(call.gasUsed, 16), 0);
  const totalPrecompileGas = assetsGas + delegationGas;
  
  const analysis: GasAnalysis = {
    txHash,
    blockNumber,
    blockTimestamp,
    nonce: message.pathway.nonce,
    guid: message.guid,
    messageType: actionName,
    actionValue: action,
    executionType,
    txGasLimit,
    endpointLzReceiveGasUsedDecimal: endpointGas,
    oappLzReceiveGasUsedDecimal: oappGas,
    protocolOverheadGasDecimal: protocolOverhead,
    totalPrecompileGasUsed: totalPrecompileGas,
  };
  
  if (assetsCalls.length > 0) {
    analysis.assetsPrecompileGasUsedDecimal = assetsGas;
  }
  
  if (delegationCalls.length > 0) {
    analysis.delegationPrecompileGasUsedDecimal = delegationGas;
  }
  
  console.log(`  ✓ Action: ${actionName} (${action})`);
  console.log(`  ✓ Execution type: ${executionType}`);
  console.log(`  ✓ Endpoint lzReceive Gas: ${endpointGas.toLocaleString()}`);
  console.log(`  ✓ OApp lzReceive Gas: ${oappGas.toLocaleString()}`);
  console.log(`  ✓ Protocol Overhead: ${protocolOverhead.toLocaleString()}`);
  console.log(`  ✓ Assets precompile gas: ${assetsGas.toLocaleString()}`);
  console.log(`  ✓ Delegation precompile gas: ${delegationGas.toLocaleString()}`);
  
  return analysis;
}

async function main() {
  console.log("=== Gas Usage Analysis Script ===\n");
  console.log(`Target Pathway:`);
  console.log(`  Sender: ${SENDER_ADDRESS} (EID: ${SENDER_EID})`);
  console.log(`  Receiver: ${RECEIVER_ADDRESS} (EID: ${RECEIVER_EID})`);
  console.log(`RPC URL: ${RPC_URL}\n`);
  
  // Setup provider
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  
  // Fetch all messages
  const allMessages = await fetchAllMessages();
  
  if (allMessages.length === 0) {
    console.log("No messages found matching target pathway. Exiting.");
    return;
  }
  
  // Filter for delivered messages only
  const deliveredMessages = allMessages.filter(isDeliveredStatus);
  console.log(`\nFound ${deliveredMessages.length} delivered messages out of ${allMessages.length} total messages`);
  
  if (deliveredMessages.length === 0) {
    console.log("No delivered messages found. Exiting.");
    return;
  }
  
  // Analyze each delivered message
  console.log(`\n=== Analyzing Gas Usage ===\n`);
  const analyses: GasAnalysis[] = [];
  let skippedCount = 0;
  
  for (let i = 0; i < deliveredMessages.length; i++) {
    const message = deliveredMessages[i];
    console.log(`[${i + 1}/${deliveredMessages.length}] Processing nonce ${message.pathway.nonce}...`);
    
    const analysis = await analyzeMessageGas(provider, message);
    if (analysis) {
      analyses.push(analysis);
    } else {
      skippedCount++;
    }
    
    // Small delay to avoid rate limiting
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  
  console.log(`\n=== Analysis Complete ===`);
  console.log(`Successfully analyzed ${analyses.length} out of ${deliveredMessages.length} messages`);
  if (skippedCount > 0) {
    console.log(`Skipped ${skippedCount} messages (traces pruned/not available)`);
  }
  
  // Sort by nonce
  analyses.sort((a, b) => a.nonce - b.nonce);
  
  // Calculate statistics
  const gasUsages = analyses.map(a => a.endpointLzReceiveGasUsedDecimal);
  const maxGas = Math.max(...gasUsages);
  const minGas = Math.min(...gasUsages);
  const avgGas = gasUsages.reduce((sum, gas) => sum + gas, 0) / gasUsages.length;
  
  console.log(`\n=== Statistics (Endpoint lzReceive) ===`);
  console.log(`Max gas: ${maxGas.toLocaleString()}`);
  console.log(`Min gas: ${minGas.toLocaleString()}`);
  console.log(`Avg gas: ${Math.round(avgGas).toLocaleString()}`);
  
  // Group by message type
  const byType: Record<string, number[]> = {};
  for (const analysis of analyses) {
    if (!byType[analysis.messageType]) {
      byType[analysis.messageType] = [];
    }
    byType[analysis.messageType].push(analysis.endpointLzReceiveGasUsedDecimal);
  }
  
  console.log(`\n=== Gas Usage by Message Type (Endpoint lzReceive) ===`);
  for (const [type, gasValues] of Object.entries(byType)) {
    const max = Math.max(...gasValues);
    const min = Math.min(...gasValues);
    const avg = gasValues.reduce((sum, gas) => sum + gas, 0) / gasValues.length;
    console.log(`  ${type}: max=${max.toLocaleString()}, min=${min.toLocaleString()}, avg=${Math.round(avg).toLocaleString()} (${gasValues.length} messages)`);
  }
  
  // Save to JSON
  const jsonPath = path.resolve(process.cwd(), "gas-analysis-results.json");
  await fs.writeFile(jsonPath, JSON.stringify(analyses, null, 2));
  console.log(`\n✓ Results saved to ${jsonPath}`);
  
  // Save to CSV
  const csvPath = path.resolve(process.cwd(), "gas-analysis-results.csv");
  const csvHeader = [
    "txHash",
    "blockNumber",
    "blockTimestamp",
    "nonce",
    "guid",
    "messageType",
    "actionValue",
    "executionType",
    "txGasLimit",
    "endpointLzReceiveGasUsed",
    "oappLzReceiveGasUsed",
    "protocolOverhead",
    "assetsPrecompileGasUsed",
    "delegationPrecompileGasUsed",
    "totalPrecompileGasUsed"
  ].join(",");
  
  const csvRows = analyses.map(a => [
    a.txHash,
    a.blockNumber,
    a.blockTimestamp,
    a.nonce,
    a.guid,
    a.messageType,
    a.actionValue,
    a.executionType,
    a.txGasLimit,
    a.endpointLzReceiveGasUsedDecimal,
    a.oappLzReceiveGasUsedDecimal,
    a.protocolOverheadGasDecimal,
    a.assetsPrecompileGasUsedDecimal || "",
    a.delegationPrecompileGasUsedDecimal || "",
    a.totalPrecompileGasUsed
  ].join(","));
  
  const csvContent = [csvHeader, ...csvRows].join("\n");
  await fs.writeFile(csvPath, csvContent);
  console.log(`✓ CSV saved to ${csvPath}`);
}

// Run the script
main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

