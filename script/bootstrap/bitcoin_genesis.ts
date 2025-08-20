import axios from 'axios';
import fs from 'fs';
import path from 'path';
import { ethers } from 'ethers';
import { fromBech32, fromHex, toBech32 } from '@cosmjs/encoding';
import { address as addressUtils, networks } from 'bitcoinjs-lib';
import config from './config';
import bootstrapAbi from '../../out/Bootstrap.sol/Bootstrap.json';
import { BTC_CONFIG, CHAIN_CONFIG } from './config';
import {
  GenesisState,
  AppState,
  AssetsState,
  DelegationState,
  OperatorState,
  OperatorAssetUsdValue,
  DogfoodState,
  Validator,
  OracleState,
  ClientChain,
  Token,
  BootstrapEntry,
} from './types';
import { toVersionAndHash } from './utils';

export interface BootstrapStake {
  txid: string;
  blockHeight: number;
  txIndex: number;
  bitcoinAddress: string; // Bitcoin sender address (20 bytes hash)
  stakerAddress: string; // Imuachain address from OP_RETURN
  imuachainAddress: string;
  validatorAddress: string;
  amount: number;
  timestamp: number;
}


interface OpReturnData {
  imuachainAddressHex: string;
  validatorAddress: string;
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
  private reverseMappings: Map<string, string> = new Map(); // imuachain -> bitcoin (for bidirectional 1-1 binding)
  private validatorInfoCache: Map<string, any> = new Map(); // validator address -> validator info

  constructor(
    vaultAddress: string,
    baseUrl: string,
    bootstrapContract: ethers.Contract,
    minConfirmations: number = 6,
    minAmount: number = 1000000
  ) {
    this.vaultAddress = vaultAddress.toLowerCase();
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

        const confirmedTxs = txs.filter((tx) => tx.status.confirmed);
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
      // Check if we already have cached info for this validator
      if (!this.validatorInfoCache.has(validatorAddr)) {
        const validatorInfo = await this.bootstrapContract.validators(validatorAddr);
        this.validatorInfoCache.set(validatorAddr, validatorInfo);
      }

      const validatorInfo = this.validatorInfoCache.get(validatorAddr);
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

  /**
   * Parse and validate OP_RETURN data from Bitcoin transaction output
   * Format: 6a3d{20 bytes imuachain}{41 bytes validator}
   */
  private parseOpReturnData(scriptPubKey: string, txid?: string): OpReturnData | null {
    // Validate OP_RETURN format
    if (!scriptPubKey.startsWith('6a3d')) {
      if (txid) {
        console.log(`Invalid OP_RETURN prefix in tx ${txid}`);
      }
      return null;
    }

    const hexOpReturnData = scriptPubKey.slice(4);
    if (hexOpReturnData.length !== 122) {
      // 20 bytes + 41 bytes = 122 hex chars
      if (txid) {
        console.log(`Invalid OP_RETURN data length in tx ${txid}`);
      }
      return null;
    }

    // Extract imuachain and validator addresses
    const imuachainAddressHex = ('0x' + hexOpReturnData.slice(0, 40)).toLowerCase();
    const validatorAddressHex = hexOpReturnData.slice(40);

    try {
      // Convert validator hex to string
      const bytes = Buffer.from(validatorAddressHex, 'hex');
      const validatorAddress = new TextDecoder().decode(bytes);

      // Validate the validator address format
      if (!this.isValidValidatorAddress(validatorAddress)) {
        if (txid) {
          console.log(`Invalid validator address format in tx ${txid}: ${validatorAddress}`);
        }
        return null;
      }

      return {
        imuachainAddressHex,
        validatorAddress,
      };
    } catch (error) {
      if (txid) {
        console.error(`Error converting validator address in tx ${txid}:`, error);
      }
      return null;
    }
  }

  getNetworkFromAddress(address: string): networks.Network {
    return determineNetworkFromAddress(address);
  }

  private async isValidBootstrapTransaction(tx: BTCTransaction): Promise<boolean> {
    // Skip if not confirmed
    if (!tx.status.confirmed || !tx.status.block_height) {
      return false;
    }

    // Check if it's from vault (should not be)
    const isFromVault = tx.vin.some((input) => input.prevout.scriptpubkey_address.toLowerCase() === this.vaultAddress);
    if (isFromVault) {
      return false;
    }

    // Check vault output
    const vaultOutputs = tx.vout.filter(
      (output) => output.scriptpubkey_address?.toLowerCase() === this.vaultAddress && output.value >= this.minAmount
    );
    if (vaultOutputs.length !== 1) {
      console.log(`Invalid number of vault outputs in tx ${tx.txid}`);
      return false;
    }

    // Check OP_RETURN output
    const opReturnOutputs = tx.vout.filter((output) => output.scriptpubkey_type === 'op_return');
    if (opReturnOutputs.length !== 1) {
      console.log(`Invalid number of OP_RETURN outputs in tx ${tx.txid}`);
      return false;
    }

    const opReturnOutput = opReturnOutputs[0];

    // Parse and validate OP_RETURN data using the private method
    const opReturnData = this.parseOpReturnData(opReturnOutput.scriptpubkey, tx.txid);
    if (!opReturnData) {
      return false;
    }

    const { imuachainAddressHex, validatorAddress } = opReturnData;

    // Check if validator is registered
    const isRegistered = await this.isValidatorRegistered(validatorAddress);
    if (!isRegistered) {
      console.log(`Validator ${validatorAddress} not registered in tx ${tx.txid}`);
      return false;
    }

    // Check bidirectional address mapping consistency - Bitcoin address to imuachain address is 1-1 binding
    // Normalize Bitcoin address to lowercase for consistent comparison (imuachainAddressHex is already lowercase)
    const senderAddress = tx.vin[0].prevout.scriptpubkey_address.toLowerCase();

    // Check forward mapping: Bitcoin -> Imuachain
    if (this.addressMappings.has(senderAddress)) {
      const existingImuachainAddress = this.addressMappings.get(senderAddress);
      if (existingImuachainAddress !== imuachainAddressHex) {
        console.log(
          `Rejecting tx ${tx.txid}: Bitcoin address ${senderAddress} already bound to different imuachain address (${existingImuachainAddress} vs ${imuachainAddressHex})`
        );
        return false;
      }
      // Forward mapping already exists and is consistent
    }

    // Check reverse mapping: Imuachain -> Bitcoin
    if (this.reverseMappings.has(imuachainAddressHex)) {
      const existingBitcoinAddress = this.reverseMappings.get(imuachainAddressHex);
      if (existingBitcoinAddress !== senderAddress) {
        console.log(
          `Rejecting tx ${tx.txid}: Imuachain address ${imuachainAddressHex} already bound to different Bitcoin address (${existingBitcoinAddress} vs ${senderAddress})`
        );
        return false;
      }
      // Reverse mapping already exists and is consistent
    }

    // If no existing mappings or all mappings are consistent, establish new mappings if needed
    if (!this.addressMappings.has(senderAddress)) {
      this.addressMappings.set(senderAddress, imuachainAddressHex);
      this.reverseMappings.set(imuachainAddressHex, senderAddress);
      console.log(`Established new bidirectional address binding: ${senderAddress} <-> ${imuachainAddressHex} in tx ${tx.txid}`);
    }

    return true;
  }

  public async generateGenesisStakes(): Promise<BootstrapStake[]> {
    console.log(`Fetching transactions for vault address ${this.vaultAddress}...`);
    const transactions = await this.getConfirmedTransactions();

    const currentHeight = await this.getBlockHeight();
    console.log(`Found ${transactions.length} transactions, current block height: ${currentHeight}`);

    // Sort transactions first to ensure earliest transactions are processed first
    const sortedTxs = transactions.sort((a, b) => {
      if (a.status.block_height !== b.status.block_height) {
        return a.status.block_height - b.status.block_height;
      }
      return (a.status.txIndex || 0) - (b.status.txIndex || 0);
    });

    // Process transactions sequentially to preserve earliest address mappings
    const validTxs: { tx: BTCTransaction; isValid: boolean }[] = [];
    for (const tx of sortedTxs) {
      const isValid = await this.isValidBootstrapTransaction(tx);
      validTxs.push({ tx, isValid });
    }

    const filteredTxs = validTxs
      .filter(
        ({ tx, isValid }) =>
          isValid && tx.status.block_height <= currentHeight && currentHeight - tx.status.block_height + 1 >= this.minConfirmations
      )
      .map(({ tx }) => tx);

    console.log(`Found ${filteredTxs.length} valid transactions with ${this.minConfirmations}+ confirmations.`);

    // Convert to BootstrapStake objects
    const stakes: BootstrapStake[] = [];
    for (const tx of filteredTxs) {
      const vaultOutput = tx.vout.find((output) => output.scriptpubkey_address?.toLowerCase() === this.vaultAddress);

      const opReturnOutput = tx.vout.find((output) => output.scriptpubkey_type === 'op_return');

      if (!vaultOutput || !opReturnOutput) continue;

      // Parse OP_RETURN data to get validator address
      const opReturnData = this.parseOpReturnData(opReturnOutput.scriptpubkey);
      if (!opReturnData) continue;

      const { validatorAddress } = opReturnData;

      // Use the consistent imuachain address from our validated mapping
      // This ensures we use the first (earliest) imuachain address for each Bitcoin sender
      const senderAddress = tx.vin[0].prevout.scriptpubkey_address.toLowerCase();
      const consistentImuachainAddress = this.addressMappings.get(senderAddress);

      if (!consistentImuachainAddress) {
        console.error(`Error: No mapping found for Bitcoin address ${senderAddress} in tx ${tx.txid}`);
        continue;
      }

      const { version, hash } = toVersionAndHash(senderAddress, this.getNetworkFromAddress(senderAddress));
      console.log(`the underlying hash of address has length ${hash.length}`);

      stakes.push({
        txid: tx.txid,
        blockHeight: tx.status.block_height,
        txIndex: tx.status.txIndex || 0,
        bitcoinAddress: senderAddress, // Bitcoin sender address (normalized to lowercase)
        stakerAddress: consistentImuachainAddress, // Imuachain address from validated mapping (ensures 1-1 binding)
        imuachainAddress: consistentImuachainAddress,
        validatorAddress: validatorAddress,
        amount: vaultOutput.value,
        timestamp: tx.status.block_time,
      });
    }

    return stakes;
  }

  // Get cached validator info (public method for use in genesis generation)
  public getValidatorInfo(validatorAddr: string): any {
    return this.validatorInfoCache.get(validatorAddr);
  }
}

export async function generateGenesisState(stakes: BootstrapStake[], generator?: GenesisGenerator): Promise<GenesisState> {
  // Calculate total staked amount
  const totalStaked = stakes.reduce((sum, stake) => sum + stake.amount, 0);

  // Current timestamp
  const genesisTime = new Date().toISOString();

  // Asset ID for BTC
  const btcAssetId = BTC_CONFIG.VIRTUAL_ADDRESS.toLowerCase() + '_0x' + CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

  // Group stakes by validator
  const validatorStakes = new Map<string, BootstrapStake[]>();
  stakes.forEach((stake) => {
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
    address_length: CHAIN_CONFIG.ADDRESS_LENGTH,
  };

  // Create BTC token
  const btcToken: Token = {
    asset_basic_info: {
      name: BTC_CONFIG.NAME,
      symbol: BTC_CONFIG.SYMBOL,
      address: BTC_CONFIG.VIRTUAL_ADDRESS.toLowerCase(),
      decimals: BTC_CONFIG.DECIMALS.toString(),
      layer_zero_chain_id: CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID,
      imua_chain_index: '0',
      meta_info: BTC_CONFIG.META_INFO,
    },
    staking_total_amount: totalStaked.toString(),
  };

  // Group deposits by staker_id
  const depositsByStaker = new Map<string, Map<string, number>>();

  for (const stake of stakes) {
    const stakerId = stake.stakerAddress + '_0x' + CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

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
        withdrawable_amount: '0', // All stakes must be delegated
        pending_undelegation_amount: '0',
      },
    })),
  }));

  // Generate assets state
  const assetsState: AssetsState = {
    params: {
      gateways: [
        '0x0000000000000000000000000000000000000901', // UTXO Gateway address
      ],
    },
    client_chains: [bitcoinChain],
    tokens: [btcToken],
    deposits: deposits,
    operator_assets: [],
  };

  // Generate operator assets
  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalAmount = validatorStakeList.reduce((sum, stake) => sum + stake.amount, 0);

    assetsState.operator_assets.push({
      operator: validator,
      assets_state: [
        {
          asset_id: btcAssetId,
          info: {
            total_amount: totalAmount.toString(),
            pending_undelegation_amount: '0',
            total_share: totalAmount.toString(),
            operator_share: '0', // Operators don't have their own stake in bootstrap
          },
        },
      ],
    });
  }

  // Generate delegation state - skip associations as they don't exist for Bitcoin
  const delegationState: DelegationState = {
    associations: [], // No associations for Bitcoin
    delegation_states: [],
    stakers_by_operator: [],
  };

  // Map to collect stakers by operator
  const stakersByOperator = new Map<string, Set<string>>();

  for (const stake of stakes) {
    const stakerId = stake.stakerAddress + '_0x' + CHAIN_CONFIG.LAYER_ZERO_CHAIN_ID.toString(16);

    // Add delegation state
    const key = `${stakerId}/${btcAssetId}/${stake.validatorAddress}`;

    // Check if the key already exist, if exist, then add up the amount, otherwise create a new entry
    const existingState = delegationState.delegation_states.find((state) => state.key === key);
    if (existingState) {
      existingState.states.undelegatable_share = (BigInt(existingState.states.undelegatable_share) + BigInt(stake.amount)).toString();
    } else {
      // Create new delegation state entry
      delegationState.delegation_states.push({
        key: key,
        states: {
          undelegatable_share: stake.amount.toString(),
          wait_undelegation_amount: '0',
        },
      });
    }

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
      stakers: Array.from(stakers),
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
    // Calculate power: totalStake (Satoshi) * btcPriceUsd / 100000000 = USD value
    // USD value is the power, avoid precision loss by doing multiplication first
    const usdValueSatoshi = totalStake * config.btcPriceUsd; // USD value in Satoshi scale
    const power = Math.floor(usdValueSatoshi / 100000000); // Convert from Satoshi scale to BTC scale (USD)

    // Get cached validator info to retrieve consensus public key
    let publicKey = validator; // fallback to validator address
    if (generator) {
      const validatorInfo = generator.getValidatorInfo(validator);
      if (validatorInfo && validatorInfo.consensusPublicKey) {
        publicKey = validatorInfo.consensusPublicKey;
      } else {
        console.warn(`No consensus public key found for validator ${validator}, using validator address`);
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
  totalPower = validators.reduce((sum, validator) => sum + parseInt(validator.power), 0);

  // Generate operator state
  const operatorAssetUsdValues: OperatorAssetUsdValue[] = [];
  for (const [validator, validatorStakeList] of validatorStakes.entries()) {
    const totalStake = validatorStakeList.reduce((sum, stake) => sum + stake.amount, 0);
    // Calculate USD value: totalStake (Satoshi) * btcPriceUsd / 100000000 = USD value
    const usdValueSatoshi = totalStake * config.btcPriceUsd; // USD value in Satoshi scale
    const usdValue = Math.floor(usdValueSatoshi / 100000000); // Convert from Satoshi scale to BTC scale (USD)

    // epoch=day :epoch/validator/asset_id
    const key = `day/${validator}/${btcAssetId}`;
    operatorAssetUsdValues.push({
      key: key,
      value: {
        amount: usdValue.toString(),
      },
    });
  }

  const operatorState: OperatorState = {
    operator_asset_usd_values: operatorAssetUsdValues,
  };

  // Generate dogfood state
  const dogfoodState: DogfoodState = {
    params: {
      asset_ids: [btcAssetId],
      max_validators: config.maxValidators,
    },
    val_set: validators,
    last_total_power: totalPower.toString(),
  };

  // Generate oracle state
  const oracleTokenId = '4'; // BTC token ID in oracle system
  const currentBtcPriceWithDecimals = Math.floor(config.btcPriceUsd * Math.pow(10, BTC_CONFIG.DECIMALS)).toString(); // Convert to price with 8 decimals

  const oracleState: OracleState = {
    params: {
      chains: [
        {
          name: "Bitcoin",
          desc: "Bitcoin blockchain"
        }
      ],
      tokens: [
        {
          name: BTC_CONFIG.SYMBOL,
          chain_id: BTC_CONFIG.CHAIN_ID,
          contract_address: BTC_CONFIG.VIRTUAL_ADDRESS.toLowerCase(),
          active: true,
          asset_id: btcAssetId,
          decimal: BTC_CONFIG.DECIMALS,
        },
      ],
      token_feeders: [
        {
          token_id: oracleTokenId,
          start_round_id: '1',
          start_base_block: '20', // Start from genesis block
          interval: '30', // 30 blocks interval for price updates
          end_block: '0', // 0 means no end block (perpetual)
          rule_id: '2', // Rule ID for BTC price feed
        },
      ],
    },
    prices_list: [
      {
        next_round_id: '1',
        price_list: [
          {
            decimal: BTC_CONFIG.DECIMALS,
            price: currentBtcPriceWithDecimals,
            round_id: '0', // Genesis price round
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
    operator: operatorState,
    dogfood: dogfoodState,
    oracle: oracleState,
  };

  // Construct the full genesis state
  const genesisState: GenesisState = {
    genesis_time: genesisTime,
    chain_id: 'imua-1',
    initial_height: '1',
    consensus_params: {
      block: {
        max_bytes: '22020096',
        max_gas: '-1',
      },
      evidence: {
        max_age_num_blocks: '100000',
        max_age_duration: '172800000000000',
        max_bytes: '1048576',
      },
      validator: {
        pub_key_types: ['ed25519'],
      },
      version: {
        app: '0',
      },
    },
    app_hash: '',
    app_state: appState,
  };

  return genesisState;
}

// Utility function to determine network from Bitcoin address
function determineNetworkFromAddress(address: string): networks.Network {
  // Bech32 addresses (native segwit)
  if (address.startsWith('bc1')) {
    return networks.bitcoin; // Mainnet
  }
  if (address.startsWith('tb1')) {
    return networks.testnet; // Testnet
  }
  if (address.startsWith('bcrt1')) {
    return networks.regtest; // Regtest
  }

  // Legacy addresses (Base58Check)
  try {
    // Try to decode the address to get the version byte
    const decoded = addressUtils.fromBase58Check(address);

    // Check version bytes for different networks
    if (decoded.version === networks.bitcoin.pubKeyHash || decoded.version === networks.bitcoin.scriptHash) {
      return networks.bitcoin; // Mainnet
    }
    if (decoded.version === networks.testnet.pubKeyHash || decoded.version === networks.testnet.scriptHash) {
      return networks.testnet; // Testnet
    }
    if (decoded.version === networks.regtest.pubKeyHash || decoded.version === networks.regtest.scriptHash) {
      return networks.regtest; // Regtest
    }
  } catch (error) {
    // If decoding fails, try prefix-based detection as fallback
    console.warn(`Failed to decode address ${address}, using prefix-based detection`);
  }

  // Fallback prefix-based detection
  if (address.startsWith('1') || address.startsWith('3')) {
    return networks.bitcoin; // Mainnet P2PKH/P2SH
  }
  if (address.startsWith('m') || address.startsWith('n') || address.startsWith('2')) {
    return networks.testnet; // Testnet
  }
  if (address.startsWith('bcrt')) {
    return networks.regtest; // Regtest
  }

  // Default to mainnet
  console.warn(`Could not determine network for address ${address}, defaulting to mainnet`);
  return networks.bitcoin;
}

export async function exportBootstrapData(stakes: BootstrapStake[], resolvedGenesisPath?: string): Promise<void> {
  // Convert stakes to bootstrap entries
  const bootstrapData: BootstrapEntry[] = stakes.map((stake) => {
    // Convert Bitcoin address string to UTF-8 bytes for the contract
    const clientAddressBytes = ethers.hexlify(ethers.toUtf8Bytes(stake.bitcoinAddress));

    return {
      clientTxId: `0x${stake.txid}`, // Ensure 0x prefix
      clientAddress: clientAddressBytes, // Bitcoin address as UTF-8 bytes
      imuachainAddress: stake.imuachainAddress,
    };
  });

  // Use project root's genesis directory
  const genesisDir = resolvedGenesisPath
    ? path.dirname(resolvedGenesisPath)
    : path.join(__dirname, '../../genesis');
  const bootstrapDataPath = path.join(genesisDir, 'btc_bootstrap_data.json');

  // Ensure directory exists
  await fs.promises.mkdir(path.dirname(bootstrapDataPath), { recursive: true });
  await fs.promises.writeFile(bootstrapDataPath, JSON.stringify(bootstrapData, null, 2));
  console.log(`Exported ${bootstrapData.length} bootstrap entries to ${bootstrapDataPath}`);
}

export async function generateBootstrapGenesis(): Promise<void> {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const bootstrapContract = new ethers.Contract(config.bootstrapContractAddress, bootstrapAbi.abi, provider);

  const generator = new GenesisGenerator(
    config.btcVaultAddress,
    config.btcEsploraBaseUrl,
    bootstrapContract,
    config.minConfirmations,
    config.minAmount
  );

  const stakes = await generator.generateGenesisStakes();
  const genesisState = await generateGenesisState(stakes, generator);

  // Use environment variable if set, otherwise fall back to config
  const outputPath = process.env.BTC_GENESIS_OUTPUT_PATH || config.genesisOutputPath;
  const resolvedPath = path.isAbsolute(outputPath) ? outputPath : path.resolve(outputPath);
  await fs.promises.mkdir(path.dirname(resolvedPath), { recursive: true });

  // Export bootstrap data for UTXOGateway (using resolved path for consistency)
  await exportBootstrapData(stakes, resolvedPath);

  // Export genesis state
  await fs.promises.writeFile(resolvedPath, JSON.stringify(genesisState, null, 2));

  console.log(`Generated genesis state with ${stakes.length} valid stakes - Written to ${resolvedPath}`);
}
