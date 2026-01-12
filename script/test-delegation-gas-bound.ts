import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { 
    ImuachainClient, 
    hexToBech32, 
    bech32ToHex,
    imuachain,
    cosmos
} from "@imua-xyz/imuajs";

// Extract types and composers from bundle
const { MessageComposer, RegisterOperatorReq, OperatorInfo } = imuachain.operator.v1;
const { Commission, CommissionRates } = cosmos.staking.v1beta1;

// Constants
const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
const DELEGATION_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000805";
const SRC_CHAIN_ID = 101;
const SRC_SENDER_ADDRESS = "0x0000000000000000000000000000000000000001";
// Use a token that exists in genesis (Tether USD from local_node.sh)
const TOKEN_ADDR = "0xdac17f958d2ee523a2206206994597c13d831ec7"; // Tether USD (registered in genesis)
const OAPP_LZ_RECEIVE_SELECTOR = "0x13137d65";
const COSMOS_RPC_URL = "http://localhost:26657";

// Action enum values matching GatewayStorage.sol
enum Action {
    RESPOND = 0,
    REQUEST_ADD_WHITELIST_TOKEN = 1,
    REQUEST_DEPOSIT_LST = 2,
    REQUEST_DEPOSIT_NST = 3,
    REQUEST_WITHDRAW_LST = 4,
    REQUEST_WITHDRAW_NST = 5,
    REQUEST_SUBMIT_REWARD = 6,
    REQUEST_CLAIM_REWARD = 7,
    REQUEST_DELEGATE_TO = 8,
    REQUEST_UNDELEGATE_FROM = 9,
    REQUEST_DEPOSIT_THEN_DELEGATE_TO = 10,
    REQUEST_MARK_BOOTSTRAP = 11,
    REQUEST_ASSOCIATE_OPERATOR = 12,
    REQUEST_DISSOCIATE_OPERATOR = 13
}

interface TraceCall {
    to: string;
    input: string;
    gasUsed: string;
    calls?: TraceCall[];
}

interface GasBoundResult {
    action: string;
    nonce: number;
    txHash: string;
    gasUsed: number;
}

/**
 * Verifies that an operator is properly registered by querying operator info.
 * Returns the operator info if found, throws an error if not found or invalid.
 */
async function verifyOperatorRegistration(
    client: ImuachainClient,
    operatorAddress: string
): Promise<void> {
    try {
        const operatorInfo = await client.getOperatorInfo(operatorAddress);
        
        if (!operatorInfo) {
            throw new Error(`Operator info not found for address: ${operatorAddress}`);
        }
        
        // Verify essential fields are present
        if (!operatorInfo.earnings_addr && !operatorInfo.approve_addr && !operatorInfo.operator_meta_info) {
            throw new Error(`Operator info is incomplete for address: ${operatorAddress}`);
        }
        
        // Log operator details
        console.log(`✅ Operator verified successfully!`);
        console.log(`   Earnings Address: ${operatorInfo.earnings_addr || 'N/A'}`);
        console.log(`   Approve Address: ${operatorInfo.approve_addr || 'N/A'}`);
        console.log(`   Meta Info: ${operatorInfo.operator_meta_info || 'N/A'}`);
        
        if (operatorInfo.commission?.commission_rates) {
            const rates = operatorInfo.commission.commission_rates;
            console.log(`   Commission Rate: ${rates.rate || 'N/A'}`);
            console.log(`   Max Commission Rate: ${rates.max_rate || 'N/A'}`);
            console.log(`   Max Change Rate: ${rates.max_change_rate || 'N/A'}`);
        }
        
        // Verify that the earnings address matches the operator address (if set)
        if (operatorInfo.earnings_addr && operatorInfo.earnings_addr !== operatorAddress) {
            console.warn(`⚠️  Warning: Earnings address (${operatorInfo.earnings_addr}) doesn't match operator address (${operatorAddress})`);
        }
        
    } catch (e: any) {
        const errorMsg = e.message || e.toString();
        // Check if it's a "not found" error vs other error
        if (errorMsg.toLowerCase().includes("not found") || 
            errorMsg.toLowerCase().includes("does not exist") ||
            errorMsg.toLowerCase().includes("404")) {
            throw new Error(`Operator is not registered at address: ${operatorAddress}`);
        }
        throw new Error(`Failed to verify operator registration: ${errorMsg}`);
    }
}

async function registerOperatorViaSDK(privateKey: string, deployer: any): Promise<string> {
    console.log("\n3. Funding and Registering operator via SDK...");
    
    const chainId = "imuachainlocalnet_232-1";
    const metaInfo = "test-operator-1";
    const commissionRate = "0.1"; // 10%
    const commissionMaxRate = "0.2"; // 20%
    const commissionMaxChangeRate = "0.01"; // 1%
    
    // 1. Initialize the Imuachain SDK client
    const client = new ImuachainClient({
        rpcEndpoint: COSMOS_RPC_URL,
        chainId,
        prefix: 'im',
    });
    
    // 2. Initialize the signer from private key
    await client.initSigner(privateKey);
    const cosmosAddr = client.getSignerAddress();
    const evmAddress = client.getSignerEvmAddress();
    
    console.log(`EVM address: ${evmAddress}`);
    console.log(`Derived Cosmos address: ${cosmosAddr}`);
    
    // 3. Fund the Cosmos account via vanilla EVM transfer
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
    
    // 4. Check if operator already exists before attempting registration
    try {
        console.log(`Checking if operator ${cosmosAddr} already exists...`);
        await verifyOperatorRegistration(client, cosmosAddr);
        console.log(`✅ Operator already exists at ${cosmosAddr}, skipping registration.`);
        await client.disconnect();
        return cosmosAddr;
    } catch (e: any) {
        // Query failed - operator doesn't exist or query error
        // This is expected if operator doesn't exist, so we'll proceed with registration
        const errorMsg = e.message || e.toString();
        if (errorMsg.includes("is not registered") || errorMsg.includes("not found")) {
            console.log(`Operator ${cosmosAddr} not found, proceeding with registration...`);
        } else {
            // Unexpected error - log but continue
            console.warn(`Warning: Error checking operator existence: ${errorMsg}`);
            console.log(`Proceeding with registration...`);
        }
    }
    
    // 5. Register operator using the SDK
    try {
        // Construct the RegisterOperatorReq message
        const operatorInfo = {
            earningsAddr: cosmosAddr,
            approveAddr: cosmosAddr,
            operatorMetaInfo: metaInfo,
            clientChainEarningsAddr: undefined,
            commission: Commission.fromPartial({
                commissionRates: CommissionRates.fromPartial({
                    rate: commissionRate,
                    maxRate: commissionMaxRate,
                    maxChangeRate: commissionMaxChangeRate,
                }),
                updateTime: new Date(),
            }),
        };
        
        const registerOperatorReq = {
            fromAddress: cosmosAddr,
            info: operatorInfo,
        };
        
        // Create the message using MessageComposer
        const encodedMsg = MessageComposer.encoded.registerOperator(registerOperatorReq);
        const messages = [encodedMsg];
        
        // Send the transaction
        console.log('Building and broadcasting transaction...');
        const txHash = await client.sendTx(messages, {
            gasLimit: '200000',
            gasPrice: '10',
            feeDenom: 'hua',
            memo: 'Register operator',
        });
        
        console.log("✅ Operator registration transaction successful.");
        console.log(`Transaction hash: ${txHash}`);
        
        // Wait a bit for the transaction to be included and state to update
        console.log("Waiting for transaction to be included in block...");
        await new Promise(resolve => setTimeout(resolve, 2000)); // Wait 2 seconds
        
        // Verify the operator was actually registered
        console.log("Verifying operator registration...");
        await verifyOperatorRegistration(client, cosmosAddr);
        console.log("✅ Operator registration verified on-chain.");
        
    } catch (e: any) {
        const errorMsg = e.message || e.toString() || "";
        const errorOutput = errorMsg.toLowerCase();
        
        // Check for various "already exists" error patterns (fallback in case query didn't catch it)
        if (errorOutput.includes("operator already exists") || 
            errorOutput.includes("already exists") ||
            errorOutput.includes("already registered") ||
            errorOutput.includes("setoperatorinfo: operator already exists")) {
            console.log(`Operator already registered (address: ${cosmosAddr}), verifying...`);
            // Verify it exists on-chain
            try {
                await verifyOperatorRegistration(client, cosmosAddr);
            } catch (verifyError) {
                console.warn(`Warning: Could not verify existing operator: ${verifyError}`);
            }
            // This is fine - operator is already registered, we can continue
        } else {
            console.error("Operator registration failed:");
            console.error("Error message:", errorMsg);
            await client.disconnect();
            throw e;
        }
    }
    
    await client.disconnect();
    return cosmosAddr;
}

/**
 * Helper function to right-pad an address to 32 bytes
 */
function rightPadAddress(addr: string): string {
    const cleanAddr = addr.replace(/^0x/i, "");
    if (cleanAddr.length !== 40) {
        throw new Error(`Invalid address length: ${addr}`);
    }
    // Right-pad: address bytes + 12 zero bytes (24 hex chars)
    return "0x" + cleanAddr + "0".repeat(24);
}

/**
 * Builds payload for different message types based on Action enum
 */
function buildPayload(action: Action, params: {
    staker?: string;
    depositor?: string;
    amount: number;
    token?: string;
    operator?: string;
    validatorID?: string;
    avsOrWithdrawer?: string;
    instantUnbond?: boolean;
}): string {
    switch (action) {
        case Action.REQUEST_DEPOSIT_LST:
        case Action.REQUEST_WITHDRAW_LST:
            if (!params.staker || !params.token) {
                throw new Error("Missing required params for LST transfer");
            }
            return ethers.solidityPacked(
                ["bytes32", "uint256", "bytes32"],
                [rightPadAddress(params.staker), BigInt(params.amount), rightPadAddress(params.token)]
            );

        case Action.REQUEST_DEPOSIT_NST:
            if (!params.staker || !params.validatorID) {
                throw new Error("Missing required params for NST deposit");
            }
            // validatorID can be variable length, so we encode it as bytes
            const validatorIDBytes = ethers.getBytes(params.validatorID);
            return ethers.solidityPacked(
                ["bytes32", "uint256", "bytes"],
                [rightPadAddress(params.staker), BigInt(params.amount), validatorIDBytes]
            );

        case Action.REQUEST_WITHDRAW_NST:
            if (!params.staker) {
                throw new Error("Missing required params for NST withdraw");
            }
            return ethers.solidityPacked(
                ["bytes32", "uint256"],
                [rightPadAddress(params.staker), BigInt(params.amount)]
            );

        case Action.REQUEST_SUBMIT_REWARD:
        case Action.REQUEST_CLAIM_REWARD:
            if (!params.token || !params.avsOrWithdrawer) {
                throw new Error("Missing required params for reward operation");
            }
            return ethers.solidityPacked(
                ["bytes32", "bytes32", "uint256"],
                [rightPadAddress(params.token), rightPadAddress(params.avsOrWithdrawer), BigInt(params.amount)]
            );

        case Action.REQUEST_DELEGATE_TO:
            if (!params.staker || !params.token || !params.operator) {
                throw new Error("Missing required params for delegate");
            }
            // Operator is a bech32 string, convert to bytes
            return ethers.solidityPacked(
                ["bytes32", "uint256", "bytes32", "bytes"],
                [rightPadAddress(params.staker), BigInt(params.amount), rightPadAddress(params.token), ethers.toUtf8Bytes(params.operator)]
            );

        case Action.REQUEST_UNDELEGATE_FROM:
            if (!params.staker || !params.token || !params.operator) {
                throw new Error("Missing required params for undelegate");
            }
            const instantUnbondByte = params.instantUnbond ? "0x01" : "0x00";
            return ethers.solidityPacked(
                ["bytes32", "uint256", "bytes32", "bytes", "uint8"],
                [rightPadAddress(params.staker), BigInt(params.amount), rightPadAddress(params.token), ethers.toUtf8Bytes(params.operator), instantUnbondByte]
            );

        case Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO:
            if (!params.depositor || !params.token || !params.operator) {
                throw new Error("Missing required params for deposit and delegate");
            }
            return ethers.solidityPacked(
                ["bytes32", "uint256", "bytes32", "bytes"],
                [rightPadAddress(params.depositor), BigInt(params.amount), rightPadAddress(params.token), ethers.toUtf8Bytes(params.operator)]
            );

        case Action.REQUEST_ASSOCIATE_OPERATOR:
            if (!params.staker || !params.operator) {
                throw new Error("Missing required params for associate operator");
            }
            return ethers.solidityPacked(
                ["bytes32", "bytes"],
                [rightPadAddress(params.staker), ethers.toUtf8Bytes(params.operator)]
            );

        case Action.REQUEST_DISSOCIATE_OPERATOR:
            if (!params.staker) {
                throw new Error("Missing required params for dissociate operator");
            }
            return ethers.solidityPacked(
                ["bytes32"],
                [rightPadAddress(params.staker)]
            );

        default:
            throw new Error(`Unsupported action: ${action}`);
    }
}

async function measureGasDetail(
    gateway: any,
    endpoint: any,
    action: Action,
    params: {
        staker?: string;
        depositor?: string;
        amount?: number;
        token?: string;
        operator?: string;
        validatorID?: string;
        avsOrWithdrawer?: string;
        instantUnbond?: boolean;
    },
    nonce: number
): Promise<GasBoundResult> {
    const payload = buildPayload(action, params as any);
    const message = ethers.solidityPacked(["uint8", "bytes"], [action, payload]);

    const origin = {
        srcEid: SRC_CHAIN_ID,
        sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32),
        nonce: BigInt(nonce + 1)
    };

    // Use NonShortCircuitEndpointV2Mock's lzReceive signature
    // Signature: lzReceive(Origin calldata _origin, address _receiver, bytes32 _guid, bytes calldata _message, bytes calldata)
    const tx = await endpoint.lzReceive(
        origin,
        gateway.target,
        ethers.ZeroHash,
        message,
        "0x",
        { gasLimit: 6000000, value: 0 }
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
        action: Action[action],
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

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Using deployer:", deployer.address);

    // Use a fixed private key for the operator (for testing consistency)
    const operatorPrivateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const operatorWallet = new ethers.Wallet(operatorPrivateKey);
    console.log(`Using fixed operator private key (address: ${operatorWallet.address})`);

    // 0. Deploy NonShortCircuitEndpointV2Mock
    console.log("\n0. Deploying NonShortCircuitEndpointV2Mock...");
    const NonShortCircuitEndpointV2Mock = await ethers.getContractFactory("NonShortCircuitEndpointV2Mock");
    const endpointMock = await NonShortCircuitEndpointV2Mock.deploy(SRC_CHAIN_ID, deployer.address);
    await endpointMock.waitForDeployment();
    console.log("NonShortCircuitEndpointV2Mock deployed to:", endpointMock.target);

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

    // Set up endpoint lookup for NonShortCircuitEndpointV2Mock
    // The endpoint looks up lzEndpointLookup[receiver.bytes32ToAddress()]
    // where receiver is the peer (bytes32) converted to address
    // So we need to map the peer address (SRC_SENDER_ADDRESS) to the endpoint address
    await endpointMock.setDestLzEndpoint(SRC_SENDER_ADDRESS, endpointMock.target);
    console.log("Endpoint lookup configured: peer", SRC_SENDER_ADDRESS, "-> endpoint", endpointMock.target);

    // 3. Register Operator (SDK)
    const operatorAddr = await registerOperatorViaSDK(operatorPrivateKey, deployer);

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
    
    const verifyClient = new ImuachainClient({
        rpcEndpoint: COSMOS_RPC_URL,
        chainId: "imuachainlocalnet_232-1",
        prefix: 'im',
    });
    
    try {
        await verifyClient.initQueryClient();
        await verifyOperatorRegistration(verifyClient, operatorAddr);
        console.log(`✅ Operator registration verified for address: ${operatorAddr}`);
    } catch (e: any) {
        await verifyClient.disconnect();
        console.error("❌ Operator registration verification failed:", e.message);
        throw e;
    }
    
    await verifyClient.disconnect();

    // 4.5 Fund Gateway for Withdrawal Response Fees
    console.log("\n4.5 Funding gateway for withdrawal response fees...");
    try {
        // Calculate estimated funds needed:
        // - REQUEST_WITHDRAW_LST: ~100 messages * estimated fee per response
        // - REQUEST_WITHDRAW_NST: ~100 messages * estimated fee per response
        // Using a generous estimate of 0.01 IMUA per response message
        const estimatedMessagesPerType = 100;
        const estimatedFeePerResponse = ethers.parseEther("0.01"); // 0.01 IMUA per response
        const totalWithdrawalMessages = estimatedMessagesPerType * 2; // LST + NST withdrawals
        const totalEstimatedFees = estimatedFeePerResponse * BigInt(totalWithdrawalMessages);
        const buffer = ethers.parseEther("1.0"); // Add 1 IMUA buffer for safety
        const fundingAmount = totalEstimatedFees + buffer;
        
        console.log(`Estimated funding needed: ${ethers.formatEther(fundingAmount)} IMUA`);
        console.log(`  - Withdrawal messages: ${totalWithdrawalMessages}`);
        console.log(`  - Estimated fee per response: ${ethers.formatEther(estimatedFeePerResponse)} IMUA`);
        console.log(`  - Buffer: ${ethers.formatEther(buffer)} IMUA`);
        
        const gatewayBalance = await ethers.provider.getBalance(gateway.target);
        console.log(`Current gateway balance: ${ethers.formatEther(gatewayBalance)} IMUA`);
        
        if (gatewayBalance < fundingAmount) {
            const needed = fundingAmount - gatewayBalance;
            console.log(`Funding gateway with ${ethers.formatEther(needed)} IMUA...`);
            const fundTx = await deployer.sendTransaction({
                to: gateway.target,
                value: needed
            });
            await fundTx.wait();
            console.log("✅ Gateway funded successfully");
        } else {
            console.log("✅ Gateway already has sufficient balance");
        }
        
        const finalBalance = await ethers.provider.getBalance(gateway.target);
        console.log(`Final gateway balance: ${ethers.formatEther(finalBalance)} IMUA`);
    } catch (e: any) {
        console.error("❌ Failed to fund gateway:", e.message);
        throw e;
    }

    // 5. Verify each message type works (1 message per type) before full testing
    console.log("\n5. Verifying each message type (1 message per type)...");
    const VERIFY_MESSAGES_PER_TYPE = 1;
    
    // Track stakers and their on-chain operations
    interface StakerOperations {
        address: string;
        hasDepositedLST: boolean;
        hasDepositedNST: boolean;
        hasAssociatedOperator: boolean;
        hasDelegated: boolean;
        hasUndelegated: boolean;
        validatorID?: string;
    }
    const stakers: StakerOperations[] = [];

    // Helper to create a new staker
    function createStaker(): StakerOperations {
        return {
            address: ethers.Wallet.createRandom().address,
            hasDepositedLST: false,
            hasDepositedNST: false,
            hasAssociatedOperator: false,
            hasDelegated: false,
            hasUndelegated: false
        };
    }

    // Test configurations with prerequisites
    // Each config includes prerequisite actions that must be executed on-chain first
    const testConfigs = [
        {
            action: Action.REQUEST_DEPOSIT_LST,
            name: "Deposit LST",
            prerequisites: [] as Action[],
            params: async (i: number, nonce: number) => {
                const staker = createStaker();
                stakers.push(staker);
                staker.hasDepositedLST = true;
                return {
                    params: {
                        staker: staker.address,
                        amount: 1000, // Deposit enough for future operations
                        token: TOKEN_ADDR
                    },
                    prerequisitesNonces: 0
                };
            }
        },
        {
            action: Action.REQUEST_DEPOSIT_NST,
            name: "Deposit NST",
            prerequisites: [] as Action[],
            params: async (i: number, nonce: number) => {
                const staker = createStaker();
                const validatorID = ethers.hexlify(ethers.randomBytes(32));
                staker.validatorID = validatorID;
                stakers.push(staker);
                staker.hasDepositedNST = true;
                return {
                    params: {
                        staker: staker.address,
                        amount: 1000,
                        validatorID
                    },
                    prerequisitesNonces: 0
                };
            }
        },
        {
            action: Action.REQUEST_ASSOCIATE_OPERATOR,
            name: "Associate Operator",
            prerequisites: [] as Action[],
            params: async (i: number, nonce: number) => {
                const staker = createStaker();
                stakers.push(staker);
                staker.hasAssociatedOperator = true;
                return {
                    params: {
                        staker: staker.address,
                        operator: operatorAddr,
                        amount: 0 // Not used but required by type
                    },
                    prerequisitesNonces: 0
                };
            }
        },
        {
            action: Action.REQUEST_DELEGATE_TO,
            name: "Delegate To",
            prerequisites: [Action.REQUEST_DEPOSIT_LST] as Action[],
            params: async (i: number, nonce: number) => {
                // Find a staker that has deposited LST but not yet delegated
                let staker = stakers.find(s => s.hasDepositedLST && !s.hasDelegated);
                
                if (!staker) {
                    // Create a new staker and execute prerequisite on-chain
                    staker = createStaker();
                    stakers.push(staker);
                    
                    // Execute prerequisite: Deposit LST
                    const depositParams = {
                        staker: staker.address,
                        amount: 1000,
                        token: TOKEN_ADDR
                    };
                    const depositPayload = buildPayload(Action.REQUEST_DEPOSIT_LST, depositParams);
                    const depositMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DEPOSIT_LST, depositPayload]);
                    const depositOrigin = {
                        srcEid: SRC_CHAIN_ID,
                        sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32),
                        nonce: BigInt(nonce)
                    };
                    
                    // Execute prerequisite on-chain (but don't measure gas for it)
                    const depositTx = await endpointMock.lzReceive(
                        depositOrigin,
                        gateway.target,
                        ethers.ZeroHash,
                        depositMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await depositTx.wait(); // Wait for transaction to be included
                    
                    staker.hasDepositedLST = true;
                    return {
                        params: {
                            staker: staker.address,
                            amount: 500, // Delegate 50% of deposited amount
                            token: TOKEN_ADDR,
                            operator: operatorAddr
                        },
                        prerequisitesNonces: 1 // One prerequisite was executed
                    };
                }
                
                staker.hasDelegated = true;
                return {
                    params: {
                        staker: staker.address,
                        amount: 500, // Delegate 50% of deposited amount
                        token: TOKEN_ADDR,
                        operator: operatorAddr
                    },
                    prerequisitesNonces: 0 // Prerequisites already met
                };
            }
        },
        {
            action: Action.REQUEST_DEPOSIT_THEN_DELEGATE_TO,
            name: "Deposit Then Delegate",
            prerequisites: [] as Action[], // This action handles both deposit and delegate
            params: async (i: number, nonce: number) => {
                const staker = createStaker();
                stakers.push(staker);
                staker.hasDepositedLST = true;
                staker.hasDelegated = true;
                return {
                    params: {
                        depositor: staker.address,
                        amount: 500,
                        token: TOKEN_ADDR,
                        operator: operatorAddr
                    },
                    prerequisitesNonces: 0
                };
            }
        },
        {
            action: Action.REQUEST_UNDELEGATE_FROM,
            name: "Undelegate From",
            prerequisites: [Action.REQUEST_DEPOSIT_LST, Action.REQUEST_DELEGATE_TO] as Action[],
            params: async (i: number, nonce: number) => {
                // Find a staker that has delegated
                let staker = stakers.find(s => s.hasDelegated && !s.hasUndelegated);
                
                if (!staker) {
                    // Create a new staker and execute prerequisites on-chain
                    staker = createStaker();
                    stakers.push(staker);
                    
                    // Execute prerequisite 1: Deposit LST
                    const depositParams = {
                        staker: staker.address,
                        amount: 1000,
                        token: TOKEN_ADDR
                    };
                    const depositPayload = buildPayload(Action.REQUEST_DEPOSIT_LST, depositParams);
                    const depositMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DEPOSIT_LST, depositPayload]);
                    const depositOrigin = {
                        srcEid: SRC_CHAIN_ID,
                        sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32),
                        nonce: BigInt(nonce)
                    };
                    const depositTx = await endpointMock.lzReceive(
                        depositOrigin,
                        gateway.target,
                        ethers.ZeroHash,
                        depositMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await depositTx.wait();
                    staker.hasDepositedLST = true;
                    
                    // Execute prerequisite 2: Delegate
                    const delegateParams = {
                        staker: staker.address,
                        amount: 500,
                        token: TOKEN_ADDR,
                        operator: operatorAddr
                    };
                    const delegatePayload = buildPayload(Action.REQUEST_DELEGATE_TO, delegateParams);
                    const delegateMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DELEGATE_TO, delegatePayload]);
                    const delegateOrigin = {
                        srcEid: SRC_CHAIN_ID,
                        sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32),
                        nonce: BigInt(nonce + 1)
                    };
                    const delegateTx = await endpointMock.lzReceive(
                        delegateOrigin,
                        gateway.target,
                        ethers.ZeroHash,
                        delegateMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await delegateTx.wait();
                    staker.hasDelegated = true;
                    return {
                        params: {
                            staker: staker.address,
                            amount: 250, // Undelegate 50% of delegated amount
                            token: TOKEN_ADDR,
                            operator: operatorAddr,
                            instantUnbond: false
                        },
                        prerequisitesNonces: 2 // Two prerequisites were executed
                    };
                }
                
                staker.hasUndelegated = true;
                return {
                    params: {
                        staker: staker.address,
                        amount: 250, // Undelegate 50% of delegated amount
                        token: TOKEN_ADDR,
                        operator: operatorAddr,
                        instantUnbond: false
                    },
                    prerequisitesNonces: 0 // Prerequisites already met
                };
            }
        },
        {
            action: Action.REQUEST_WITHDRAW_LST,
            name: "Withdraw LST",
            prerequisites: [Action.REQUEST_DEPOSIT_LST, Action.REQUEST_DELEGATE_TO, Action.REQUEST_UNDELEGATE_FROM] as Action[],
            params: async (i: number, nonce: number) => {
                // Find a staker that has deposited, delegated, and undelegated (has unlocked balance)
                let staker = stakers.find(s => s.hasDepositedLST && s.hasDelegated && s.hasUndelegated);
                
                if (!staker) {
                    // Create a new staker and execute prerequisites on-chain
                    staker = createStaker();
                    stakers.push(staker);
                    
                    // Execute all prerequisites in sequence
                    let currentNonce = nonce;
                    
                    // 1. Deposit LST
                    const depositParams = {
                        staker: staker.address,
                        amount: 1000,
                        token: TOKEN_ADDR
                    };
                    const depositPayload = buildPayload(Action.REQUEST_DEPOSIT_LST, depositParams);
                    const depositMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DEPOSIT_LST, depositPayload]);
                    const depositTx1 = await endpointMock.lzReceive(
                        { srcEid: SRC_CHAIN_ID, sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32), nonce: BigInt(currentNonce) },
                        gateway.target,
                        ethers.ZeroHash,
                        depositMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await depositTx1.wait();
                    staker.hasDepositedLST = true;
                    currentNonce++;
                    
                    // 2. Delegate
                    const delegateParams = {
                        staker: staker.address,
                        amount: 500,
                        token: TOKEN_ADDR,
                        operator: operatorAddr
                    };
                    const delegatePayload = buildPayload(Action.REQUEST_DELEGATE_TO, delegateParams);
                    const delegateMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DELEGATE_TO, delegatePayload]);
                    const delegateTx1 = await endpointMock.lzReceive(
                        { srcEid: SRC_CHAIN_ID, sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32), nonce: BigInt(currentNonce) },
                        gateway.target,
                        ethers.ZeroHash,
                        delegateMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await delegateTx1.wait();
                    staker.hasDelegated = true;
                    currentNonce++;
                    
                    // 3. Undelegate (creates unlocked balance)
                    const undelegateParams = {
                        staker: staker.address,
                        amount: 250,
                        token: TOKEN_ADDR,
                        operator: operatorAddr,
                        instantUnbond: false
                    };
                    const undelegatePayload = buildPayload(Action.REQUEST_UNDELEGATE_FROM, undelegateParams);
                    const undelegateMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_UNDELEGATE_FROM, undelegatePayload]);
                    const undelegateTx1 = await endpointMock.lzReceive(
                        { srcEid: SRC_CHAIN_ID, sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32), nonce: BigInt(currentNonce) },
                        gateway.target,
                        ethers.ZeroHash,
                        undelegateMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await undelegateTx1.wait();
                    staker.hasUndelegated = true;
                    return {
                        params: {
                            staker: staker.address,
                            amount: 200, // Withdraw some unlocked balance
                            token: TOKEN_ADDR
                        },
                        prerequisitesNonces: 3 // Three prerequisites were executed
                    };
                }
                
                return {
                    params: {
                        staker: staker.address,
                        amount: 200, // Withdraw some unlocked balance
                        token: TOKEN_ADDR
                    },
                    prerequisitesNonces: 0 // Prerequisites already met
                };
            }
        },
        {
            action: Action.REQUEST_WITHDRAW_NST,
            name: "Withdraw NST",
            prerequisites: [Action.REQUEST_DEPOSIT_NST] as Action[],
            params: async (i: number, nonce: number) => {
                // Find a staker that has deposited NST (NST doesn't need delegation for withdrawal)
                let staker = stakers.find(s => s.hasDepositedNST);
                
                if (!staker) {
                    // Create a new staker and execute prerequisite on-chain
                    staker = createStaker();
                    const validatorID = ethers.hexlify(ethers.randomBytes(32));
                    staker.validatorID = validatorID;
                    stakers.push(staker);
                    
                    // Execute prerequisite: Deposit NST
                    const depositParams = {
                        staker: staker.address,
                        amount: 1000,
                        validatorID
                    };
                    const depositPayload = buildPayload(Action.REQUEST_DEPOSIT_NST, depositParams);
                    const depositMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_DEPOSIT_NST, depositPayload]);
                    const depositTx2 = await endpointMock.lzReceive(
                        { srcEid: SRC_CHAIN_ID, sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32), nonce: BigInt(nonce) },
                        gateway.target,
                        ethers.ZeroHash,
                        depositMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await depositTx2.wait();
                    staker.hasDepositedNST = true;
                return {
                    params: {
                        staker: staker.address,
                        amount: 500
                    },
                    prerequisitesNonces: 1 // One prerequisite was executed
                };
            }
            
            return {
                params: {
                    staker: staker.address,
                    amount: 500
                },
                prerequisitesNonces: 0 // Prerequisites already met
            };
            }
        },
        {
            action: Action.REQUEST_DISSOCIATE_OPERATOR,
            name: "Dissociate Operator",
            prerequisites: [Action.REQUEST_ASSOCIATE_OPERATOR] as Action[],
            params: async (i: number, nonce: number) => {
                // Find a staker that has associated operator
                let staker = stakers.find(s => s.hasAssociatedOperator);
                
                if (!staker) {
                    // Create a new staker and execute prerequisite on-chain
                    staker = createStaker();
                    stakers.push(staker);
                    
                    // Execute prerequisite: Associate Operator
                    const associateParams = {
                        staker: staker.address,
                        operator: operatorAddr,
                        amount: 0
                    };
                    const associatePayload = buildPayload(Action.REQUEST_ASSOCIATE_OPERATOR, associateParams);
                    const associateMessage = ethers.solidityPacked(["uint8", "bytes"], [Action.REQUEST_ASSOCIATE_OPERATOR, associatePayload]);
                    const associateTx = await endpointMock.lzReceive(
                        { srcEid: SRC_CHAIN_ID, sender: ethers.zeroPadValue(SRC_SENDER_ADDRESS, 32), nonce: BigInt(nonce) },
                        gateway.target,
                        ethers.ZeroHash,
                        associateMessage,
                        "0x",
                        { gasLimit: 6000000, value: 0 }
                    );
                    await associateTx.wait();
                    staker.hasAssociatedOperator = true;
                    return {
                        params: {
                            staker: staker.address,
                            amount: 0 // Not used but required by type
                        },
                        prerequisitesNonces: 1 // One prerequisite was executed
                    };
                }
                
                return {
                    params: {
                        staker: staker.address,
                        amount: 0 // Not used but required by type
                    },
                    prerequisitesNonces: 0 // Prerequisites already met
                };
            }
        }
    ];

    // First, verify each message type with 1 message
    console.log("\n=== Verification Phase ===");
    let verifyNonce = 0;
    for (const config of testConfigs) {
        console.log(`\nVerifying ${config.name}...`);
        if (config.prerequisites.length > 0) {
            console.log(`  Prerequisites: ${config.prerequisites.map(a => Action[a]).join(", ")}`);
        }
        
        try {
            const paramsResult = await config.params(0, verifyNonce);
            const params = paramsResult.params;
            const prerequisitesNonces = paramsResult.prerequisitesNonces || 0;
            verifyNonce += prerequisitesNonces;
            
            const result = await measureGasDetail(
                gateway,
                endpointMock,
                config.action,
                params,
                verifyNonce
            );
            verifyNonce++;
            console.log(`  ✅ ${config.name} verified successfully (Gas: ${result.gasUsed})`);
        } catch (e: any) {
            console.error(`  ❌ ${config.name} verification failed: ${e.message}`);
            throw new Error(`Verification failed for ${config.name}: ${e.message}`);
        }
    }
    console.log("\n✅ All message types verified successfully!\n");

    // 6. Full test run
    console.log("=== Full Test Phase ===");
    const MESSAGES_PER_TYPE = 100;
    const results: GasBoundResult[] = [];
    
    let globalNonce = verifyNonce; // Continue from verification nonce
    for (const config of testConfigs) {
        console.log(`\nTesting ${config.name} (${MESSAGES_PER_TYPE} messages)...`);
        if (config.prerequisites.length > 0) {
            console.log(`  Prerequisites: ${config.prerequisites.map(a => Action[a]).join(", ")}`);
        }
        
        for (let i = 0; i < MESSAGES_PER_TYPE; i++) {
            try {
                // Get params which may execute prerequisites on-chain
                // The params function returns both the params and the number of nonces consumed by prerequisites
                const paramsResult = await config.params(i, globalNonce);
                const params = paramsResult.params;
                const prerequisitesNonces = paramsResult.prerequisitesNonces || 0;
                
                // Update nonce to account for prerequisite operations
                globalNonce += prerequisitesNonces;
                
                const result = await measureGasDetail(
                    gateway,
                    endpointMock,
                    config.action,
                    params,
                    globalNonce
                );
                results.push(result);
                globalNonce++;
                
                if ((i + 1) % 10 === 0) {
                    console.log(`  Progress: ${i + 1}/${MESSAGES_PER_TYPE} | Last Gas: ${result.gasUsed} | Last txHash: ${result.txHash}`);
                }
            } catch (e: any) {
                console.error(`  Error at message ${i + 1}: ${e.message}`);
                throw e;
            }
        }
    }

    // 7. Statistics and CSV output
    console.log("\n=== Overall Statistics ===");
    console.log(`Total Messages: ${results.length}`);
    
    const gasUsages = results.map(r => r.gasUsed);
    const maxGas = Math.max(...gasUsages);
    const minGas = Math.min(...gasUsages);
    const avgGas = gasUsages.reduce((sum, g) => sum + g, 0) / gasUsages.length;
    
    console.log(`Max Gas: ${maxGas.toLocaleString()}`);
    console.log(`Min Gas: ${minGas.toLocaleString()}`);
    console.log(`Avg Gas: ${Math.round(avgGas).toLocaleString()}`);

    // Statistics per action type
    console.log("\n=== Statistics Per Action Type ===");
    const actionStats = new Map<string, { count: number; totalGas: number; minGas: number; maxGas: number }>();
    
    for (const result of results) {
        const stats = actionStats.get(result.action) || { count: 0, totalGas: 0, minGas: Infinity, maxGas: 0 };
        stats.count++;
        stats.totalGas += result.gasUsed;
        stats.minGas = Math.min(stats.minGas, result.gasUsed);
        stats.maxGas = Math.max(stats.maxGas, result.gasUsed);
        actionStats.set(result.action, stats);
    }
    
    for (const [action, stats] of actionStats.entries()) {
        const avg = stats.totalGas / stats.count;
        console.log(`${action}:`);
        console.log(`  Count: ${stats.count}`);
        console.log(`  Avg Gas: ${Math.round(avg).toLocaleString()}`);
        console.log(`  Min Gas: ${stats.minGas.toLocaleString()}`);
        console.log(`  Max Gas: ${stats.maxGas.toLocaleString()}`);
    }

    // 8. Save to CSV
    const csvPath = path.join(process.cwd(), "gas-bound-results.csv");
    const csvHeader = "action,nonce,txHash,gasUsed\n";
    const csvRows = results.map(r => `${r.action},${r.nonce},${r.txHash},${r.gasUsed}`).join("\n");
    fs.writeFileSync(csvPath, csvHeader + csvRows);
    console.log(`\nResults saved to ${csvPath}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
