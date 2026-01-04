import { ethers } from "hardhat";
import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as bech32 from "bech32";

// Constants
const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
const DELEGATION_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000805";
const SRC_CHAIN_ID = 101;
const SRC_SENDER_ADDRESS = "0x0000000000000000000000000000000000000001";
// Use a token that exists in genesis (Tether USD from local_node.sh)
const TOKEN_ADDR = "0xdac17f958d2ee523a2206206994597c13d831ec7"; // Tether USD (registered in genesis)
const ACTION_DEPOSIT_AND_DELEGATE = 10; // REQUEST_DEPOSIT_THEN_DELEGATE_TO (enum value 10, not 18)
const OAPP_LZ_RECEIVE_SELECTOR = "0x13137d65";
const COSMOS_RPC_URL = "http://localhost:26657";

interface TraceCall {
    to: string;
    input: string;
    gasUsed: string;
    calls?: TraceCall[];
}

interface GasBoundResult {
    nonce: number;
    txHash: string;
    gasUsed: number;
}

/**
 * Converts a bech32 address (like im1...) to its 0x hex equivalent.
 */
function bech32ToHex(address: string): string {
    const decoded = bech32.decode(address);
    const data = bech32.fromWords(decoded.words);
    return ethers.hexlify(new Uint8Array(data));
}

/**
 * Converts an EVM address (0x...) to a Cosmos bech32 address with prefix "im".
 * In Ethermint chains, the Cosmos address is derived from the EVM address (20 bytes),
 * not from the public key using Cosmos SDK's standard derivation.
 */
function hexToBech32(hexAddress: string, prefix: string = "im"): string {
    // Remove 0x prefix if present
    const cleanHex = hexAddress.replace(/^0x/i, "");
    // Convert hex to bytes
    const bytes = ethers.getBytes("0x" + cleanHex);
    // Encode to bech32
    const words = bech32.toWords(bytes);
    return bech32.encode(prefix, words);
}


async function registerOperatorViaCli(privateKey: string, deployer: any): Promise<string> {
    console.log("\n3. Funding and Registering operator via CLI...");
    
    // 3.1 Derive the EVM address from private key, then convert to Cosmos bech32 address
    // In Ethermint chains, Cosmos address is derived from EVM address (20 bytes), not from public key
    const evmWallet = new ethers.Wallet(privateKey);
    const evmAddress = evmWallet.address;
    console.log(`EVM address: ${evmAddress}`);
    
    // Convert EVM address to Cosmos bech32 address with prefix "im"
    let cosmosAddr = hexToBech32(evmAddress, "im");
    console.log(`Derived Cosmos address: ${cosmosAddr}`);

    // 3.2 Fund the Cosmos account via vanilla EVM transfer
    const hexToFund = bech32ToHex(cosmosAddr);
    console.log(`Cosmos address for registration: ${cosmosAddr}`);
    console.log(`Equivalent hex address to fund: ${hexToFund}`);

    try {
        const balance = await ethers.provider.getBalance(hexToFund);
        if (balance < ethers.parseEther("1.0")) {
            console.log(`Funding ${hexToFund} via EVM...`);
            const fundTx = await deployer.sendTransaction({
                to: hexToFund,
                value: ethers.parseEther("10.0") // Send 10 IMUA
            });
            await fundTx.wait();
            console.log("Funding successful.");
        } else {
            console.log("Account already has sufficient balance.");
        }
    } catch (e) {
        console.log("Funding via EVM failed. Proceeding...");
    }
    
    // 3.3 Register operator using imuad CLI
    // Based on: imuachain/x/operator/client/cli/tx.go
    // Command: imuad tx operator register-operator --meta-info <meta-info> 
    //          --commission-rate <rate> --commission-max-rate <max-rate> 
    //          --commission-max-change-rate <max-change-rate>
    //          --from <address> --chain-id <chain-id> --node <rpc-url> --yes
    
    const chainId = "imuachainlocalnet_232-1"; // Adjust if needed
    const metaInfo = "test-operator-1";
    const commissionRate = "0.1"; // 10%
    const commissionMaxRate = "0.2"; // 20%
    const commissionMaxChangeRate = "0.01"; // 1%
    
    // Import the private key using unsafe-import-eth-key command
    // This command accepts a hex-encoded Ethereum private key
    // Use a unique key name based on the full address to avoid conflicts
    const keyName = `operator-${cosmosAddr.replace(/^im/, '')}`; // Use full address without prefix for uniqueness
    const privateKeyHex = privateKey.replace('0x', '');
    
    // Import or verify the key, and get its actual address
    let actualKeyAddress = cosmosAddr;
    try {
        // Check if key already exists and get its address
        try {
            const keyShowOutput = execSync(
                `imuad keys show ${keyName} --keyring-backend test --address 2>&1`,
                { stdio: 'pipe', encoding: 'utf-8' }
            );
            actualKeyAddress = keyShowOutput.trim();
            console.log(`Key ${keyName} already exists with address: ${actualKeyAddress}`);
            
            // Verify the address matches what we expect
            if (actualKeyAddress !== cosmosAddr) {
                console.log(`Error: Key address (${actualKeyAddress}) doesn't match expected (${cosmosAddr})`);
                console.log(`This key was imported with a different private key. Deleting and re-importing...`);
                // Delete the existing key and re-import
                try {
                    execSync(
                        `echo "y" | imuad keys delete ${keyName} --keyring-backend test 2>&1`,
                        { stdio: 'pipe', encoding: 'utf-8' }
                    );
                } catch (deleteError) {
                    // Ignore delete errors
                }
                throw new Error("Key mismatch, will re-import");
            }
        } catch (e: any) {
            // Key doesn't exist or was deleted, import it
            // unsafe-import-eth-key requires a password (min 8 chars) even with test keyring
            // We'll provide a simple password via stdin (password is required but key is stored unencrypted in test mode)
            const password = "testpass123"; // Simple password for test keyring
            console.log(`Importing private key as ${keyName}...`);
            execSync(
                `echo -e "${password}\\n${password}" | imuad keys unsafe-import-eth-key ${keyName} ${privateKeyHex} --keyring-backend test`,
                { stdio: 'inherit', encoding: 'utf-8' }
            );
            
            // Verify the imported key's address
            const keyShowOutput = execSync(
                `imuad keys show ${keyName} --keyring-backend test --address 2>&1`,
                { stdio: 'pipe', encoding: 'utf-8' }
            );
            actualKeyAddress = keyShowOutput.trim();
            console.log(`Key imported successfully. Address: ${actualKeyAddress}`);
            
            // Verify the address matches
            if (actualKeyAddress !== cosmosAddr) {
                throw new Error(`Imported key address (${actualKeyAddress}) doesn't match derived address (${cosmosAddr}). This indicates a key derivation mismatch.`);
            }
        }
    } catch (e: any) {
        const errorMsg = e.message || e.toString();
        if (errorMsg.includes("Key mismatch") || errorMsg.includes("doesn't match")) {
            // Retry import after deletion
            const password = "testpass123";
            console.log(`Re-importing private key as ${keyName}...`);
            execSync(
                `echo -e "${password}\\n${password}" | imuad keys unsafe-import-eth-key ${keyName} ${privateKeyHex} --keyring-backend test`,
                { stdio: 'inherit', encoding: 'utf-8' }
            );
            
            // Verify again
            const keyShowOutput = execSync(
                `imuad keys show ${keyName} --keyring-backend test --address 2>&1`,
                { stdio: 'pipe', encoding: 'utf-8' }
            );
            actualKeyAddress = keyShowOutput.trim();
            if (actualKeyAddress !== cosmosAddr) {
                throw new Error(`Key address mismatch after re-import: ${actualKeyAddress} vs ${cosmosAddr}`);
            }
            console.log(`Key re-imported successfully. Address: ${actualKeyAddress}`);
        } else {
            console.error("Failed to import/verify key:", errorMsg);
            throw e;
        }
    }
    
    // Check if operator already exists before attempting registration
    try {
        console.log(`Checking if operator ${cosmosAddr} already exists...`);
        const queryCmd = [
            "imuad",
            "query",
            "operator",
            "get-operator-info",
            cosmosAddr,
            "--node", COSMOS_RPC_URL,
            "--output", "json"
        ].join(" ");
        
        const queryOutput = execSync(queryCmd, { 
            stdio: 'pipe',
            encoding: 'utf-8',
            env: { ...process.env }
        });
        
        // If query succeeds, operator exists
        // The response contains earnings_addr, approve_addr, operator_meta_info, etc.
        // but NOT operator_addr - so check for any of these fields
        const operatorInfo = JSON.parse(queryOutput.trim());
        if (operatorInfo && (operatorInfo.earnings_addr || operatorInfo.approve_addr || operatorInfo.operator_meta_info)) {
            console.log(`✅ Operator already exists at ${cosmosAddr}, skipping registration.`);
            return cosmosAddr;
        }
    } catch (e: any) {
        // Query failed - operator doesn't exist or query error
        // This is expected if operator doesn't exist, so we'll proceed with registration
        console.log(`Operator ${cosmosAddr} not found, proceeding with registration...`);
    }
    
    // Register operator using the imported key
    try {
        const cmd = [
            "imuad",
            "tx",
            "operator",
            "register-operator",
            "--meta-info", metaInfo,
            "--commission-rate", commissionRate,
            "--commission-max-rate", commissionMaxRate,
            "--commission-max-change-rate", commissionMaxChangeRate,
            "--from", keyName,
            "--chain-id", chainId,
            "--node", COSMOS_RPC_URL,
            "--keyring-backend", "test",
            "--gas", "auto",
            "--gas-adjustment", "1.5",
            "--gas-prices", "10hua", // Set gas price to 10hua per gas unit (higher than required 7hua)
            "--yes"
        ].join(" ");
        
        console.log(`Executing: ${cmd}`);
        const output = execSync(cmd, { 
            stdio: 'inherit',
            encoding: 'utf-8',
            env: { ...process.env }
        });
        
        console.log("Operator registration successful.");
    } catch (e: any) {
        // execSync error object structure: { message, stderr, stdout, status, signal, output }
        const errorMsg = e.message || e.toString() || "";
        const errorOutput = (e.stderr?.toString() || e.stdout?.toString() || e.output?.join("") || "").toLowerCase();
        const fullError = (errorMsg + " " + errorOutput).toLowerCase();
        
        // Check for various "already exists" error patterns (fallback in case query didn't catch it)
        // The error message format is: "SetOperatorInfo: operator already exists, address: ..."
        if (fullError.includes("operator already exists") || 
            fullError.includes("already exists") ||
            fullError.includes("already registered") ||
            fullError.includes("setoperatorinfo: operator already exists")) {
            console.log(`Operator already registered (address: ${cosmosAddr}), skipping registration.`);
            // This is fine - operator is already registered, we can continue
        } else {
            console.error("Operator registration failed:");
            console.error("Error message:", errorMsg);
            console.error("Error output:", errorOutput);
            throw e;
        }
    }

    return cosmosAddr;
}

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Using deployer:", deployer.address);

    // Use a fixed private key for the operator (for testing consistency)
    // This is a well-known test private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
    // Corresponding address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    const operatorPrivateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const operatorWallet = new ethers.Wallet(operatorPrivateKey);
    console.log(`Using fixed operator private key (address: ${operatorWallet.address})`);

    // 0. Deploy a Mock Endpoint to avoid reverts during initialization/calls
    console.log("\n0. Deploying EndpointMock...");
    const EndpointMock = await ethers.getContractFactory("EndpointMock");
    const endpointMock = await EndpointMock.deploy(SRC_CHAIN_ID);
    await endpointMock.waitForDeployment();
    console.log("EndpointMock deployed to:", endpointMock.target);

    // 1. Deploy ImuachainGateway with Mock Endpoint
    console.log("\n1. Deploying ImuachainGateway...");
    const ImuachainGateway = await ethers.getContractFactory("ImuachainGateway");
    const gatewayLogic = await ImuachainGateway.deploy(endpointMock.target);
    await gatewayLogic.waitForDeployment();
    console.log("ImuachainGateway logic deployed to:", gatewayLogic.target);

    const ProxyAdmin = await ethers.getContractFactory("ProxyAdmin");
    const proxyAdmin = await ProxyAdmin.deploy();
    await proxyAdmin.waitForDeployment();
    console.log("ProxyAdmin deployed to:", proxyAdmin.target);

    const TransparentProxy = await ethers.getContractFactory("TransparentUpgradeableProxy");
    const initData = gatewayLogic.interface.encodeFunctionData("initialize", [deployer.address]);
    const proxy = await TransparentProxy.deploy(gatewayLogic.target, proxyAdmin.target, initData);
    await proxy.waitForDeployment();
    const gateway = ImuachainGateway.attach(proxy.target) as any;
    console.log("ImuachainGateway proxy deployed to:", gateway.target);

    // 2. Set Peer for source chain
    console.log("\n2. Setting peer for source chain...");
    const dummyPeer = ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32);
    await gateway.setPeer(SRC_CHAIN_ID, dummyPeer);
    console.log("Peer set for chain", SRC_CHAIN_ID);

    // 3. Register Operator (CLI) - using newly generated private key
    const operatorAddr = await registerOperatorViaCli(operatorPrivateKey, deployer);

    // 4. Authorize Gateway in Assets Precompile
    console.log("\n4. Authorizing gateway in Assets precompile...");
    const assetsPrecompile = (await ethers.getContractAt("IAssets", ASSETS_PRECOMPILE_ADDRESS)) as any;
    try {
        const tx = await assetsPrecompile.connect(deployer).updateAuthorizedGateways([gateway.target]);
        await tx.wait();
        console.log("Gateway authorized in Assets precompile.");
    } catch (e) {
        console.log("Failed to authorize gateway. Ensure deployer has permissions or gateway is already authorized.");
    }

    // 4.1 Verify Gateway Authorization
    console.log("\n4.1 Verifying gateway authorization...");
    try {
        const [authSuccess, isAuthorized] = await assetsPrecompile.isAuthorizedGateway(gateway.target);
        if (!authSuccess || !isAuthorized) {
            throw new Error("Gateway is not properly authorized in Assets precompile");
        }
        console.log("✅ Gateway is authorized in Assets precompile");
    } catch (e: any) {
        console.error("❌ Gateway authorization verification failed:", e.message);
        throw e;
    }

    // 4.2 Verify Client Chain Registration
    console.log("\n4.2 Verifying client chain registration...");
    try {
        const [chainSuccess, isChainRegistered] = await assetsPrecompile.isRegisteredClientChain(SRC_CHAIN_ID);
        if (!chainSuccess || !isChainRegistered) {
            throw new Error(`Client chain ${SRC_CHAIN_ID} is not properly registered`);
        }
        console.log(`✅ Client chain ${SRC_CHAIN_ID} is registered`);
    } catch (e: any) {
        console.error("❌ Client chain registration verification failed:", e.message);
        throw e;
    }

    // 4.3 Verify Gateway Address
    console.log("\n4.3 Verifying gateway address...");
    const gatewayAddress = await gateway.getAddress();
    if (!gatewayAddress || gatewayAddress === ethers.ZeroAddress) {
        throw new Error("Gateway address is invalid");
    }
    console.log(`✅ Gateway address: ${gatewayAddress}`);

    // 4.4 Verify Operator Registration
    console.log("\n4.4 Verifying operator registration...");
    if (!operatorAddr || operatorAddr.length === 0) {
        throw new Error("Operator address is invalid");
    }
    console.log(`✅ Operator address: ${operatorAddr}`);

    // 5. Client chain is already registered in genesis (layer_zero_chain_id=101)
    // No need to register it again

    // 6. Continuous Gas Measurement
    const TOTAL_MESSAGES = 1000;
    const results: GasBoundResult[] = [];

    console.log(`\n6. Sending ${TOTAL_MESSAGES} deposit + delegate messages...`);

    for (let i = 0; i < TOTAL_MESSAGES; i++) {
        const stakerAddr = ethers.Wallet.createRandom().address;
        const result = await measureGasDetail(gateway, endpointMock, stakerAddr, 100, i, operatorAddr);
        results.push(result);
        
        if ((i + 1) % 10 === 0) {
            console.log(`Progress: ${i + 1}/${TOTAL_MESSAGES} | Last Gas: ${result.gasUsed}`);
        }
    }

    // 7. Statistics and CSV output
    const gasUsages = results.map(r => r.gasUsed);
    const maxGas = Math.max(...gasUsages);
    const minGas = Math.min(...gasUsages);
    const avgGas = gasUsages.reduce((sum, g) => sum + g, 0) / gasUsages.length;

    console.log("\n=== Statistics ===");
    console.log(`Total Messages: ${TOTAL_MESSAGES}`);
    console.log(`Max Gas: ${maxGas.toLocaleString()}`);
    console.log(`Min Gas: ${minGas.toLocaleString()}`);
    console.log(`Avg Gas: ${Math.round(avgGas).toLocaleString()}`);

    // 8. Save to CSV
    const csvPath = path.join(process.cwd(), "gas-bound-results.csv");
    const csvHeader = "nonce,txHash,gasUsed\n";
    const csvRows = results.map(r => `${r.nonce},${r.txHash},${r.gasUsed}`).join("\n");
    fs.writeFileSync(csvPath, csvHeader + csvRows);
    console.log(`\nResults saved to ${csvPath}`);
}

async function measureGasDetail(gateway: any, endpoint: any, staker: string, amount: number, nonce: number, operator: string): Promise<GasBoundResult> {
    // In Solidity, bytes32(bytes20(addr)) right-pads (address bytes on left, zeros on right)
    // ethers.zeroPadValue left-pads, so we need to manually right-pad
    // bytes32(bytes20(addr)) = [20 address bytes][12 zero bytes]
    function rightPadAddress(addr: string): string {
        const cleanAddr = addr.replace(/^0x/i, "");
        if (cleanAddr.length !== 40) {
            throw new Error(`Invalid address length: ${addr}`);
        }
        // Right-pad: address bytes + 12 zero bytes (24 hex chars)
        return "0x" + cleanAddr + "0".repeat(24);
    }

    const payload = ethers.solidityPacked(
        ["uint8", "bytes32", "uint256", "bytes32", "bytes"],
        [
            ACTION_DEPOSIT_AND_DELEGATE,
            rightPadAddress(staker),
            BigInt(amount),
            rightPadAddress(TOKEN_ADDR),
            ethers.toUtf8Bytes(operator)
        ]
    );

    const origin = {
        srcEid: SRC_CHAIN_ID,
        sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32),
        nonce: BigInt(nonce + 1)
    };

    // We call through the mock endpoint to satisfy the OnlyEndpoint check
    // Set a high gas limit to avoid out-of-gas errors (precompile calls can be expensive)
    const tx = await endpoint.lzReceive(
        gateway.target,
        origin.srcEid,
        origin.sender,
        origin.nonce,
        ethers.ZeroHash,
        payload,
        "0x",
        { gasLimit: 6000000 } // 6M gas limit (same as resume-messages.ts)
    );
    const receipt = await tx.wait();
    if (receipt.status !== 1) {
        throw new Error(`Transaction ${receipt.hash} failed with status ${receipt.status}`);
    }
    
    const trace = await (ethers.provider as any).send("debug_traceTransaction", [
        receipt.hash,
        { tracer: "callTracer" }
    ]);

    const lzReceiveCall = findLzReceiveCallInTrace(trace);
    if (!lzReceiveCall) {
        throw new Error("Could not find lzReceive call in trace");
    }

    return {
        nonce: nonce + 1,
        txHash: receipt.hash,
        gasUsed: parseInt(lzReceiveCall.gasUsed, 16)
    };
}

function findLzReceiveCallInTrace(call: TraceCall): TraceCall | null {
    if (call.input.startsWith(OAPP_LZ_RECEIVE_SELECTOR)) {
        return call;
    }
    if (call.calls) {
        for (const nested of call.calls) {
            const found = findLzReceiveCallInTrace(nested);
            if (found) return found;
        }
    }
    return null;
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
