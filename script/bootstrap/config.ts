import path from 'path';

// Constants for BTC virtual token
export const BTC_CONFIG = {
  VIRTUAL_ADDRESS: '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB',
  NAME: 'Bitcoin',
  SYMBOL: 'BTC',
  DECIMALS: 8,
  CHAIN_ID: 1, // Bitcoin mainnet
  META_INFO: 'Bitcoin virtual token'
};

export const CHAIN_CONFIG = {
  NAME: 'Bitcoin',
  META_INFO: 'Bitcoin mainnet',
  FINALIZATION_BLOCKS: 6,
  LAYER_ZERO_CHAIN_ID: 1,
  ADDRESS_LENGTH: 20
};

export interface Config {
  btcVaultAddress: string;
  btcEsploraBaseUrl: string;
  minConfirmations: number;
  minAmount: number;
  bootstrapContractAddress: string;
  rpcUrl: string;
  genesisOutputPath: string;
  maxValidators: number;
  btcPriceUsd: number; // BTC price in USD for voting power calculation
}

const config: Config = {
  btcVaultAddress: process.env.BITCOIN_VAULT_ADDRESS || '',
  btcEsploraBaseUrl: process.env.BITCOIN_ESPLORA_API_URL || '',
  minConfirmations: parseInt(process.env.MIN_CONFIRMATIONS || '6'),
  minAmount: parseInt(process.env.MIN_AMOUNT || '546'), // satoshis
  bootstrapContractAddress: process.env.BOOTSTRAP_CONTRACT_ADDRESS || '',
  rpcUrl: process.env.CLIENT_CHAIN_RPC || 'http://localhost:8545',
  genesisOutputPath: process.env.GENESIS_OUTPUT_PATH || 
                     path.join(__dirname, '../../../genesis/bootstrap_stakes.json'),
  maxValidators: parseInt(process.env.MAX_VALIDATORS || '100'),
  btcPriceUsd: parseFloat(process.env.BTC_PRICE_USD || '50000')
};

if (!config.btcVaultAddress) throw new Error('BTC_VAULT_ADDRESS not set');
if (!config.btcEsploraBaseUrl) throw new Error('BTC_ESPLORA_BASE_URL not set');

export default config; 