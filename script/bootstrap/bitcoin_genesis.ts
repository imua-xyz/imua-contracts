import axios from 'axios';
import fs from 'fs';
import { ethers } from 'ethers';
import { fromBech32, fromHex, toBech32 } from '@cosmjs/encoding';
import {address, networks} from 'bitcoinjs-lib';
import config from './config';
import bootstrapAbi from '../../out/Bootstrap.sol/Bootstrap.json';
import { BTC_CONFIG, CHAIN_CONFIG } from './config';
import { 
  GenesisState, AppState, AssetsState, DelegationState, 
  DogfoodState, Validator, OracleState, ClientChain, Token
} from './types';
import { toVersionAndHash } from './utils';

interface BootstrapStake {
  txid: string;
  blockHeight: number;
  txIndex: number;
  bitcoinAddress: string;
  imuachainAddress: string;
  validatorAddress: string;
  amount: number;
  timestamp: number;
}

interface BTCTransaction {
  txid: string;
  vin: Array<{
    prevout: {
      scriptpubkey_address: string;
    };
  }>;
  vout: Array<{
    scriptpubkey: string;
    scriptpubkey_type: string;
    scriptpubkey_address?: string;
    value: number;
  }>;
  status: {
    confirmed: boolean;
    block_height: number;
    block_time: number;
    txIndex?: number;
  };
}

export class GenesisGenerator {
  private readonly vaultAddress: string;
  private readonly baseUrl: string;
  private readonly minConfirmations: number;
  private readonly minAmount: number; // in satoshis
  private readonly bootstrapContract: ethers.Contract;
  private addressMappings: Map<string, string> = new Map(); // bitcoin -> imuachain

  constructor(
    vaultAddress: string,
    baseUrl: string,
    bootstrapContract: ethers.Contract,
    minConfirmations: number = 6,
    minAmount: number = 1000000
  ) {
    this.vaultAddress = vaultAddress;
    this.baseUrl = baseUrl;
    this.bootstrapContract = bootstrapContract;
    this.minConfirmations = minConfirmations;
    this.minAmount = minAmount;
  }

  private async getTxIndexInBlock(txid: string): Promise<number> {
    try {
      const txResponse = await axios.get(`${this.baseUrl}/api/tx/${txid}`);
      const blockHash = txResponse.data.status.block_hash;
      
      const blockResponse = await axios.get(`${this.baseUrl}/api/block/${blockHash}/txids`);
      const txids = blockResponse.data;
      
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

  private async getBlockHeight(): Promise<number> {
    try {
      const response = await axios.get(`${this.baseUrl}/api/blocks/tip/height`);
      return response.data;
    } catch (error) {
      console.error('Error getting block height:', error);
      throw error;
    }
  }

  private async getConfirmedTransactions(): Promise<BTCTransaction[]> {
    let allTxs: BTCTransaction[] = [];
    let lastSeenTxId: string | undefined;

    while (true) {
      const url = lastSeenTxId
        ? `${this.baseUrl}/api/address/${this.vaultAddress}/txs/chain/${lastSeenTxId}`
        : `${this.baseUrl}/api/address/${this.vaultAddress}/txs`;

      try {
        const response = await axios.get(url);
        const txs = response.data as BTCTransaction[];

        if (txs.length === 0) break;

        const confirmedTxs = txs.filter(tx => tx.status.confirmed);
        for (const tx of confirmedTxs) {
          tx.status.txIndex = await this.getTxIndexInBlock(tx.txid);
          allTxs.push(tx);
        }

        lastSeenTxId = txs[txs.length - 1].txid;
      } catch (error) {
        console.error('Error fetching transactions:', error);
        throw error;
      }
    }

    return allTxs;
  }

  private async isValidatorRegistered(validatorAddr: string): Promise<boolean> {
    try {
      const validatorInfo = await this.bootstrapContract.validators(validatorAddr);
      return validatorInfo && validatorInfo.name && validatorInfo.name.length > 0;
    } catch (error) {
      console.error(`Error checking validator registration for ${validatorAddr}:`, error);
      return false;
    }
  }

  private isValidValidatorAddress(address: string): boolean {
    try {
      const { prefix, data } = fromBech32(address);
      return prefix === 'im' && data.length === 20;
    } catch {
      return false;
    }
  }

  private async isValidBootstrapTransaction(tx: BTCTransaction): Promise<boolean> {
    // Skip if not confirmed
    if (!tx.status.confirmed || !tx.status.block_height) {
      return false;
    }

    // Check if it's from vault (should not be)
    const isFromVault = tx.vin.some(
      (input) => input.prevout.scriptpubkey_address === this.vaultAddress
    );
    if (isFromVault) {
      return false;
    }

    // Check vault output
    const vaultOutputs = tx.vout.filter(
      (output) => output.scriptpubkey_address === this.vaultAddress && 
                  output.value >= this.minAmount
    );
    if (vaultOutputs.length !== 1) {
      console.log(`Invalid number of vault outputs in tx ${tx.txid}`);
      return false;
    }

    // Check OP_RETURN output
    const opReturnOutputs = tx.vout.filter(
      (output) => output.scriptpubkey_type === "op_return"
    );
    if (opReturnOutputs.length !== 1) {
      console.log(`Invalid number of OP_RETURN outputs in tx ${tx.txid}`);
      return false;
    }

    const opReturnOutput = opReturnOutputs[0];
    // Validate OP_RETURN format
    // Format: 6a3d{20 bytes imuachain}{41 bytes validator}
    const scriptPubKey = opReturnOutput.scriptpubkey;
    if (!scriptPubKey.startsWith('6a3d')) {
      console.log(`Invalid OP_RETURN prefix in tx ${tx.txid}`);
      return false;
    }

    const hexOpReturnData = scriptPubKey.slice(4);
    if (hexOpReturnData.length !== 122) { // 20 bytes + 41 bytes = 122 hex chars
      console.log(`Invalid OP_RETURN data length in tx ${tx.txid}`);
      return false;
    }

    // Extract imuachain and validator addresses
    const imuachainAddressHex = '0x' + hexOpReturnData.slice(0, 40);
    const validatorAddressHex = hexOpReturnData.slice(40);
    
    // Convert validator hex to bech32
    let validatorAddress = '';
    try {
      // Convert hex to bytes
      const bytes = Buffer.from(validatorAddressHex, 'hex');
      // Convert bytes to string
      validatorAddress = new TextDecoder().decode(bytes);
      
      // Validate the validator address format
      if (!this.isValidValidatorAddress(validatorAddress)) {
        console.log(`Invalid validator address format in tx ${tx.txid}`);
        return false;
      }
    } catch (error) {
      console.error(`Error converting validator address in tx ${tx.txid}:`, error);
      return false;
    }

    // Check if validator is registered
    const isRegistered = await this.isValidatorRegistered(validatorAddress);
    if (!isRegistered) {
      console.log(`Validator ${validatorAddress} not registered in tx ${tx.txid}`);
      return false;
    }

    // Check address mapping consistency
    const senderAddress = tx.vin[0].prevout.scriptpubkey_address;
    if (this.addressMappings.has(senderAddress)) {
      const existingImuachainAddress = this.addressMappings.get(senderAddress);
      if (existingImuachainAddress !== imuachainAddressHex) {
        console.log(`Inconsistent imuachain address for Bitcoin address ${senderAddress} in tx ${tx.txid}`);
        console.log(`Previous: ${existingImuachainAddress}, Current: ${imuachainAddressHex}`);
        return false;
      }
    }

    // Store the mapping for later use
    this.addressMappings.set(senderAddress, imuachainAddressHex);

    return true;
  }

  public async generateGenesisStakes(): Promise<BootstrapStake[]> {
    console.log(`Fetching transactions for vault address ${this.vaultAddress}...`);
    const transactions = await this.getConfirmedTransactions();
    console.log(`Found ${transactions.length} transactions.`);

    const currentHeight = await this.getBlockHeight();
    console.log(`Current block height: ${currentHeight}`);

    // Filter and sort transactions
    const validTxs = await Promise.all(
      transactions.map(async tx => ({
        tx,
        isValid: await this.isValidBootstrapTransaction(tx)
      }))
    );

    const filteredTxs = validTxs
      .filter(({ tx, isValid }) => 
        isValid &&
        tx.status.block_height <= currentHeight &&
        (currentHeight - tx.status.block_height + 1) >= this.minConfirmations
      )
      .map(({ tx }) => tx)
      .sort((a, b) => {
        if (a.status.block_height !== b.status.block_height) {
          return a.status.block_height - b.status.block_height;
        }
        return (a.status.txIndex || 0) - (b.status.txIndex || 0);
      });

    console.log(`Found ${filteredTxs.length} valid transactions with ${this.minConfirmations}+ confirmations.`);

    // Convert to BootstrapStake objects
    const stakes: BootstrapStake[] = [];
    for (const tx of filteredTxs) {
      const vaultOutput = tx.vout.find(
        (output) => output.scriptpubkey_address === this.vaultAddress
      );
      
      const opReturnOutput = tx.vout.find(
        (output) => output.scriptpubkey_type === "op_return"
      );
      
      if (!vaultOutput || !opReturnOutput) continue;
      
      const hexOpReturnData = opReturnOutput.scriptpubkey.slice(4);
      const imuaAddressHex = '0x' + hexOpReturnData.slice(0, 40);
      const validatorAddressHex = hexOpReturnData.slice(40);
      
      // Convert validator hex to bech32
      const validatorAddress = toBech32('im', fromHex(validatorAddressHex));
      
      const {version, hash} = toVersionAndHash(
        tx.vin[0].prevout.scriptpubkey_address,
        networks.regtest,
      );
      console.log(`the underlying hash of address has length ${hash.length}`);
      
      stakes.push({
        txid: tx.txid,
        blockHeight: tx.status.block_height,
        txIndex: tx.status.txIndex || 0,
        bitcoinAddress: '0x' + Buffer.from(hash).toString('hex'),
        imuachainAddress: imuaAddressHex,
        validatorAddress: validatorAddress,
        amount: vaultOutput.value,
        timestamp: tx.status.block_time
      });
    }

    return stakes;
  }
}

export async function generateGenesisState(stakes: BootstrapStake[]): Promise<GenesisState> {
  // Calculate total staked amount
  const totalStaked = stakes.reduce((sum, stake) => sum + stake.amount, 0);
  
  // Current timestamp
  const genesisTime = new Date().toISOString();
  
  // Asset ID for BTC
  const btcAssetId = BTC_CONFIG.VIRTUAL_ADDRESS.toLowerCase() + '_0x' + 
                    CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);
  
  // Group stakes by validator
  const validatorStakes = new Map<string, BootstrapStake[]>();
  stakes.forEach(stake => {
    if (!validatorStakes.has(stake.validatorAddress)) {
      validatorStakes.set(stake.validatorAddress, []);
    }
    validatorStakes.get(stake.validatorAddress)!.push(stake);
  });
  
  // Create Bitcoin client chain
  const bitcoinChain: ClientChain = {
    name: CHAIN_CONFIG.NAME,
    meta_info: CHAIN_CONFIG.META_INFO,
    finalization_blocks: CHAIN_CONFIG.FINALIZATION_BLOCKS,
    layer_zero_chain_id: CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID,
    address_length: CHAIN_CONFIG.ADDRESS_LENGTH
  };
  
  // Create BTC token
  const btcToken: Token = {
    asset_basic_info: {
      name: BTC_CONFIG.NAME,
      symbol: BTC_CONFIG.SYMBOL,
      address: BTC_CONFIG.VIRTUAL_ADDRESS,
      decimals: BTC_CONFIG.DECIMALS.toString(),
      layer_zero_chain_id: CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID,
      imua_chain_index: "0",
      meta_info: BTC_CONFIG.META_INFO
    },
    staking_total_amount: totalStaked.toString()
  };
  
  // Group deposits by staker_id
  const depositsByStaker = new Map<string, Map<string, number>>();
  
  for (const stake of stakes) {
    const stakerId = stake.bitcoinAddress + '_0x' + CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);
    
    if (!depositsByStaker.has(stakerId)) {
      depositsByStaker.set(stakerId, new Map<string, number>());
    }
    
    const stakerDeposits = depositsByStaker.get(stakerId)!;
    const currentAmount = stakerDeposits.get(btcAssetId) || 0;
    stakerDeposits.set(btcAssetId, currentAmount + stake.amount);
  }
  
  // Generate deposits array
  const deposits = Array.from(depositsByStaker.entries()).map(([stakerId, assetMap]) => ({
    staker: stakerId,
    deposits: Array.from(assetMap.entries()).map(([assetId, amount]) => ({
      asset_id: assetId,
      info: {
        total_deposit_amount: amount.toString(),
        withdrawable_amount: "0", // All stakes must be delegated
        pending_undelegation_amount: "0"
      }
    }))
  }));
  
  // Generate assets state
  const assetsState: AssetsState = {
    params: {
      gateways: [
        "0x0000000000000000000000000000000000000901" // UTXO Gateway address
      ]
    },
    client_chains: [bitcoinChain],
    tokens: [btcToken],
    deposits: deposits,
    operator_assets: []
  };
  
  // Generate operator assets
  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalAmount = validatorStakeList.reduce((sum, stake) => sum + stake.amount, 0);
    
    assetsState.operator_assets.push({
      operator: validator,
      assets_state: [{
        asset_id: btcAssetId,
        info: {
          total_amount: totalAmount.toString(),
          pending_undelegation_amount: "0",
          total_share: totalAmount.toString(),
          operator_share: "0" // Operators don't have their own stake in bootstrap
        }
      }]
    });
  }
  
  // Generate delegation state - skip associations as they don't exist for Bitcoin
  const delegationState: DelegationState = {
    associations: [], // No associations for Bitcoin
    delegation_states: [],
    stakers_by_operator: []
  };
  
  // Map to collect stakers by operator
  const stakersByOperator = new Map<string, Set<string>>();
  
  for (const stake of stakes) {
    const stakerId = stake.bitcoinAddress + '_0x' + CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);
    
    // Add delegation state
    const key = `${stakerId}/${btcAssetId}/${stake.validatorAddress}`;
    delegationState.delegation_states.push({
      key: key,
      states: {
        undelegatable_share: stake.amount.toString(),
        wait_undelegation_amount: "0"
      }
    });
    
    // Collect stakers by operator
    const mapKey = `${stake.validatorAddress}/${btcAssetId}`;
    if (!stakersByOperator.has(mapKey)) {
      stakersByOperator.set(mapKey, new Set());
    }
    stakersByOperator.get(mapKey)!.add(stakerId);
  }
  
  // Convert stakers by operator map to array
  for (const [key, stakers] of stakersByOperator.entries()) {
    delegationState.stakers_by_operator.push({
      key: key,
      stakers: Array.from(stakers)
    });
  }
  
  // Sort arrays for deterministic output
  delegationState.delegation_states.sort((a, b) => a.key.localeCompare(b.key));
  delegationState.stakers_by_operator.sort((a, b) => a.key.localeCompare(b.key));
  
  // Calculate validator power based on stake and BTC price
  let validators: Validator[] = [];
  let totalPower = 0;
  
  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalStake = validatorStakeList.reduce((sum, stake) => sum + stake.amount, 0);
    // Convert BTC to USD value and then to power units
    const usdValue = totalStake * config.btcPriceUsd;
    // Convert to integer power (e.g., 1 USD = 1000000 power units)
    const power = Math.floor(usdValue * 1000000);
    
    validators.push({
      public_key: validator,
      power: power.toString()
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
  totalPower = validators.reduce((sum, validator) => sum + parseInt(validator.power), 0);
  
  // Generate dogfood state
  const dogfoodState: DogfoodState = {
    params: {
      asset_ids: [btcAssetId],
      max_validators: config.maxValidators
    },
    val_set: validators,
    last_total_power: totalPower.toString()
  };
  
  // Generate oracle state
  const oracleState: OracleState = {
    params: {
      tokens: [{
        name: BTC_CONFIG.SYMBOL,
        chain_id: BTC_CONFIG.CHAIN_ID,
        contract_address: BTC_CONFIG.VIRTUAL_ADDRESS,
        active: true,
        asset_id: btcAssetId,
        decimal: BTC_CONFIG.DECIMALS
      }]
    },
    staker_list_assets: [{
      asset_id: btcAssetId,
      staker_list: {
        staker_addrs: stakes.map(stake => stake.bitcoinAddress)
      }
    }],
    staker_infos_assets: [{
      asset_id: btcAssetId,
      staker_infos: stakes.map((stake, index) => ({
        staker_addr: stake.bitcoinAddress,
        staker_index: index,
        validator_pubkey_list: [stake.validatorAddress],
        balance_list: [{
          round_id: 0,
          block: 0,
          index: 0,
          balance: stake.amount.toString(),
          change: "ACTION_DEPOSIT"
        }]
      }))
    }]
  };
  
  // Combine all states into app state
  const appState: AppState = {
    assets: assetsState,
    delegation: delegationState,
    dogfood: dogfoodState,
    oracle: oracleState
  };
  
  // Construct the full genesis state
  const genesisState: GenesisState = {
    genesis_time: genesisTime,
    chain_id: "imua-1",
    initial_height: "1",
    consensus_params: {
      block: {
        max_bytes: "22020096",
        max_gas: "-1"
      },
      evidence: {
        max_age_num_blocks: "100000",
        max_age_duration: "172800000000000",
        max_bytes: "1048576"
      },
      validator: {
        pub_key_types: [
          "ed25519"
        ]
      },
      version: {
        app: "0"
      }
    },
    app_hash: "",
    app_state: appState
  };

  return genesisState;
}

export async function generateBootstrapGenesis(): Promise<void> {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const bootstrapContract = new ethers.Contract(
    config.bootstrapContractAddress,
    bootstrapAbi.abi,
    provider
  );

  const generator = new GenesisGenerator(
    config.btcVaultAddress,
    config.btcEsploraBaseUrl,
    bootstrapContract,
    config.minConfirmations,
    config.minAmount
  );

  const stakes = await generator.generateGenesisStakes();
  const genesisState = await generateGenesisState(stakes);

  await fs.promises.writeFile(
    config.genesisOutputPath,
    JSON.stringify(genesisState, null, 2)
  );

  console.log(`Generated genesis state with ${stakes.length} valid stakes`);
  console.log(`Written to ${config.genesisOutputPath}`);
}
