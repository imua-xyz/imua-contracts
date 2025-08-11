import { Client } from "xrpl";
import { decodeAccountID } from "ripple-address-codec";
import fs from "fs";
import path from "path";
import { ethers } from "ethers";
import { fromBech32 } from "@cosmjs/encoding";
import config from "./config";
import bootstrapAbi from "../../out/Bootstrap.sol/Bootstrap.json";
import { XRP_CONFIG, XRP_CHAIN_CONFIG } from "./config";
import {
  GenesisState,
  AppState,
  AssetsState,
  DelegationState,
  DogfoodState,
  Validator,
  OracleState,
  ClientChain,
  Token,
} from "./types";

interface BootstrapStake {
  hash: string; // XRP transaction hash
  ledgerIndex: number; // Ledger sequence number
  transactionIndex: number; // Transaction index in ledger
  xrpAddress: string; // Staker's XRP address (hex format)
  imuachainAddress: string; // Corresponding Imuachain address
  validatorAddress: string; // Target validator address
  amount: number; // Stake amount in drops (1 XRP = 1,000,000 drops)
  timestamp: number; // Transaction timestamp
}

interface ParsedMemoData {
  imuachainAddress: string;
  validatorAddress: string;
}

interface XRPMemo {
  MemoType?: string;
  MemoData?: string;
  MemoFormat?: string;
}

interface XRPTransaction {
  hash: string;
  ledger_index: number;
  date: number;
  validated: boolean;
  tx: {
    TransactionType: string;
    Account: string; // Sender address
    Destination?: string; // Destination address (for Payment)
    Amount:
      | string
      | {
          // Amount (string for XRP, object for tokens)
          currency: string;
          value: string;
          issuer: string;
        };
    Fee: string; // Transaction fee in drops
    Sequence: number; // Account sequence number
    Memos?: Array<{
      // Memo field for validator info
      Memo: XRPMemo;
    }>;
    DestinationTag?: number; // Optional destination tag
  };
  meta: {
    TransactionResult: string;
    TransactionIndex: number;
    delivered_amount?: string;
  };
}

/**
 * XRP Genesis Generator Class
 * Uses XRPL client to fetch transaction data from XRP network and generate genesis state
 */
export class XRPGenesisGenerator {
  private readonly vaultAddress: string;
  private readonly client: Client;
  private readonly minConfirmations: number;
  private readonly minAmount: number; // in drops (1 XRP = 1,000,000 drops)
  private readonly bootstrapContract: ethers.Contract;
  private addressMappings: Map<string, string> = new Map(); // xrp -> imuachain
  private validatorInfoCache: Map<string, any> = new Map(); // validator address -> validator info

  constructor(
    vaultAddress: string,
    rpcUrl: string,
    bootstrapContract: ethers.Contract,
    minConfirmations: number = 6,
    minAmount: number = 50000000 // 50 XRP minimum
  ) {
    this.vaultAddress = vaultAddress;
    this.client = new Client(rpcUrl);
    this.bootstrapContract = bootstrapContract;
    this.minConfirmations = minConfirmations;
    this.minAmount = minAmount;

    // Validate configuration
    if (!this.vaultAddress) {
      throw new Error("Vault address is required");
    }
    if (!rpcUrl) {
      throw new Error("XRP RPC URL is required");
    }
    if (this.minConfirmations < 1) {
      throw new Error("Minimum confirmations must be at least 1");
    }
  }

  /**
   * Get current ledger index from XRPL
   */
  private async getCurrentLedgerIndex(): Promise<number> {
    try {
      if (!this.client.isConnected()) {
        await this.client.connect();
      }

      const ledgerResponse = await this.client.request({
        command: "ledger",
        ledger_index: "validated",
        binary: false,
        api_version: 2,
      });

      if (!ledgerResponse?.result?.ledger?.ledger_index) {
        throw new Error("Invalid response format from WebSocket");
      }

      const ledgerIndex = ledgerResponse.result.ledger.ledger_index;
      return typeof ledgerIndex === "number"
        ? ledgerIndex
        : parseInt(ledgerIndex, 10);
    } catch (error: any) {
      throw new Error(`Failed to retrieve XRP ledger index: ${error.message}`);
    }
  }

  /**
   * Get transaction details by hash
   */
  private async getTransactionDetails(
    hash: string
  ): Promise<XRPTransaction | null> {
    try {
      if (!this.client.isConnected()) {
        await this.client.connect();
      }

      const response = await this.client.request({
        command: "tx",
        transaction: hash,
        binary: false,
        api_version: 2,
      });

      if (response?.result && response.result.validated) {
        const result = response.result as any;
        return {
          hash: result.hash || "",
          ledger_index: result.ledger_index || 0,
          date: result.date || -1,
          tx: {
            TransactionType: result.TransactionType,
            Account: result.Account,
            Destination: result.Destination,
            Amount: result.Amount,
            Fee: result.Fee,
            Sequence: result.Sequence,
            Memos: result.Memos,
            DestinationTag: result.DestinationTag,
          },
          meta: {
            TransactionResult: result.meta?.TransactionResult || "tesSUCCESS",
            TransactionIndex: result.meta?.TransactionIndex || 0,
            delivered_amount: result.meta?.delivered_amount,
          },
          validated: result.validated || false,
        };
      }
      return null;
    } catch (error: any) {
      console.error(`Error getting transaction details for ${hash}:`, error);
      return null;
    }
  }

  /**
   * Get all transactions for the vault address
   */
  private async getVaultTransactions(): Promise<XRPTransaction[]> {
    const allTxs: XRPTransaction[] = [];
    let marker: any = undefined;

    try {
      if (!this.client.isConnected()) {
        await this.client.connect();
      }

      while (true) {
        const requestParams: any = {
          command: "account_tx",
          account: this.vaultAddress,
          ledger_index_min: -1,
          ledger_index_max: -1,
          binary: false,
          limit: 200,
          api_version: 2,
        };

        if (marker) {
          requestParams.marker = marker;
        }

        const response = await this.client.request(requestParams);
        const result = response?.result as any;

        if (!result || !result.transactions) {
          break;
        }

        // Process transactions to match our interface
        for (const txData of result.transactions) {
          const tx_json = txData.tx_json || txData.tx;
          if (!tx_json || !txData.validated) {
            continue;
          }

          const tx: XRPTransaction = {
            hash: txData.hash,
            ledger_index: txData.ledger_index,
            date: tx_json.date || -1,
            tx: {
              TransactionType: tx_json.TransactionType,
              Account: tx_json.Account,
              Destination: tx_json.Destination,
              Amount: tx_json.DeliverMax || tx_json.Amount,
              Fee: tx_json.Fee,
              Sequence: tx_json.Sequence,
              Memos: tx_json.Memos,
              DestinationTag: tx_json.DestinationTag,
            },
            meta: {
              TransactionResult: txData.meta?.TransactionResult || "tesSUCCESS",
              TransactionIndex: txData.meta?.TransactionIndex || 0,
              delivered_amount: txData.meta?.delivered_amount,
            },
            validated: txData.validated,
          };

          if (tx.tx.TransactionType === "Payment") {
            allTxs.push(tx);
          }
        }

        // Check if there are more transactions
        if (!result.marker) {
          break;
        }
        marker = result.marker;
      }
    } catch (error) {
      console.error("Error fetching vault transactions:", error);
      throw error;
    }

    return allTxs;
  }

  /**
   * Check if validator is registered in the bootstrap contract
   */
  private async isValidatorRegistered(validatorAddr: string): Promise<boolean> {
    try {
      // Check if we already have cached info for this validator
      if (!this.validatorInfoCache.has(validatorAddr)) {
        const validatorInfo = await this.bootstrapContract.validators(
          validatorAddr
        );
        this.validatorInfoCache.set(validatorAddr, validatorInfo);
      }

      const validatorInfo = this.validatorInfoCache.get(validatorAddr);
      return (
        validatorInfo && validatorInfo.name && validatorInfo.name.length > 0
      );
    } catch (error: any) {
      if (
        error.code === "ECONNREFUSED" ||
        error.message.includes("JsonRpcProvider")
      ) {
        console.warn(
          `⚠️ RPC connection failed for validator ${validatorAddr}, assuming not registered`
        );
        return false; // Assume not registered when RPC is unavailable
      }
      console.error(
        `Error checking validator registration for ${validatorAddr}:`,
        error
      );
      return false;
    }
  }

  /**
   * Validate validator address format (bech32 with 'im' prefix)
   */
  private isValidValidatorAddress(address: string): boolean {
    try {
      const { prefix, data } = fromBech32(address);
      return prefix === "im" && data.length === 20;
    } catch {
      return false;
    }
  }

  /**
   * Convert XRP address to hex format for storage
   */
  private xrpAddressToHex(xrpAddress: string): string {
    try {
      const accountId = decodeAccountID(xrpAddress);
      return "0x" + Buffer.from(accountId).toString("hex");
    } catch (error) {
      console.error(
        `Error converting XRP address ${xrpAddress} to hex:`,
        error
      );
      throw error;
    }
  }

  /**
   * Validate memo format before parsing
   * @param memos Array of memo objects to validate
   * @returns true if memos have valid structure
   */
  private validateMemoFormat(memos: Array<{ Memo: XRPMemo }>): boolean {
    return memos.every(
      ({ Memo }) =>
        Memo?.MemoType &&
        Memo?.MemoData &&
        typeof Memo.MemoType === "string" &&
        typeof Memo.MemoData === "string"
    );
  }

  /**
   * Parse and validate address data from memo buffer
   * @param buffer Buffer containing memo data
   * @returns ParsedMemoData object or null if invalid
   */
  private parseAddressesFromBuffer(buffer: Buffer): ParsedMemoData | null {
    // Validate minimum length (41 bytes validator + 20 bytes ethereum address)
    if (buffer.length < 61) {
      console.log(
        `Memo data too short: ${buffer.length} bytes, expected at least 61`
      );
      return null;
    }

    try {
      // Extract last 41 bytes as validator address
      const validatorBytes = buffer.subarray(-41);
      const validatorAddress = validatorBytes.toString("utf8");

      // Validate validator address (must be 41 characters bech32 format)
      if (
        !this.isValidValidatorAddress(validatorAddress) ||
        validatorAddress.length !== 41
      ) {
        console.log(`Invalid validator address format: ${validatorAddress}`);
        return null;
      }

      // Extract remaining bytes as ethereum address
      const ethBytes = buffer.subarray(0, -41);

      if (ethBytes.length === 40) {
        // 40 bytes UTF8 encoded hex string
        const ethAddressString = ethBytes.toString("utf8");

        // Validate hex format
        if (!/^[0-9a-fA-F]{40}$/.test(ethAddressString)) {
          console.log(`Invalid hex format for address: ${ethAddressString}`);
          return null;
        }

        const imuachainAddressHex = "0x" + ethAddressString;

        // Validate ethereum address format
        if (!ethers.isAddress(imuachainAddressHex)) {
          console.log(
            `Invalid imuachain address format: ${imuachainAddressHex}`
          );
          return null;
        }

        return {
          imuachainAddress: imuachainAddressHex,
          validatorAddress: validatorAddress,
        };
      } else {
        console.log(
          `Invalid ethereum address length: ${ethBytes.length}, expected: 40 bytes`
        );
        return null;
      }
    } catch (error) {
      console.log(
        `Failed to parse address data: ${
          error instanceof Error ? error.message : "Unknown error"
        }`
      );
      return null;
    }
  }

  /**
   * Parse memo data to extract imuachain and validator addresses
   * Validates MemoType must be "Description" (hex: 4465736372697074696F6E)
   * Format: memoData is binary data with last 41 bytes as validator address
   */
  private parseMemoData(
    memos: Array<{ Memo: XRPMemo }>
  ): ParsedMemoData | null {
    // Validate memo format first
    if (!this.validateMemoFormat(memos)) {
      console.log("Invalid memo format detected");
      return null;
    }

    try {
      for (const memo of memos) {
        // Validate MemoType is "Description" (hex: 4465736372697074696F6E)
        if (memo.Memo.MemoType !== "4465736372697074696F6E") {
          console.log(
            `Invalid MemoType: ${memo.Memo.MemoType}, expected: 4465736372697074696F6E`
          );
          continue;
        }

        const buffer = Buffer.from(memo.Memo.MemoData!, "hex");
        const result = this.parseAddressesFromBuffer(buffer);

        if (result) {
          return result;
        }
      }

      console.log("No valid memo data found in transaction");
      return null;
    } catch (error) {
      console.error(
        `Error parsing memo data: ${
          error instanceof Error ? error.message : "Unknown error"
        }`
      );
      return null;
    }
  }

  /**
   * Validate if transaction is a valid bootstrap stake
   * Implements the same validation rules as monitor.xrp.ts
   */
  private async isValidBootstrapTransaction(
    tx: XRPTransaction
  ): Promise<boolean> {
    // Must be validated
    if (!tx.validated) {
      console.log(`Transaction ${tx.hash} is not validated`);
      return false;
    }

    // Must be a Payment transaction
    if (tx.tx.TransactionType !== "Payment") {
      console.log(
        `Invalid transaction type in tx ${tx.hash}: ${tx.tx.TransactionType}`
      );
      return false;
    }

    // Must be successful
    if (tx.meta.TransactionResult !== "tesSUCCESS") {
      console.log(
        `Transaction ${tx.hash} failed with result: ${tx.meta.TransactionResult}`
      );
      return false;
    }

    // Must be sent to our vault address
    if (tx.tx.Destination !== this.vaultAddress) {
      console.log(`Invalid destination in tx ${tx.hash}: ${tx.tx.Destination}`);
      return false;
    }

    // Must not be from vault address (no self-transfers)
    if (tx.tx.Account === this.vaultAddress) {
      console.log(`Self-transfer detected in tx ${tx.hash}`);
      return false;
    }

    // Check DestinationTag (must be 9999)
    if (tx.tx.DestinationTag !== 9999) {
      console.log(
        `Invalid DestinationTag in tx ${tx.hash}: ${tx.tx.DestinationTag}`
      );
      return false;
    }

    // Must be XRP payment (not token)
    if (typeof tx.tx.Amount !== "string") {
      console.log(`Non-XRP payment in tx ${tx.hash}`);
      return false;
    }

    // Check the minimum amount
    const amount = parseInt(tx.tx.Amount);
    if (amount < this.minAmount) {
      console.log(
        `Amount ${amount} below minimum ${this.minAmount} in tx ${tx.hash}`
      );
      return false;
    }

    // Must have memo with validator info
    if (!tx.tx.Memos || tx.tx.Memos.length === 0) {
      console.log(`No memos found in tx ${tx.hash}`);
      return false;
    }

    // Parse and validate memo data
    const memoData = this.parseMemoData(tx.tx.Memos);
    if (!memoData) {
      console.log(`Invalid memo format in tx ${tx.hash}`);
      return false;
    }

    // Check if the validator is registered
    const isRegistered = await this.isValidatorRegistered(
      memoData.validatorAddress
    );
    if (!isRegistered) {
      console.log(
        `Validator ${memoData.validatorAddress} not registered in tx ${tx.hash}`
      );
      // return false;
    }

    // Check address mapping consistency
    const senderAddress = tx.tx.Account;
    if (this.addressMappings.has(senderAddress)) {
      const existingImuachainAddress = this.addressMappings.get(senderAddress);
      if (existingImuachainAddress !== memoData.imuachainAddress) {
        console.log(
          `Inconsistent imuachain address for XRP address ${senderAddress} in tx ${tx.hash}\n  Previous: ${existingImuachainAddress}, Current: ${memoData.imuachainAddress}`
        );
        return false;
      }
    }

    // Store the mapping for later use
    this.addressMappings.set(senderAddress, memoData.imuachainAddress);

    return true;
  }

  /**
   * Generate bootstrap stakes from XRP transactions
   */
  public async generateGenesisStakes(): Promise<BootstrapStake[]> {
    const transactions = await this.getVaultTransactions();
    const currentLedgerIndex = await this.getCurrentLedgerIndex();
    console.log(
      `Fetching transactions for vault address ${this.vaultAddress}... Found ${transactions.length} transactions. Current ledger index: ${currentLedgerIndex}`
    );

    // Filter and validate transactions
    const validTxs = await Promise.all(
      transactions.map(async (tx) => ({
        tx,
        isValid: await this.isValidBootstrapTransaction(tx),
      }))
    );

    const filteredTxs = validTxs
      .filter(
        ({ tx, isValid }) =>
          isValid &&
          tx.ledger_index <= currentLedgerIndex &&
          currentLedgerIndex - tx.ledger_index + 1 >= this.minConfirmations
      )
      .map(({ tx }) => tx)
      .sort((a, b) => {
        // Sort by ledger index first, then by transaction index
        if (a.ledger_index !== b.ledger_index) {
          return a.ledger_index - b.ledger_index;
        }
        return a.meta.TransactionIndex - b.meta.TransactionIndex;
      });

    console.log(
      `Found ${filteredTxs.length} valid transactions with ${this.minConfirmations}+ confirmations.`
    );

    // Convert to BootstrapStake objects
    const stakes: BootstrapStake[] = [];
    for (const tx of filteredTxs) {
      const memoData = this.parseMemoData(tx.tx.Memos!);
      if (!memoData) continue;

      const amount = parseInt(tx.tx.Amount as string);

      stakes.push({
        hash: tx.hash,
        ledgerIndex: tx.ledger_index,
        transactionIndex: tx.meta.TransactionIndex,
        xrpAddress: this.xrpAddressToHex(tx.tx.Account),
        imuachainAddress: memoData.imuachainAddress,
        validatorAddress: memoData.validatorAddress,
        amount: amount,
        timestamp: tx.date,
      });
    }

    // Disconnect client when done
    if (this.client.isConnected()) {
      await this.client.disconnect();
    }

    return stakes;
  }

  // Get cached validator info (public method for use in genesis generation)
  public getValidatorInfo(validatorAddr: string): any {
    return this.validatorInfoCache.get(validatorAddr);
  }
}

/**
 * Generate genesis state from XRP bootstrap stakes
 */
export async function generateXRPGenesisState(
  stakes: BootstrapStake[],
  generator?: XRPGenesisGenerator
): Promise<GenesisState> {
  // Calculate total staked amount
  const totalStaked = stakes.reduce((sum, stake) => sum + stake.amount, 0);

  // Current timestamp
  const genesisTime = new Date().toISOString();

  // Asset ID for XRP
  const xrpAssetId =
    XRP_CONFIG.VIRTUAL_ADDRESS.toLowerCase() +
    "_0x" +
    XRP_CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

  // Group stakes by validator
  const validatorStakes = new Map<string, BootstrapStake[]>();
  stakes.forEach((stake) => {
    if (!validatorStakes.has(stake.validatorAddress)) {
      validatorStakes.set(stake.validatorAddress, []);
    }
    validatorStakes.get(stake.validatorAddress)!.push(stake);
  });

  // Create XRP client chain
  const xrpChain: ClientChain = {
    name: XRP_CHAIN_CONFIG.NAME,
    meta_info: XRP_CHAIN_CONFIG.META_INFO,
    finalization_blocks: XRP_CHAIN_CONFIG.FINALIZATION_BLOCKS,
    layer_zero_chain_id: XRP_CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID,
    address_length: XRP_CHAIN_CONFIG.ADDRESS_LENGTH,
  };

  // Create XRP token
  const xrpToken: Token = {
    asset_basic_info: {
      name: XRP_CONFIG.NAME,
      symbol: XRP_CONFIG.SYMBOL,
      address: XRP_CONFIG.VIRTUAL_ADDRESS.toLowerCase(),
      decimals: XRP_CONFIG.DECIMALS.toString(),
      layer_zero_chain_id: XRP_CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID,
      imua_chain_index: "0",
      meta_info: XRP_CONFIG.META_INFO,
    },
    staking_total_amount: totalStaked.toString(),
  };

  // Group deposits by staker_id
  const depositsByStaker = new Map<string, Map<string, number>>();

  for (const stake of stakes) {
    const stakerId =
      stake.xrpAddress +
      "_0x" +
      XRP_CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

    if (!depositsByStaker.has(stakerId)) {
      depositsByStaker.set(stakerId, new Map<string, number>());
    }

    const stakerDeposits = depositsByStaker.get(stakerId)!;
    const currentAmount = stakerDeposits.get(xrpAssetId) || 0;
    stakerDeposits.set(xrpAssetId, currentAmount + stake.amount);
  }

  // Generate deposits array
  const deposits = Array.from(depositsByStaker.entries()).map(
    ([stakerId, assetMap]) => ({
      staker: stakerId,
      deposits: Array.from(assetMap.entries()).map(([assetId, amount]) => ({
        asset_id: assetId,
        info: {
          total_deposit_amount: amount.toString(),
          withdrawable_amount: "0", // All stakes must be delegated
          pending_undelegation_amount: "0",
        },
      })),
    })
  );

  // Generate assets state
  const assetsState: AssetsState = {
    params: {
      gateways: [
        "0x0000000000000000000000000000000000000902", // XRP Gateway address
      ],
    },
    client_chains: [xrpChain],
    tokens: [xrpToken],
    deposits: deposits,
    operator_assets: [],
  };

  // Generate operator assets
  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalAmount = validatorStakeList.reduce(
      (sum, stake) => sum + stake.amount,
      0
    );

    assetsState.operator_assets.push({
      operator: validator,
      assets_state: [
        {
          asset_id: xrpAssetId,
          info: {
            total_amount: totalAmount.toString(),
            pending_undelegation_amount: "0",
            total_share: totalAmount.toString(),
            operator_share: "0", // Operators don't have their own stake in bootstrap
          },
        },
      ],
    });
  }

  // Generate delegation state
  const delegationState: DelegationState = {
    associations: [], // No associations for XRP
    delegation_states: [],
    stakers_by_operator: [],
  };

  // Map to collect stakers by operator
  const stakersByOperator = new Map<string, Set<string>>();

  for (const stake of stakes) {
    const stakerId =
      stake.xrpAddress +
      "_0x" +
      XRP_CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

    // Add delegation state
    const key = `${stakerId}/${xrpAssetId}/${stake.validatorAddress}`;
    delegationState.delegation_states.push({
      key: key,
      states: {
        undelegatable_share: stake.amount.toString(),
        wait_undelegation_amount: "0",
      },
    });

    // Collect stakers by operator
    const mapKey = `${stake.validatorAddress}/${xrpAssetId}`;
    if (!stakersByOperator.has(mapKey)) {
      stakersByOperator.set(mapKey, new Set());
    }
    stakersByOperator.get(mapKey)!.add(stakerId);
  }

  // Convert stakers by operator map to array
  for (const [key, stakers] of stakersByOperator.entries()) {
    delegationState.stakers_by_operator.push({
      key: key,
      stakers: Array.from(stakers),
    });
  }

  // Sort arrays for deterministic output
  delegationState.delegation_states.sort((a, b) => a.key.localeCompare(b.key));
  delegationState.stakers_by_operator.sort((a, b) =>
    a.key.localeCompare(b.key)
  );

  // Calculate validator power based on stake and XRP price
  let validators: Validator[] = [];
  let totalPower = 0;

  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalStake = validatorStakeList.reduce(
      (sum, stake) => sum + stake.amount,
      0
    );
    // Convert XRP drops to XRP (1 XRP = 1,000,000 drops)
    const xrpAmount = totalStake / 1000000;
    // Convert XRP to USD value and then to power units(USD value is the power)
    const usdValue = xrpAmount * config.xrpPriceUsd;
    const power = Math.floor(usdValue);

    // Get cached validator info to retrieve consensus public key
    let publicKey = validator; // fallback to validator address
    if (generator) {
      const validatorInfo = generator.getValidatorInfo(validator);
      if (validatorInfo && validatorInfo.consensusPublicKey) {
        publicKey = validatorInfo.consensusPublicKey;
      } else {
        console.warn(
          `No consensus public key found for validator ${validator}, using validator address`
        );
      }
    }

    validators.push({
      power: power.toString(),
      public_key: publicKey,
    });

    totalPower += power;
  }

  // Sort validators by power (descending)
  validators.sort((a, b) => {
    const powerA = BigInt(a.power);
    const powerB = BigInt(b.power);
    if (powerA === powerB) {
      return a.public_key.localeCompare(b.public_key);
    }
    return powerB > powerA ? 1 : -1;
  });

  // Limit to max validators
  validators = validators.slice(0, config.maxValidators);

  // Recalculate total power after limiting validators
  totalPower = validators.reduce(
    (sum, validator) => sum + parseInt(validator.power),
    0
  );

  // Generate dogfood state
  const dogfoodState: DogfoodState = {
    params: {
      asset_ids: [xrpAssetId],
      max_validators: config.maxValidators,
    },
    val_set: validators,
    last_total_power: totalPower.toString(),
  };

  // Generate oracle state
  const oracleTokenId = "5"; // XRP token ID in oracle system
  const currentXrpPriceWithDecimals = Math.floor(
    config.xrpPriceUsd * Math.pow(10, 8)
  ).toString(); // Convert to price with 8 decimals

  const oracleState: OracleState = {
    params: {
      tokens: [
        {
          name: XRP_CONFIG.SYMBOL,
          chain_id: XRP_CONFIG.CHAIN_ID,
          contract_address: XRP_CONFIG.VIRTUAL_ADDRESS.toLowerCase(),
          active: true,
          asset_id: xrpAssetId,
          decimal: XRP_CONFIG.DECIMALS,
        },
      ],
      token_feeders: [
        {
          token_id: oracleTokenId,
          start_round_id: "1",
          start_base_block: "20", // Start from genesis block
          interval: "30", // 30 blocks interval for price updates
          end_block: "0", // 0 means no end block (perpetual)
          rule_id: "2", // Rule ID for XRP price feed
        },
      ],
    },
    prices_list: [
      {
        next_round_id: "1",
        price_list: [
          {
            decimal: 8,
            price: currentXrpPriceWithDecimals,
            round_id: "0", // Genesis price round
          },
        ],
        token_id: oracleTokenId,
      },
    ],
  };

  // Combine all states into app state
  const appState: AppState = {
    assets: assetsState,
    delegation: delegationState,
    dogfood: dogfoodState,
    oracle: oracleState,
  };

  // Construct the full genesis state
  const genesisState: GenesisState = {
    genesis_time: genesisTime,
    chain_id: "imua-1",
    initial_height: "1",
    consensus_params: {
      block: {
        max_bytes: "22020096",
        max_gas: "-1",
      },
      evidence: {
        max_age_num_blocks: "100000",
        max_age_duration: "172800000000000",
        max_bytes: "1048576",
      },
      validator: {
        pub_key_types: ["ed25519"],
      },
      version: {
        app: "0",
      },
    },
    app_hash: "",
    app_state: appState,
  };

  return genesisState;
}

/**
 * Main function to generate XRP bootstrap genesis
 */
export async function generateXRPBootstrapGenesis(): Promise<void> {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const bootstrapContract = new ethers.Contract(
    config.bootstrapContractAddress,
    bootstrapAbi.abi,
    provider
  );

  const generator = new XRPGenesisGenerator(
    config.xrpVaultAddress,
    config.xrpRpcUrl, // XRP Ledger RPC endpoint
    bootstrapContract,
    config.minConfirmations,
    config.minAmount // in drops
  );

  const stakes = await generator.generateGenesisStakes();
  const genesisState = await generateXRPGenesisState(stakes, generator);

  const outputPath =
    process.env.XRP_GENESIS_OUTPUT_PATH || config.genesisOutputPath;
  const resolvedPath = path.isAbsolute(outputPath)
    ? outputPath
    : path.resolve(outputPath);

  // Ensure directory exists
  const dir = path.dirname(resolvedPath);
  await fs.promises.mkdir(dir, { recursive: true });

  await fs.promises.writeFile(
    resolvedPath,
    JSON.stringify(genesisState, null, 2)
  );

  console.log(
    `Generated XRP genesis state with ${stakes.length} valid stakes - Written to ${resolvedPath}`
  );
}
