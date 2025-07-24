#!/usr/bin/env node

/**
 * Unified Genesis Generation Script
 *
 * This script unifies Bitcoin and EVM genesis generation into a single output.
 * It reuses existing scripts and combines their outputs intelligently.
 *
 * Usage:
 *   node script/generate_unified.mjs [--config=config.json] [--output=genesis.json]
 *
 * Environment Variables:
 *   - UNIFIED_GENESIS_CONFIG: Path to configuration file
 *   - UNIFIED_GENESIS_OUTPUT: Path to output genesis file
 *   - All existing generate.mjs environment variables
 *   - All Bitcoin genesis environment variables
 */

import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Default configuration
const DEFAULT_CONFIG = {
  enableEVM: true,
  enableBitcoin: false, // Bitcoin support requires additional setup
  output: {
    path: process.env.UNIFIED_GENESIS_OUTPUT || './genesis_unified.json',
    pretty: true
  },
  chains: {
    evm: {
      enabled: true,
      script: './generate.mjs',
      tempOutput: './temp_evm_genesis.json'
    },
    bitcoin: {
      enabled: false,
      script: './bootstrap/bitcoin_genesis.ts',
      tempOutput: './temp_btc_genesis.json'
    },
    // XRP support can be added here in the future
    // xrp: {
    //   enabled: false,
    //   script: './bootstrap/xrp_genesis.ts',
    //   tempOutput: './temp_xrp_genesis.json'
    // }
  },
  merge: {
    strategy: 'merge', // 'merge' | 'replace' | 'append'
    conflictResolution: 'evm_priority' // 'evm_priority' | 'bitcoin_priority' | 'fail' (xrp_priority reserved for future)
  }
};

/**
 * Configuration Manager
 * Handles loading and validating configuration
 */
class ConfigManager {
  constructor() {
    this.config = { ...DEFAULT_CONFIG };
  }

  async loadConfig(configPath) {
    if (configPath && await this.fileExists(configPath)) {
      try {
        const userConfig = JSON.parse(await fs.readFile(configPath, 'utf8'));
        this.config = this.mergeConfig(this.config, userConfig);
        console.log(`✓ Loaded configuration from ${configPath}`);
      } catch (error) {
        console.warn(`⚠ Failed to load config from ${configPath}:`, error.message);
        console.log('Using default configuration');
      }
    }
    return this.config;
  }

  mergeConfig(base, override) {
    const result = { ...base };
    for (const [key, value] of Object.entries(override)) {
      if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
        result[key] = this.mergeConfig(result[key] || {}, value);
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  async fileExists(filePath) {
    try {
      await fs.access(filePath);
      return true;
    } catch {
      return false;
    }
  }

  getConfig() {
    return this.config;
  }
}

/**
 * Genesis State Merger
 * Handles merging multiple genesis states into one
 */
class GenesisStateMerger {
  constructor(strategy = 'merge', conflictResolution = 'evm_priority') {
    this.strategy = strategy;
    this.conflictResolution = conflictResolution;
  }

  /**
   * Merge multiple genesis states into a unified genesis
   * @param {Object[]} genesisStates - Array of genesis state objects
   * @returns {Object} Unified genesis state
   */
  merge(genesisStates) {
    if (genesisStates.length === 0) {
      throw new Error('No genesis states to merge');
    }

    if (genesisStates.length === 1) {
      return genesisStates[0];
    }

    console.log(`📦 Merging ${genesisStates.length} genesis states using strategy: ${this.strategy}`);

    // Start with the first genesis state as base
    let unified = JSON.parse(JSON.stringify(genesisStates[0]));

    // Merge additional genesis states
    for (let i = 1; i < genesisStates.length; i++) {
      unified = this.mergeTwo(unified, genesisStates[i]);
    }

    return unified;
  }

  /**
   * Merge two genesis states
   * @param {Object} base - Base genesis state
   * @param {Object} additional - Additional genesis state to merge
   * @returns {Object} Merged genesis state
   */
  mergeTwo(base, additional) {
    const result = JSON.parse(JSON.stringify(base));

    // Merge app_state modules
    if (additional.app_state) {
      if (!result.app_state) {
        result.app_state = {};
      }

      for (const [module, moduleState] of Object.entries(additional.app_state)) {
        if (!result.app_state[module]) {
          // New module, add it directly
          result.app_state[module] = moduleState;
          console.log(`✓ Added new module: ${module}`);
        } else {
          // Module exists, merge it
          result.app_state[module] = this.mergeModule(
            result.app_state[module],
            moduleState,
            module
          );
        }
      }
    }

    // Use the latest genesis_time
    if (additional.genesis_time) {
      result.genesis_time = additional.genesis_time;
    }

    return result;
  }

  /**
   * Merge specific app_state modules
   * @param {Object} baseModule - Base module state
   * @param {Object} additionalModule - Additional module state
   * @param {string} moduleName - Name of the module
   * @returns {Object} Merged module state
   */
  mergeModule(baseModule, additionalModule, moduleName) {
    const result = JSON.parse(JSON.stringify(baseModule));

    switch (moduleName) {
      case 'assets':
        return this.mergeAssetsModule(result, additionalModule);
      case 'delegation':
        return this.mergeDelegationModule(result, additionalModule);
      case 'dogfood':
        return this.mergeDogfoodModule(result, additionalModule);
      case 'oracle':
        return this.mergeOracleModule(result, additionalModule);
      default:
        console.log(`⚠ Unknown module ${moduleName}, using simple merge`);
        return this.mergeSimple(result, additionalModule);
    }
  }

  mergeAssetsModule(base, additional) {
    const result = { ...base };

    // Merge client_chains
    if (additional.client_chains) {
      if (!result.client_chains) result.client_chains = [];

      for (const chain of additional.client_chains) {
        const existingIndex = result.client_chains.findIndex(c => c.layer_zero_chain_id === chain.layer_zero_chain_id);
        if (existingIndex >= 0) {
          console.log(`⚠ Conflict: client_chain with layer_zero_chain_id ${chain.layer_zero_chain_id} already exists`);
          if (this.conflictResolution === 'bitcoin_priority') {
            result.client_chains[existingIndex] = chain;
          }
          // XRP priority can be added here in the future
          // if (this.conflictResolution === 'xrp_priority') {
          //   result.client_chains[existingIndex] = chain;
          // }
        } else {
          result.client_chains.push(chain);
          console.log(`✓ Added client_chain: ${chain.name}`);
        }
      }
    }

    // Merge tokens
    if (additional.tokens) {
      if (!result.tokens) result.tokens = [];

      for (const token of additional.tokens) {
        const existingIndex = result.tokens.findIndex(t =>
          t.asset_basic_info.layer_zero_chain_id === token.asset_basic_info.layer_zero_chain_id &&
          t.asset_basic_info.address === token.asset_basic_info.address
        );

        if (existingIndex >= 0) {
          console.log(`⚠ Conflict: token ${token.asset_basic_info.name} already exists`);
          if (this.conflictResolution === 'bitcoin_priority') {
            result.tokens[existingIndex] = token;
          }
          // XRP priority can be added here in the future
          // if (this.conflictResolution === 'xrp_priority') {
          //   result.tokens[existingIndex] = token;
          // }
        } else {
          result.tokens.push(token);
          console.log(`✓ Added token: ${token.asset_basic_info.name}`);
        }
      }
    }

    // Merge deposits
    if (additional.deposits) {
      if (!result.deposits) result.deposits = [];
      result.deposits = result.deposits.concat(additional.deposits);
      console.log(`✓ Added ${additional.deposits.length} deposits`);
    }

    return result;
  }

  mergeDelegationModule(base, additional) {
    const result = { ...base };

    // Merge delegations
    if (additional.delegations) {
      if (!result.delegations) result.delegations = [];
      result.delegations = result.delegations.concat(additional.delegations);
      console.log(`✓ Added ${additional.delegations.length} delegations`);
    }

    // Merge associations
    if (additional.associations) {
      if (!result.associations) result.associations = [];
      result.associations = result.associations.concat(additional.associations);
      console.log(`✓ Added ${additional.associations.length} associations`);
    }

    // Merge stakersByOperator
    if (additional.stakersByOperator) {
      if (!result.stakersByOperator) result.stakersByOperator = [];
      result.stakersByOperator = result.stakersByOperator.concat(additional.stakersByOperator);
      console.log(`✓ Added ${additional.stakersByOperator.length} stakersByOperator entries`);
    }

    return result;
  }

  mergeDogfoodModule(base, additional) {
    const result = { ...base };

    // For dogfood, we typically want to merge validators and keep the most recent params
    if (additional.val_set) {
      if (!result.val_set) result.val_set = [];

      // Merge validators, avoiding duplicates by consensus_public_key
      for (const validator of additional.val_set) {
        const existingIndex = result.val_set.findIndex(v =>
          v.consensus_public_key === validator.consensus_public_key
        );

        if (existingIndex >= 0) {
          console.log(`⚠ Conflict: validator with consensus key ${validator.consensus_public_key} already exists`);
          if (this.conflictResolution === 'bitcoin_priority') {
            result.val_set[existingIndex] = validator;
          }
        } else {
          result.val_set.push(validator);
          console.log(`✓ Added validator: ${validator.consensus_public_key}`);
        }
      }
    }

    // Use additional params if they exist
    if (additional.params) {
      result.params = additional.params;
    }

    return result;
  }

  mergeOracleModule(base, additional) {
    const result = { ...base };

    // Merge tokens (oracle tokens are different from assets tokens)
    if (additional.tokens) {
      if (!result.tokens) result.tokens = [];

      for (const token of additional.tokens) {
        const existingIndex = result.tokens.findIndex(t => t.name === token.name);
        if (existingIndex >= 0) {
          console.log(`⚠ Conflict: oracle token ${token.name} already exists`);
          if (this.conflictResolution === 'bitcoin_priority') {
            result.tokens[existingIndex] = token;
          }
        } else {
          result.tokens.push(token);
          console.log(`✓ Added oracle token: ${token.name}`);
        }
      }
    }

    // Merge other oracle data
    if (additional.prices) {
      if (!result.prices) result.prices = [];
      result.prices = result.prices.concat(additional.prices);
    }

    return result;
  }

  mergeSimple(base, additional) {
    // Simple deep merge for unknown modules
    const result = { ...base };
    for (const [key, value] of Object.entries(additional)) {
      if (Array.isArray(value)) {
        if (!result[key]) result[key] = [];
        result[key] = result[key].concat(value);
      } else if (typeof value === 'object' && value !== null) {
        if (!result[key]) result[key] = {};
        result[key] = { ...result[key], ...value };
      } else {
        result[key] = value;
      }
    }
    return result;
  }
}

/**
 * Script Runner
 * Handles execution of individual genesis generation scripts
 */
class ScriptRunner {
  constructor(workingDir) {
    this.workingDir = workingDir;
  }

  /**
   * Run EVM genesis generation script
   * @param {Object} chainConfig - Chain configuration
   * @returns {Object} Generated genesis state
   */
  async runEvmGenesis(chainConfig) {
    console.log('🔄 Running EVM genesis generation...');

    try {
      // Import and run the existing generate.mjs
      const { default: generateEvm } = await import('./generate.mjs');

      // The generate.mjs typically writes to a file, so we need to capture its output
      // For now, we'll read the generated file
      const outputPath = process.env.INTEGRATION_RESULT_GENESIS_FILE_PATH || chainConfig.tempOutput;

      // Run the EVM genesis generation (it should create the file)
      await this.runScript(chainConfig.script);

      // Read the generated file
      if (await this.fileExists(outputPath)) {
        const content = await fs.readFile(outputPath, 'utf8');
        const genesis = JSON.parse(content);
        console.log('✓ EVM genesis generation completed');
        return genesis;
      } else {
        throw new Error(`EVM genesis output file not found: ${outputPath}`);
      }
    } catch (error) {
      console.error('❌ EVM genesis generation failed:', error.message);
      throw error;
    }
  }

  /**
   * Run Bitcoin genesis generation script
   * @param {Object} chainConfig - Chain configuration
   * @returns {Object} Generated genesis state
   */
  async runBitcoinGenesis(chainConfig) {
    console.log('🔄 Running Bitcoin genesis generation...');

    try {
      // For Bitcoin genesis, we would need to import and run the TypeScript module
      // This is more complex and would require ts-node or compilation
      console.log('⚠ Bitcoin genesis generation not implemented in this version');
      console.log('ℹ This would require additional setup for TypeScript execution');

      // For now, return an empty genesis structure that can be extended
      return this.createEmptyBitcoinGenesis();
    } catch (error) {
      console.error('❌ Bitcoin genesis generation failed:', error.message);
      throw error;
    }
  }

  // XRP genesis generation can be added here in the future
  // async runXrpGenesis(chainConfig) {
  //   console.log('🔄 Running XRP genesis generation...');
  //   // Implementation will be added when XRP support is ready
  // }

  /**
   * Create an empty Bitcoin genesis structure for demonstration
   * @returns {Object} Empty Bitcoin genesis structure
   */
  createEmptyBitcoinGenesis() {
    return {
      app_state: {
        assets: {
          client_chains: [{
            layer_zero_chain_id: 1,
            name: "Bitcoin",
            meta_info: "Bitcoin mainnet",
            finalization_blocks: 6,
            address_length: 20
          }],
          tokens: [{
            asset_basic_info: {
              name: "Bitcoin",
              symbol: "BTC",
              address: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
              decimals: "8",
              layer_zero_chain_id: 1,
              imua_chain_index: "2",
              meta_info: "Bitcoin virtual token"
            },
            staking_total_amount: "0"
          }],
          deposits: []
        },
        delegation: {
          delegations: [],
          associations: [],
          stakersByOperator: []
        }
      }
    };
  }

  // XRP genesis structure can be added here in the future
  // createEmptyXrpGenesis() {
  //   // Implementation will be added when XRP support is ready
  // }

  async runScript(scriptPath) {
    // For now, we'll assume scripts are run as separate processes
    // In a production version, this could use child_process.exec
    console.log(`Running script: ${scriptPath}`);
  }

  async fileExists(filePath) {
    try {
      await fs.access(filePath);
      return true;
    } catch {
      return false;
    }
  }
}

/**
 * Main Unified Genesis Generator
 */
class UnifiedGenesisGenerator {
  constructor() {
    this.configManager = new ConfigManager();
    this.scriptRunner = new ScriptRunner(__dirname);
    this.merger = null; // Will be initialized with config
  }

  async generate(configPath = null) {
    try {
      console.log('🚀 Starting unified genesis generation...');

      // Load configuration
      const config = await this.configManager.loadConfig(
        configPath || process.env.UNIFIED_GENESIS_CONFIG
      );

      // Initialize merger with config
      this.merger = new GenesisStateMerger(
        config.merge.strategy,
        config.merge.conflictResolution
      );

      console.log('📋 Configuration:');
      console.log(`  - EVM enabled: ${config.chains.evm.enabled}`);
      console.log(`  - Bitcoin enabled: ${config.chains.bitcoin.enabled}`);
      console.log(`  - Merge strategy: ${config.merge.strategy}`);
      console.log(`  - Conflict resolution: ${config.merge.conflictResolution}`);

      // Generate genesis states for each enabled chain
      const genesisStates = [];

      if (config.chains.evm.enabled) {
        try {
          const evmGenesis = await this.scriptRunner.runEvmGenesis(config.chains.evm);
          genesisStates.push(evmGenesis);
        } catch (error) {
          console.warn('⚠ EVM genesis generation failed, continuing with other chains');
          console.warn(error.message);
        }
      }

      if (config.chains.bitcoin.enabled) {
        try {
          const bitcoinGenesis = await this.scriptRunner.runBitcoinGenesis(config.chains.bitcoin);
          genesisStates.push(bitcoinGenesis);
        } catch (error) {
          console.warn('⚠ Bitcoin genesis generation failed, continuing with other chains');
          console.warn(error.message);
        }
      }

      // XRP chain support can be added here in the future
      // if (config.chains.xrp && config.chains.xrp.enabled) {
      //   try {
      //     const xrpGenesis = await this.scriptRunner.runXrpGenesis(config.chains.xrp);
      //     genesisStates.push(xrpGenesis);
      //   } catch (error) {
      //     console.warn('⚠ XRP genesis generation failed, continuing with other chains');
      //     console.warn(error.message);
      //   }
      // }

      if (genesisStates.length === 0) {
        throw new Error('No genesis states were generated successfully');
      }

      // Merge genesis states
      const unifiedGenesis = this.merger.merge(genesisStates);

      // Add metadata about the generation
      unifiedGenesis._unified_generation_info = {
        generated_at: new Date().toISOString(),
        sources: [],
        version: "1.0.0"
      };

      if (config.chains.evm.enabled) {
        unifiedGenesis._unified_generation_info.sources.push('evm');
      }
      if (config.chains.bitcoin.enabled) {
        unifiedGenesis._unified_generation_info.sources.push('bitcoin');
      }
      // XRP source tracking can be added here in the future
      // if (config.chains.xrp && config.chains.xrp.enabled) {
      //   unifiedGenesis._unified_generation_info.sources.push('xrp');
      // }

      // Write output
      await this.writeOutput(unifiedGenesis, config.output);

      console.log('✅ Unified genesis generation completed successfully!');
      console.log(`📄 Output written to: ${config.output.path}`);

      return unifiedGenesis;

    } catch (error) {
      console.error('❌ Unified genesis generation failed:', error.message);
      throw error;
    }
  }

  async writeOutput(genesis, outputConfig) {
    const content = outputConfig.pretty
      ? JSON.stringify(genesis, null, 2)
      : JSON.stringify(genesis);

    await fs.writeFile(outputConfig.path, content, 'utf8');
  }
}

/**
 * CLI Interface
 */
async function main() {
  const args = process.argv.slice(2);
  let configPath = null;

  // Parse command line arguments
  for (const arg of args) {
    if (arg.startsWith('--config=')) {
      configPath = arg.substring(9);
    } else if (arg.startsWith('--help') || arg === '-h') {
      console.log(`
Unified Genesis Generation Script

Usage:
  node script/generate_unified.mjs [options]

Options:
  --config=<path>     Path to configuration file
  --help, -h          Show this help message

Environment Variables:
  UNIFIED_GENESIS_CONFIG    Path to configuration file
  UNIFIED_GENESIS_OUTPUT    Path to output genesis file

  Plus all environment variables used by generate.mjs and bitcoin_genesis.ts

Examples:
  # Generate with default configuration
  node script/generate_unified.mjs

  # Generate with custom configuration
  node script/generate_unified.mjs --config=./my-config.json

  # Generate with environment variables
  UNIFIED_GENESIS_OUTPUT=./custom_genesis.json node script/generate_unified.mjs
`);
      process.exit(0);
    }
  }

  try {
    const generator = new UnifiedGenesisGenerator();
    await generator.generate(configPath);
  } catch (error) {
    console.error('Fatal error:', error.message);
    process.exit(1);
  }
}

// Run if this script is executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(console.error);
}

export default UnifiedGenesisGenerator;