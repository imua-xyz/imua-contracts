#!/usr/bin/env node

/**
 * Unified Genesis Generation Script
 *
 * This script unifies Bitcoin and EVM genesis generation into a single output.
 * It reuses existing scripts and combines their outputs intelligently.
 *
 * Usage:
 *   node script/bootstrap/generate_unified.mjs [--config=config.json] [--output=genesis.json]
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
import JSONbig from 'json-bigint';

// Load environment variables
dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configure json-bigint for safe BigInt handling
const jsonBig = JSONbig({ storeAsString: true });

/**
 * Safe deep copy function that handles BigInt values
 * @param {Object} obj - Object to deep copy
 * @returns {Object} Deep copied object
 */
function safeDeepCopy(obj) {
  return jsonBig.parse(jsonBig.stringify(obj));
}

// Default configuration
const DEFAULT_CONFIG = {
  output: {
    path: process.env.UNIFIED_GENESIS_OUTPUT || 'genesis/genesis_unified.json',
    pretty: true,
  },
  chains: {
    evm: {
      enabled: true,
      script: './generate.mjs',
      tempOutput: 'genesis/temp_evm_genesis.json',
      envPathKey: 'INTEGRATION_RESULT_GENESIS_FILE_PATH',
    },
    bitcoin: {
      enabled: true,
      script: './bitcoin_genesis.ts',
      tempOutput: 'genesis/temp_btc_genesis.json',
      useTsx: true,
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
    conflictResolution: 'evm_priority', // 'evm_priority' | 'bitcoin_priority' | 'fail' (xrp_priority reserved for future)
  },
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
    if (configPath && (await this.fileExists(configPath))) {
      let configData;
      try {
        configData = await fs.readFile(configPath, 'utf8');
      } catch (error) {
        console.warn(`⚠ Failed to read config file ${configPath}: ${error.message}. Using default configuration.`);
        return this.config;
      }

      try {
        const userConfig = JSON.parse(configData);
        this.config = this.mergeConfig(this.config, userConfig);
        console.log(`📄 Loaded configuration from ${configPath}`);
      } catch (error) {
        console.warn(`⚠ Invalid JSON in config file ${configPath}: ${error.message}. Using default configuration.`);
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

    // Start with the first genesis state as base
    let unified = safeDeepCopy(genesisStates[0]);

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
    const result = safeDeepCopy(base);

    // Merge app_state modules
    if (additional.app_state) {
      if (!result.app_state) {
        result.app_state = {};
      }

      for (const [module, moduleState] of Object.entries(additional.app_state)) {
        if (!result.app_state[module]) {
          // New module, add it directly
          result.app_state[module] = moduleState;
        } else {
          // Module exists, merge it
          result.app_state[module] = this.mergeModule(result.app_state[module], moduleState, module);
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
    const result = safeDeepCopy(baseModule);

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
        return this.mergeSimple(result, additionalModule);
    }
  }

  mergeAssetsModule(base, additional) {
    const result = { ...base };

    // Merge client_chains
    if (additional.client_chains) {
      if (!result.client_chains) result.client_chains = [];

      for (const chain of additional.client_chains) {
        const existingIndex = result.client_chains.findIndex((c) => c.layer_zero_chain_id === chain.layer_zero_chain_id);
        if (existingIndex >= 0) {
          if (this.conflictResolution === 'bitcoin_priority') {
            result.client_chains[existingIndex] = chain;
          }
          // XRP priority can be added here in the future
          // if (this.conflictResolution === 'xrp_priority') {
          //   result.client_chains[existingIndex] = chain;
          // }
        } else {
          result.client_chains.push(chain);
        }
      }
    }

    // Merge tokens
    if (additional.tokens) {
      if (!result.tokens) result.tokens = [];

      for (const token of additional.tokens) {
        const existingIndex = result.tokens.findIndex(
          (t) =>
            t.asset_basic_info.layer_zero_chain_id === token.asset_basic_info.layer_zero_chain_id &&
            t.asset_basic_info.address === token.asset_basic_info.address
        );

        if (existingIndex >= 0) {
          if (this.conflictResolution === 'bitcoin_priority') {
            result.tokens[existingIndex] = token;
          }
          // XRP priority can be added here in the future
          // if (this.conflictResolution === 'xrp_priority') {
          //   result.tokens[existingIndex] = token;
          // }
        } else {
          result.tokens.push(token);
        }
      }
    }

    // Merge deposits
    if (additional.deposits) {
      if (!result.deposits) result.deposits = [];
      result.deposits = result.deposits.concat(additional.deposits);
    }

    // Merge operator_assets - Bitcoin genesis format with smart merge for same operator
    if (additional.operator_assets) {
      if (!result.operator_assets) result.operator_assets = [];

      for (const operatorAsset of additional.operator_assets) {
        const existingIndex = result.operator_assets.findIndex(
          (existing) => existing.operator === operatorAsset.operator
        );

        if (existingIndex >= 0) {
          // Same operator found, merge assets_state arrays (different chains have different asset_ids)
          const existingAssetsState = result.operator_assets[existingIndex].assets_state || [];
          const additionalAssetsState = operatorAsset.assets_state || [];

          // Since different chains have different asset_ids, simply concatenate the arrays
          const mergedAssetsState = existingAssetsState.concat(additionalAssetsState);

          result.operator_assets[existingIndex].assets_state = mergedAssetsState;
          console.log(`🔄 Merged operator_assets for operator ${operatorAsset.operator}: ${existingAssetsState.length} + ${additionalAssetsState.length} = ${mergedAssetsState.length} total assets`);
        } else {
          // New operator, add it directly
          result.operator_assets.push(operatorAsset);
          console.log(`➕ Added new operator ${operatorAsset.operator} with ${operatorAsset.assets_state?.length || 0} assets`);
        }
      }

      console.log(`🔄 Total operator_assets entries: ${result.operator_assets.length}`);
    }

    return result;
  }

  mergeDelegationModule(base, additional) {
    const result = { ...base };

    // Merge delegations
    if (additional.delegations) {
      if (!result.delegations) result.delegations = [];
      result.delegations = result.delegations.concat(additional.delegations);
    }

    // Merge associations
    if (additional.associations) {
      if (!result.associations) result.associations = [];
      result.associations = result.associations.concat(additional.associations);
    }

    // Merge stakersByOperator (camelCase)
    if (additional.stakersByOperator) {
      if (!result.stakersByOperator) result.stakersByOperator = [];
      result.stakersByOperator = result.stakersByOperator.concat(additional.stakersByOperator);
    }

    // Merge stakers_by_operator (snake_case) - Bitcoin genesis format
    if (additional.stakers_by_operator) {
      if (!result.stakers_by_operator) result.stakers_by_operator = [];
      result.stakers_by_operator = result.stakers_by_operator.concat(additional.stakers_by_operator);
      console.log(`🔄 Merged ${additional.stakers_by_operator.length} stakers_by_operator entries`);
    }

    if (additional.delegation_states) {
      if (!result.delegation_states) result.delegation_states = [];
      result.delegation_states = result.delegation_states.concat(additional.delegation_states);
      console.log(`🔄 Merged ${additional.delegation_states.length} delegation_states entries`);
    }

    return result;
  }

  mergeDogfoodModule(base, additional) {
    const result = { ...base };

    // For dogfood, we need to merge validators by public_key and sum their power
    if (additional.val_set) {
      if (!result.val_set) result.val_set = [];

      // Merge validators, summing power for same public_key
      for (const validator of additional.val_set) {
        const existingIndex = result.val_set.findIndex((v) => v.public_key === validator.public_key);

        if (existingIndex >= 0) {
          // Same public_key found, sum the power values
          const existingPower = BigInt(result.val_set[existingIndex].power || '0');
          const additionalPower = BigInt(validator.power || '0');
          const totalPower = existingPower + additionalPower;

          result.val_set[existingIndex].power = totalPower.toString();
          console.log(`🔄 Merged validator with public_key ${validator.public_key}: ${existingPower} + ${additionalPower} = ${totalPower}`);
        } else {
          // New validator, add it directly
          result.val_set.push(validator);
        }
      }
    }

    // Merge params, especially asset_ids array with deduplication
    if (additional.params) {
      if (!result.params) {
        result.params = additional.params;
      } else {
        // Store original asset_ids before merging
        const originalAssetIds = result.params.asset_ids || [];
        const additionalAssetIds = additional.params.asset_ids || [];

        // Merge params fields (this might overwrite asset_ids)
        result.params = { ...result.params, ...additional.params };

        // Special handling for asset_ids array - merge and deduplicate
        if (originalAssetIds.length > 0 || additionalAssetIds.length > 0) {
          const combinedAssetIds = [...originalAssetIds, ...additionalAssetIds];
          result.params.asset_ids = [...new Set(combinedAssetIds)];
          console.log(`🔄 Merged asset_ids: ${originalAssetIds.length} + ${additionalAssetIds.length} = ${result.params.asset_ids.length} unique assets - [${result.params.asset_ids.join(', ')}]`);
        }
      }
    }

    // Sort validators by power (descending) and recalculate last_total_power
    if (result.val_set && result.val_set.length > 0) {
      // Sort validators by power (descending), then by public_key (ascending) for deterministic ordering
      result.val_set.sort((a, b) => {
        const powerA = BigInt(a.power || '0');
        const powerB = BigInt(b.power || '0');
        if (powerA === powerB) {
          return a.public_key.localeCompare(b.public_key);
        }
        return powerB > powerA ? 1 : -1;
      });

      const totalPower = result.val_set.reduce((sum, validator) => {
        return sum + BigInt(validator.power || '0');
      }, BigInt('0'));
      result.last_total_power = totalPower.toString();
      console.log(`🔄 Sorted ${result.val_set.length} validators and updated last_total_power to ${totalPower}`);
    }

    return result;
  }

  mergeOracleModule(base, additional) {
    const result = { ...base };

    const baseTokens = base.params?.tokens || [];
    const additionalTokens = additional.params?.tokens || [];
    console.log(`🔍 Oracle merge: base tokens ${baseTokens.length}, additional tokens ${additionalTokens.length}`);

    // Initialize result.params if needed
    if (!result.params) result.params = {};
    if (!result.params.tokens) result.params.tokens = [];

    // Merge tokens (oracle tokens are different from assets tokens)
    if (additionalTokens.length > 0) {
      for (const token of additionalTokens) {
        // Use more specific matching: name + chain_id + contract_address for uniqueness
        const existingIndex = result.params.tokens.findIndex((t) =>
          t.name === token.name &&
          t.chain_id === token.chain_id &&
          t.contract_address === token.contract_address
        );

        if (existingIndex >= 0) {
          // Exact match found, apply conflict resolution
          if (this.conflictResolution === 'bitcoin_priority') {
            result.params.tokens[existingIndex] = token;
            console.log(`🔄 Replaced oracle token ${token.name} (chain_id: ${token.chain_id}) with Bitcoin priority`);
          } else {
            console.log(`🔄 Keeping existing oracle token ${token.name} (chain_id: ${token.chain_id}) with ${this.conflictResolution}`);
          }
        } else {
          // No exact match, add the token
          result.params.tokens.push(token);
          console.log(`➕ Added oracle token ${token.name} (chain_id: ${token.chain_id}, address: ${token.contract_address})`);
        }
      }
    }

    // Merge token_feeders
    if (additional.params?.token_feeders) {
      if (!result.params.token_feeders) result.params.token_feeders = [];

      for (const feeder of additional.params.token_feeders) {
        // Check for existing feeder by token_id
        const existingIndex = result.params.token_feeders.findIndex(f => f.token_id === feeder.token_id);

        if (existingIndex >= 0) {
          if (this.conflictResolution === 'bitcoin_priority') {
            result.params.token_feeders[existingIndex] = feeder;
            console.log(`🔄 Replaced token_feeder for token_id ${feeder.token_id} with Bitcoin priority`);
          } else {
            console.log(`🔄 Keeping existing token_feeder for token_id ${feeder.token_id} with ${this.conflictResolution}`);
          }
        } else {
          result.params.token_feeders.push(feeder);
          console.log(`➕ Added token_feeder for token_id ${feeder.token_id}`);
        }
      }
    }

    // Merge prices_list
    if (additional.prices_list) {
      if (!result.prices_list) result.prices_list = [];

      for (const priceEntry of additional.prices_list) {
        // Check for existing price entry by token_id
        const existingIndex = result.prices_list.findIndex(p => p.token_id === priceEntry.token_id);

        if (existingIndex >= 0) {
          if (this.conflictResolution === 'bitcoin_priority') {
            result.prices_list[existingIndex] = priceEntry;
            console.log(`🔄 Replaced prices_list for token_id ${priceEntry.token_id} with Bitcoin priority`);
          } else {
            // For EVM priority, we might want to merge price_list arrays
            if (priceEntry.price_list && Array.isArray(priceEntry.price_list)) {
              if (!result.prices_list[existingIndex].price_list) {
                result.prices_list[existingIndex].price_list = [];
              }
              result.prices_list[existingIndex].price_list = result.prices_list[existingIndex].price_list.concat(priceEntry.price_list);
              console.log(`🔄 Merged price_list for token_id ${priceEntry.token_id} with ${this.conflictResolution}`);
            }
          }
        } else {
          result.prices_list.push(priceEntry);
          console.log(`➕ Added prices_list entry for token_id ${priceEntry.token_id}`);
        }
      }
    }

    // Merge other oracle params (excluding tokens, token_feeders which are handled above)
    if (additional.params) {
      if (!result.params) result.params = {};
      for (const [key, value] of Object.entries(additional.params)) {
        if (key !== 'tokens' && key !== 'token_feeders') { // tokens and token_feeders are handled above
          if (Array.isArray(value)) {
            // For arrays, concatenate them
            if (!result.params[key]) result.params[key] = [];
            result.params[key] = result.params[key].concat(value);
            console.log(`🔄 Merged oracle params array ${key}: added ${value.length} entries`);
          } else {
            result.params[key] = value;
            console.log(`🔄 Set oracle params ${key}`);
          }
        }
      }
    }

    console.log(`🔍 Oracle merge result: ${result.params.tokens.length} tokens, ${result.params.token_feeders?.length || 0} feeders, ${result.prices_list?.length || 0} price entries`);
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
   * Generic method to run chain genesis generation
   * @param {string} chainName - Name of the chain (for logging)
   * @param {Object} chainConfig - Chain configuration
   * @param {Object} options - Generation options
   * @returns {Object} Generated genesis state
   */
  async runChainGenesis(chainName, chainConfig, options = {}) {
    try {
      const {
        envPathKey = null,
        defaultOutputPath = chainConfig.tempOutput,
        scriptFunction = null,
        waitTime = 1000
      } = options;

      // Determine output path from environment or config
      const outputPath = envPathKey ? (process.env[envPathKey] || defaultOutputPath) : defaultOutputPath;
      const resolvedOutputPath = path.isAbsolute(outputPath) ? outputPath : path.resolve(outputPath);

      // For Bitcoin genesis, set the environment variable to ensure consistent path usage
      if (chainName === 'Bitcoin' && envPathKey) {
        const oldValue = process.env[envPathKey];
        process.env[envPathKey] = resolvedOutputPath;
        console.log(`🔧 Setting ${envPathKey}=${resolvedOutputPath} (was: ${oldValue || 'undefined'}) for consistent path usage`);
      }

      // Check if genesis file already exists
      if (await this.fileExists(resolvedOutputPath)) {
        const content = await fs.readFile(resolvedOutputPath, 'utf8');
        const genesis = JSON.parse(content);
        console.log(`📄 Loading existing ${chainName} genesis from: ${resolvedOutputPath} ✓`);
        return genesis;
      }

      // If file doesn't exist, run the generation script
      console.log(`📋 ${chainName} genesis file not found, running generation script: ${chainConfig.script}`);

      // Check if we need to use tsx for TypeScript files
      if (chainConfig.useTsx && chainConfig.script.endsWith('.ts')) {
        console.log(`🔧 Using tsx to run TypeScript file: ${chainConfig.script}`);
        await this.runWithTsx(chainConfig.script, scriptFunction);
      } else {
        // Import and run the generation script (JavaScript)
        const scriptModule = await import(`${chainConfig.script}`);

        if (scriptFunction) {
          // Call specific function if provided
          await scriptModule[scriptFunction]();
        }
        // For EVM script, it executes immediately on import, so no function call needed
      }

      // Poll for file with timeout
      const maxAttempts = 30;
      const pollInterval = 100;

      for (let attempt = 0; attempt < maxAttempts; attempt++) {
        if (await this.fileExists(resolvedOutputPath)) {
          try {
            const content = await fs.readFile(resolvedOutputPath, 'utf8');
            const genesis = JSON.parse(content);
            console.log(`🔄 ${chainName} genesis generation completed from: ${resolvedOutputPath} ✓`);
            return genesis;
          } catch (error) {
            if (attempt === maxAttempts - 1) throw error;
            // File might still be writing, continue polling
          }
        }
        await new Promise(resolve => setTimeout(resolve, pollInterval));
      }

      throw new Error(`${chainName} genesis output file not found after ${maxAttempts * pollInterval}ms: ${resolvedOutputPath}`);
    } catch (error) {
      console.error(`❌ ${chainName} genesis generation failed: ${error.message}`);
      throw error;
    }
  }



  /**
   * Run EVM genesis generation script
   * @param {Object} chainConfig - Chain configuration
   * @returns {Object} Generated genesis state
   */
  async runEvmGenesis(chainConfig) {
    return this.runChainGenesis('EVM', chainConfig, {
      envPathKey: chainConfig.envPathKey,
      waitTime: 1000
    });
  }

  /**
   * Run TypeScript file using tsx
   * @param {string} scriptPath - Path to TypeScript file
   * @param {string} functionName - Function to call (optional)
   */
  async runWithTsx(scriptPath, functionName = null) {
    const { spawn } = await import('child_process');

    return new Promise((resolve, reject) => {
      let args;
      if (functionName) {
        // Create a temporary script that imports and calls the function
        const tempScript = `
import { ${functionName} } from '${scriptPath}';
(async () => {
  await ${functionName}();
})().catch(console.error);
        `;
        args = ['tsx', '--eval', tempScript];
      } else {
        args = ['tsx', scriptPath];
      }

      console.log(`🔧 Running: npx tsx with ${functionName ? 'function call' : 'direct execution'}`);

      const tsxProcess = spawn('npx', args, {
        cwd: path.dirname(process.argv[1]), // Run from script/bootstrap directory
        stdio: 'inherit',
        env: { ...process.env }
      });

      tsxProcess.on('close', (code) => {
        if (code === 0) {
          resolve();
        } else {
          reject(new Error(`tsx process exited with code ${code}`));
        }
      });

      tsxProcess.on('error', (error) => {
        reject(new Error(`Failed to start tsx: ${error.message}`));
      });
    });
  }

  /**
   * Run Bitcoin genesis generation script
   * @param {Object} chainConfig - Chain configuration
   * @returns {Object} Generated genesis state
   */
  async runBitcoinGenesis(chainConfig) {
    // Use absolute path to ensure consistency between read and write operations
    const absoluteOutputPath = path.resolve(process.cwd(), 'genesis/bitcoin_bootstrap_genesis.json');

    return this.runChainGenesis('Bitcoin', chainConfig, {
      envPathKey: 'GENESIS_OUTPUT_PATH',
      defaultOutputPath: absoluteOutputPath,
      scriptFunction: 'generateBootstrapGenesis',
      waitTime: 0
    });
  }

  // XRP genesis generation can be added here in the future
  // async runXrpGenesis(chainConfig) {
  //   console.log('🔄 Running XRP genesis generation...');
  //   // Implementation will be added when XRP support is ready
  // }

  // XRP genesis structure can be added here in the future
  // createEmptyXrpGenesis() {
  //   // Implementation will be added when XRP support is ready
  // }

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
      const config = await this.configManager.loadConfig(configPath || process.env.UNIFIED_GENESIS_CONFIG);

      // Initialize merger with config
      this.merger = new GenesisStateMerger(config.merge.strategy, config.merge.conflictResolution);

      // Check if we should use existing JSON files directly
      const useExistingFiles = process.env.USE_EXISTING_FILES === 'true';

      if (useExistingFiles) {
        console.log('📄 Using existing JSON files for merge...');
        return await this.mergeExistingFiles(config);
      }

      // Show enabled chains only
      const enabledChains = [];
      if (config.chains.evm.enabled) enabledChains.push('EVM');
      if (config.chains.bitcoin.enabled) enabledChains.push('Bitcoin');

      console.log(`📋 Generating genesis for: ${enabledChains.join(', ')}`);

      // Generate genesis states for each enabled chain
      const genesisStates = [];

      console.log('🔄 Starting genesis generation for all enabled chains...');

      // Define chain runners
      const chainRunners = [
        {
          name: 'EVM',
          enabled: config.chains.evm.enabled,
          config: config.chains.evm,
          runner: this.scriptRunner.runEvmGenesis.bind(this.scriptRunner)
        },
        {
          name: 'Bitcoin',
          enabled: config.chains.bitcoin.enabled,
          config: config.chains.bitcoin,
          runner: this.scriptRunner.runBitcoinGenesis.bind(this.scriptRunner)
        }
        // Future chains can be added here:
        // {
        //   name: 'XRP',
        //   enabled: config.chains.xrp?.enabled || false,
        //   config: config.chains.xrp,
        //   runner: this.scriptRunner.runXrpGenesis.bind(this.scriptRunner)
        // }
      ];

      // Run enabled chains
      for (const chain of chainRunners) {
        if (chain.enabled) {
          try {
            console.log(`📋 Generating ${chain.name} genesis...`);
            const genesis = await chain.runner(chain.config);
            genesisStates.push(genesis);
            console.log(`✅ ${chain.name} genesis completed successfully`);
          } catch (error) {
            console.warn(`⚠ ${chain.name} genesis generation failed, continuing with other chains. Error: ${error.message}`);
          }
        }
      }

      // XRP chain support can be added here in the future
      // if (config.chains.xrp && config.chains.xrp.enabled) {
      //   try {
      //     const xrpGenesis = await this.scriptRunner.runXrpGenesis(config.chains.xrp);
      //     genesisStates.push(xrpGenesis);
      //   } catch (error) {
      //     console.warn('⚠ XRP genesis generation failed, continuing with other chains');
      //     console.warn(`   Error: ${error.message}`);
      //   }
      // }

      if (genesisStates.length === 0) {
        throw new Error('No genesis states were generated successfully');
      }

      // Merge genesis states
      console.log('🔄 Merging genesis states...');
      const unifiedGenesis = this.merger.merge(genesisStates);

      // Validate genesis structure
      this.validateGenesisStructure(unifiedGenesis);

      // Write output
      await this.writeOutput(unifiedGenesis, config.output);

      console.log(`✅ Unified genesis generation completed successfully! Output written to: ${config.output.path}`);

      return unifiedGenesis;
    } catch (error) {
      console.error('❌ Unified genesis generation failed:', error.message);
      throw error;
    }
  }

  /**
 * Validate the unified genesis structure
 * @param {Object} genesis - The unified genesis to validate
 */
  validateGenesisStructure(genesis) {
    if (!genesis || typeof genesis !== 'object') {
      throw new Error('Invalid genesis: must be an object');
    }

    if (!genesis.app_state || typeof genesis.app_state !== 'object') {
      throw new Error('Invalid genesis: missing or invalid app_state');
    }

    if (!genesis.genesis_time) {
      throw new Error('Invalid genesis: missing genesis_time');
    }

    console.log('✅ Basic genesis structure validation passed');

    // Validate required modules based on enabled chains
    const config = this.configManager.getConfig();
    const requiredModules = [];

    if (config.chains.evm?.enabled) {
      requiredModules.push('assets', 'oracle', 'dogfood', 'delegation');
    }

    if (config.chains.bitcoin?.enabled) {
      // Bitcoin-specific modules (add as needed based on actual requirements)
      requiredModules.push('assets', 'delegation');
    }

    // Remove duplicates
    const uniqueModules = [...new Set(requiredModules)];

    let missingModules = 0;
    for (const module of uniqueModules) {
      if (!genesis.app_state[module]) {
        console.warn(`⚠ Warning: Expected module '${module}' not found in genesis app_state`);
        missingModules++;
      }
    }

    if (missingModules === 0 && uniqueModules.length > 0) {
      console.log(`✅ All ${uniqueModules.length} expected modules found in genesis`);
    } else if (uniqueModules.length > 0) {
      console.log(`⚠ Genesis validation completed with ${missingModules} missing expected modules`);
    }

    console.log('✅ Genesis structure validation completed');
  }

  async writeOutput(genesis, outputConfig) {
    const content = outputConfig.pretty ? JSON.stringify(genesis, null, 2) : JSON.stringify(genesis);
    const resolvedPath = path.isAbsolute(outputConfig.path) ? outputConfig.path : path.resolve(outputConfig.path);
    await fs.writeFile(resolvedPath, content, 'utf8');
  }

  async fileExists(filePath) {
    try {
      await fs.access(filePath);
      return true;
    } catch {
      return false;
    }
  }

  async mergeExistingFiles(config) {
    try {
      console.log('🔄 Loading existing JSON files for merge...');

      const genesisStates = [];

      // Define chain loaders for existing files
      const chainLoaders = [
        {
          name: 'EVM',
          enabled: config.chains.evm.enabled,
          envPathKey: 'EVM_GENESIS_PATH',
          defaultPath: config.chains.evm.tempOutput
        },
        {
          name: 'Bitcoin',
          enabled: config.chains.bitcoin.enabled,
          envPathKey: 'BITCOIN_GENESIS_PATH',
          defaultPath: config.chains.bitcoin.tempOutput
        }
        // Future chains can be added here:
        // {
        //   name: 'XRP',
        //   enabled: config.chains.xrp?.enabled || false,
        //   envPathKey: 'XRP_GENESIS_PATH',
        //   defaultPath: config.chains.xrp?.tempOutput
        // }
      ];

      // Load existing files for enabled chains
      for (const chain of chainLoaders) {
        if (chain.enabled) {
          const filePath = process.env[chain.envPathKey] || chain.defaultPath;
          const resolvedPath = path.isAbsolute(filePath) ? filePath : path.resolve(filePath);

          if (await this.fileExists(resolvedPath)) {
            const content = await fs.readFile(resolvedPath, 'utf8');
            const genesis = JSON.parse(content);
            genesisStates.push(genesis);
            console.log(`📄 Loading ${chain.name} genesis from: ${resolvedPath} ✓`);
          } else {
            console.warn(`⚠ ${chain.name} genesis file not found: ${resolvedPath}`);
          }
        }
      }

      if (genesisStates.length === 0) {
        throw new Error('No existing genesis files found to merge');
      }

      // Merge genesis states
      console.log('🔄 Merging existing genesis files...');
      const unifiedGenesis = this.merger.merge(genesisStates);



      // Write output
      await this.writeOutput(unifiedGenesis, config.output);

      console.log(`✅ Existing files merge completed successfully! Output written to: ${config.output.path}`);

      return unifiedGenesis;
    } catch (error) {
      console.error('❌ Existing files merge failed:', error.message);
      throw error;
    }
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
  node script/bootstrap/generate_unified.mjs

  # Generate with custom configuration
  node script/bootstrap/generate_unified.mjs --config=./my-config.json

  # Generate with environment variables
  UNIFIED_GENESIS_OUTPUT=./custom_genesis.json node script/bootstrap/generate_unified.mjs
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
export { GenesisStateMerger };
