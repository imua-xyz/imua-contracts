/**
 * Script Name: Testnet Validator Airdrop Reward Calculator (Time-Weighted & Grouped)
 *
 * Description:
 * This script calculates airdrop rewards for validators across multiple testnet versions, 
 * considering the DURATION of each version as a weight factor. It aggregates voting power, 
 * categorizes validators (Internal vs External), and generates a detailed distribution report.
 *
 * Logic Flow:
 * 1. File Discovery: Recursively finds all genesis `.json` files.
 * 2. Sorting: Sorts genesis files chronologically by `genesis_time`.
 * 3. Period Calculation: Determines the duration of each period (from current genesis to next).
 * - **Crucial (`reward_end_time`):** Since a genesis file only marks the *start* of a chain, 
 * the script uses the configured `reward_end_time` to determine when the *final* testnet 
 * version ended. 
 * Duration of Last Period = `reward_end_time` - `last_genesis_time`.
 * 4. Distribution Loop: Iterates through each period to calculate rewards.
 * 5. Aggregation: Sums up rewards from all periods for each unique validator.
 * 6. Output: Generates a JSON report with summary stats, period breakdowns, and ranked validator lists.
 *
 * Validator Classification (Internal vs External):
 * The script automatically categorizes validators based on their Moniker (Name) using Regex:
 * - Internal: Names strictly matching `validator` or `operator` followed by numbers.
 * (e.g., "validator1", "Operator05", "Validator99"). Case-insensitive.
 * - External: All other validator names (e.g., "NodeGuru", "Stakely", "MyNode").
 *
 * Reward Distribution Logic:
 * 1. Time-Weighted Pool: 
 * The total reward pool is split into "Period Pools" based on the duration of that period 
 * relative to the total duration of all testnets.
 * Formula: PeriodPool = TotalGlobalReward * (PeriodDuration / TotalDuration)
 *
 * 2. Group Allocation (Internal vs External):
 * Within each period, the pool is split between Internal and External groups.
 * - IF `distinguish_internal_external` is TRUE: 
 * The split follows a fixed ratio defined in config (e.g., 20% Internal / 80% External),
 * ignoring the "raw voting power disparity" (the massive power gap between foundation 
 * nodes and community nodes).
 * - IF `distinguish_internal_external` is FALSE:
 * The split is purely proportional to the total voting power of each group.
 *
 * 3. Individual Distribution:
 * Inside a group, a validator's reward is proportional to their share of the group's voting power.
 * Formula: ValidatorReward = GroupPool * (ValidatorPower / TotalGroupPower)
 *
 * Corner Case Handling:
 * - Empty Groups: If `distinguish_internal_external` is TRUE but a period contains ONLY 
 * validators of one type (e.g., only Internal validators exist in the first genesis):
 * - The non-empty group receives 100% of that Period's pool.
 * - This prevents rewards from being "burned" or unallocated when a group is missing.
 * 
 * Usage:
 * 1. Dependencies: Ensure `bignumber.js` and `bech32` are installed.
 *    $ npm install bignumber.js bech32
 *
 * 2. Command:
 * $ node genesis_validator_rewards.mjs <genesis_dir> <config_dir> <output_dir>
 * * Example:
 * $ node genesis_validator_rewards.mjs ./genesis_files ./config ./output
 *
 * 3. Configuration (config.json inside <config_dir>):
 * {
 * "total_supply": "314159265",             // Total Token Supply
 * "genesis_validator_ratio": "0.02",        // % of supply for Genesis Airdrop
 * "distinguish_internal_external": true,    // Enable fixed ratio split?
 * "external_validator_ratio": "0.9",        // If true, External gets 90%, Internal gets 10%
 * "reward_end_time": "2025-12-01T00:00:00Z" // The end time of the final testnet period
 * }
 */

import fs from 'fs/promises';
import path from 'path';
import { BigNumber } from 'bignumber.js';
import { decode, encode } from 'bech32';

// Configure BigNumber
BigNumber.config({ DECIMAL_PLACES: 18, ROUNDING_MODE: BigNumber.ROUND_DOWN });

// Normalize any cosmos bech32 address to use the canonical 'im' prefix.
// This handles the rebranding from 'exo' prefix to 'im' prefix, ensuring
// that the same underlying address is treated as one entity.
function normalizeAddress(addr) {
  if (!addr) return addr;
  try {
    const { prefix, words } = decode(addr);
    if (prefix === 'im') return addr; // already canonical
    return encode('im', words);
  } catch (e) {
    console.warn(`[Warn] Failed to decode bech32 address: ${addr}, keeping as-is`);
    return addr;
  }
}

async function getAllGenesisFiles(dirPath) {
  let files = [];
  const items = await fs.readdir(dirPath, { withFileTypes: true });

  for (const item of items) {
    const fullPath = path.join(dirPath, item.name);
    if (item.isDirectory()) {
      files = files.concat(await getAllGenesisFiles(fullPath));
    } else if (item.isFile() && item.name.endsWith('.json')) {
      files.push(fullPath);
    }
  }
  return files;
}

async function parseGenesisFile(filePath) {
  console.log(`Processing: ${path.basename(filePath)}`);

  const content = await fs.readFile(filePath, 'utf-8');
  const json = JSON.parse(content);

  const genesisTimeStr = json.genesis_time;
  if (!genesisTimeStr) {
    throw new Error(`Missing 'genesis_time' in ${path.basename(filePath)}`);
  }
  const genesisTime = new Date(genesisTimeStr).getTime();
  if (Number.isNaN(genesisTime)) {
    throw new Error(`Invalid 'genesis_time' format in ${path.basename(filePath)}: ${genesisTimeStr}`);
  }

  let valSet = json.app_state?.dogfood?.val_set || json.app_state?.dogfood?.initial_val_set;
  if (!valSet) {
    valSet = [];
  }

  const operatorRecords = json.app_state?.operator?.operator_records || [];
  const consensusKeyToOpAddr = {};
  operatorRecords.forEach(record => {
    if (record.chains) {
      record.chains.forEach(chainInfo => {
        if (chainInfo.consensus_key) {
          consensusKeyToOpAddr[chainInfo.consensus_key.toLowerCase()] = normalizeAddress(record.operator_address);
        }
      });
    }
  });

  const operators = json.app_state?.operator?.operators || [];
  const opAddrToName = {};
  operators.forEach(op => {
    const earningsAddr = op.earnings_addr || op.operator_info?.earnings_addr;
    const metaInfo = op.operator_meta_info || op.operator_info?.operator_meta_info;
    if (earningsAddr) {
      const normalizedAddr = normalizeAddress(earningsAddr);
      opAddrToName[normalizedAddr] = metaInfo || "";
    }
  });

  return {
    fileName: path.basename(filePath),
    filePath,
    genesisTime,
    valSet,
    consensusKeyToOpAddr,
    opAddrToName
  };
}

async function calculateTimeWeightedRewards() {
  try {
    const args = process.argv.slice(2);
    if (args.length < 3) {
      console.error("Usage: node genesis_validator_rewards.mjs <genesis_dir> <config_dir> <output_dir>");
      process.exit(1);
    }
    const [genesisDir, configDir, outputDir] = args;

    const configPath = path.join(configDir, 'config.json');
    const configRaw = await fs.readFile(configPath, 'utf-8');
    const config = JSON.parse(configRaw);

    let endTimeMs = Date.now();
    if (config.reward_end_time) {
      endTimeMs = new Date(config.reward_end_time).getTime();
      if (Number.isNaN(endTimeMs)) {
        throw new Error(`Invalid 'reward_end_time' format in config: ${config.reward_end_time}`);
      }
    } else {
      console.warn("[Warn] 'reward_end_time' not found in config. Using current time.");
    }

    console.log("------------------------------------------------");
    console.log(`Starting Calculation...`);
    console.log(`Genesis Dir: ${genesisDir}`);
    console.log("------------------------------------------------");

    const filePaths = await getAllGenesisFiles(genesisDir);
    const parsedFiles = [];

    for (const fp of filePaths) {
      try {
        const data = await parseGenesisFile(fp);
        parsedFiles.push(data);
      } catch (e) {
        console.error(`Skipping file ${fp}: ${e.message}`);
      }
    }

    parsedFiles.sort((a, b) => a.genesisTime - b.genesisTime);

    if (parsedFiles.length === 0) throw new Error("No valid genesis files found.");
    if (endTimeMs <= parsedFiles[parsedFiles.length - 1].genesisTime) {
      throw new Error(`Configured reward_end_time is before or equal to the last genesis time.`);
    }

    const periods = [];
    let totalDurationMs = 0;

    for (let i = 0; i < parsedFiles.length; i++) {
      const current = parsedFiles[i];
      const nextTime = (i === parsedFiles.length - 1) ? endTimeMs : parsedFiles[i + 1].genesisTime;

      const duration = nextTime - current.genesisTime;
      if (duration <= 0) {
        const currentTs = new Date(current.genesisTime).toISOString();
        const nextTs = new Date(nextTime).toISOString();
        console.warn(`[Warn] Skipping period ${current.fileName}: non-positive duration (${duration}ms). ` +
          `current_genesis_time=${currentTs}, next_boundary=${nextTs}`);
        continue;
      }

      totalDurationMs += duration;

      periods.push({
        ...current,
        periodStart: current.genesisTime,
        periodEnd: nextTime,
        duration: duration
      });
    }

    const totalDurationDays = new BigNumber(totalDurationMs).div(1000 * 60 * 60 * 24);
    console.log(`Total Duration: ${totalDurationDays.toFixed(2)} days.`);

    if (!config.total_supply || !config.genesis_validator_ratio) {
      throw new Error("Config must include 'total_supply' and 'genesis_validator_ratio'.");
    }
    const totalSupply = new BigNumber(config.total_supply);
    const totalGlobalReward = totalSupply.times(config.genesis_validator_ratio);
    if (totalSupply.isNaN() || totalGlobalReward.isNaN() || totalSupply.lte(0) || totalGlobalReward.lte(0)) {
      throw new Error(`Invalid numeric config values: total_supply=${config.total_supply}, genesis_validator_ratio=${config.genesis_validator_ratio}`);
    }

    const globalValidatorMap = new Map();
    const periodsOutput = [];

    for (const period of periods) {
      const periodRatio = new BigNumber(period.duration).div(totalDurationMs);
      const periodPool = totalGlobalReward.times(periodRatio);

      const internalVals = [];
      const externalVals = [];
      let internalPower = new BigNumber(0);
      let externalPower = new BigNumber(0);
      let periodTotalPower = new BigNumber(0);

      // =========================================================
      // Phase 1: Collect and DEDUPLICATE validators by normalized
      // address within this period. After rebranding, the same
      // validator may appear with 'exo' and 'im' prefixes — these
      // must be treated as one entity. Normally each operator should
      // only participate once per period; duplicates are merged with
      // a warning.
      // =========================================================
      const periodValMap = new Map();

      for (const val of period.valSet) {
        if (!val.public_key) {
          console.log(`Skipping validator without public_key in ${period.fileName}`);
          continue;
        }
        const pubKey = val.public_key.toLowerCase();
        const power = new BigNumber(val.power);

        // Filter out invalid voting power values to prevent reward leaks and broken math.
        if (!power.isFinite() || power.isNaN() || power.lte(0)) {
          console.warn(`[Warn] Invalid validator power in ${period.fileName}: ${val.power}`);
          continue;
        }

        let opAddr = val.operator_acc_addr
          ? normalizeAddress(val.operator_acc_addr)
          : period.consensusKeyToOpAddr[pubKey]; // already normalized in parseGenesisFile
        if (!opAddr) {
          console.log(`Skipping validator without opAddr in ${period.fileName}: ${pubKey}`);
          continue;
        }

        const name = period.opAddrToName[opAddr] || "Unknown";

        if (periodValMap.has(opAddr)) {
          // Same normalized address already seen in this period — merge
          const existing = periodValMap.get(opAddr);
          existing.power = existing.power.plus(power);
          if (name !== "Unknown" && !existing.names.includes(name)) {
            existing.names.push(name);
          }
          console.log(`[Merge] Duplicate address in period ${period.fileName}: ${opAddr} — power merged`);
        } else {
          periodValMap.set(opAddr, {
            opAddr,
            names: name !== "Unknown" ? [name] : [],
            power,
          });
        }
      }

      // =========================================================
      // Phase 2: Classify deduplicated validators into Internal /
      // External and accumulate voting power.
      // =========================================================
      for (const [, valData] of periodValMap) {
        const allNames = valData.names.length > 0 ? valData.names : ["Unknown"];
        const name = allNames.join(',');

        // A validator is Internal only if ALL of its names match the internal pattern.
        const isInternal = allNames.every(n => /^(validator|operator)\d+$/i.test(n));
        const type = isInternal ? 'Internal' : 'External';

        const validatorObj = { opAddr: valData.opAddr, name, power: valData.power, type };

        if (isInternal) {
          internalVals.push(validatorObj);
          internalPower = internalPower.plus(valData.power);
        } else {
          externalVals.push(validatorObj);
          externalPower = externalPower.plus(valData.power);
        }
        periodTotalPower = periodTotalPower.plus(valData.power);
      }

      const hasInternal = internalVals.length > 0;
      const hasExternal = externalVals.length > 0;

      let internalPool = new BigNumber(0);
      let externalPool = new BigNumber(0);

      if (config.distinguish_internal_external) {
        const extRatio = new BigNumber(config.external_validator_ratio);
        if (extRatio.isNaN() || extRatio.lt(0) || extRatio.gt(1)) {
          throw new Error(`Invalid 'external_validator_ratio': ${config.external_validator_ratio}. Must be a number between 0 and 1.`);
        }
        // Handle Empty Groups with Fixed Ratio
        if (hasInternal && hasExternal) {
          // Normal case: Both groups exist, apply fixed ratio
          externalPool = periodPool.times(extRatio);
          internalPool = periodPool.minus(externalPool);
        } else if (hasInternal) {
          // Only Internal exists: They get 100% of this period's pool
          internalPool = periodPool;
          externalPool = new BigNumber(0);
        } else if (hasExternal) {
          // Only External exists: They get 100% of this period's pool
          externalPool = periodPool;
          internalPool = new BigNumber(0);
        }
        // If neither exist (empty period), pools remain 0
      } else {
        // Mode B: Proportional to Power (No fix needed, handles 0 naturally)
        if (!periodTotalPower.isZero()) {
          internalPool = periodPool.times(internalPower).div(periodTotalPower);
          externalPool = periodPool.minus(internalPool);
        }
      }

      if (internalPool.gt(0) && internalPower.isZero()) {
        console.warn(`[Leak Alert] Period ${period.fileName}: Internal pool has funds but TotalPower is 0. Rewards burned.`);
      }
      if (externalPool.gt(0) && externalPower.isZero()) {
        console.warn(`[Leak Alert] Period ${period.fileName}: External pool has funds but TotalPower is 0. Rewards burned.`);
      }

      // Distribute Function
      const distributeToGroup = (validators, pool, totalGroupPower) => {
        if (totalGroupPower.isZero()) return;
        validators.forEach(v => {
          const reward = pool.times(v.power).div(totalGroupPower);

          if (!globalValidatorMap.has(v.opAddr)) {
            globalValidatorMap.set(v.opAddr, {
              operator_address: v.opAddr,
              name: v.name,
              type: v.type,
              total_reward: new BigNumber(0),
              periods_active: 0
            });
          }
          const record = globalValidatorMap.get(v.opAddr);
          record.total_reward = record.total_reward.plus(reward);

          // Merge names: combine all unique names across periods (e.g. "operator1,validator1").
          const existingNames = record.name.split(',').filter(n => n && n !== 'Unknown');
          const newNames = v.name.split(',').filter(n => n && n !== 'Unknown');
          for (const n of newNames) {
            if (!existingNames.includes(n)) {
              existingNames.push(n);
            }
          }
          record.name = existingNames.length > 0 ? existingNames.join(',') : "Unknown";

          record.periods_active += 1;
        });
      };

      distributeToGroup(internalVals, internalPool, internalPower);
      distributeToGroup(externalVals, externalPool, externalPower);

      // =========================================================
      // PERIOD BREAKDOWN CONSTRUCTION
      // =========================================================
      periodsOutput.push({
        period_name: period.fileName,
        start_time: new Date(period.periodStart).toISOString(),
        end_time: new Date(period.periodEnd).toISOString(),
        duration_days: (period.duration / (1000 * 60 * 60 * 24)).toFixed(2),

        period_total_reward: periodPool.toFixed(18),
        percentage_of_total_reward: periodRatio.toString(),
        percentage_of_total_supply: periodPool.div(totalSupply).toString(),

        // --- POWER STATS ---
        total_voting_power: periodTotalPower.toString(),
        internal_voting_power: internalPower.toString(), // [Added]
        external_voting_power: externalPower.toString(), // [Added]

        // --- COUNTS ---
        active_validators_count: internalVals.length + externalVals.length,
        internal_validators_count: internalVals.length,
        external_validators_count: externalVals.length,

        // --- REWARD RATIOS ---
        internal_reward_percentage: periodPool.isZero() ? "0" : internalPool.div(periodPool).toString(),
        external_reward_percentage: periodPool.isZero() ? "0" : externalPool.div(periodPool).toString()
      });
    }

    // ------------------------------------------------------------------
    // Prepare & Enrich Results
    // ------------------------------------------------------------------

    const allResults = Array.from(globalValidatorMap.values()).map(v => ({
      operator_address: v.operator_address,
      name: v.name,
      type: v.type,
      periods_participated: v.periods_active,
      reward_amount: v.total_reward.toFixed(18),
      percentage_of_total_supply: v.total_reward.div(totalSupply).toString(),
      percentage_of_total_reward: v.total_reward.div(totalGlobalReward).toString()
    }));

    // Split Groups
    let internalList = allResults.filter(v => v.type === 'Internal');
    let externalList = allResults.filter(v => v.type === 'External');

    // Helper to sum rewards
    const sumRewards = (list) => list.reduce((acc, v) => acc.plus(new BigNumber(v.reward_amount)), new BigNumber(0));

    const internalTotalReward = sumRewards(internalList);
    const externalTotalReward = sumRewards(externalList);

    // Enrich with percentage_of_group_reward
    const enrichWithGroupStats = (list, groupTotal) => {
      return list.map(v => ({
        ...v,
        percentage_of_group_reward: groupTotal.isZero() ? "0" : new BigNumber(v.reward_amount).div(groupTotal).toString()
      }));
    };

    internalList = enrichWithGroupStats(internalList, internalTotalReward);
    externalList = enrichWithGroupStats(externalList, externalTotalReward);

    // Sort Descending
    const sortByReward = (a, b) => {
      const rA = new BigNumber(a.reward_amount);
      const rB = new BigNumber(b.reward_amount);
      return rB.comparedTo(rA);
    };

    internalList.sort(sortByReward);
    externalList.sort(sortByReward);

    const totalAllocated = internalTotalReward.plus(externalTotalReward);
    const remainder = totalGlobalReward.minus(totalAllocated);

    // ------------------------------------------------------------------
    // Console Output
    // ------------------------------------------------------------------
    console.log("------------------------------------------------");
    console.log("Rewards Summary (Time-Weighted):");
    console.log(`Total Duration:            ${totalDurationDays.toFixed(2)} days`);
    console.log(`Total Allocated Reward:    ${totalAllocated.toFixed(6)}`);
    console.log(`Internal Allocated Reward: ${internalTotalReward.toFixed(6)}`);
    console.log(`External Allocated Reward: ${externalTotalReward.toFixed(6)}`);
    console.log("------------------------------------------------");

    const printList = (list) => {
      list.forEach(v => {
        const formattedAmount = new BigNumber(v.reward_amount).toFixed(6);
        console.log(`- [${v.type}] ${v.name} (${v.operator_address}): ${formattedAmount}`);
      });
    };
    console.log("Internal Validators:");
    printList(internalList);
    console.log("\nExternal Validators:");
    printList(externalList);
    console.log("------------------------------------------------");

    // ------------------------------------------------------------------
    // JSON Output Construction
    // ------------------------------------------------------------------
    const outputData = {
      meta: {
        total_supply: totalSupply.toString(),
        total_reward_pool: totalGlobalReward.toString(),
        total_duration_days: totalDurationDays.toString(),
        config_used: config,
        generation_time: new Date().toISOString()
      },
      summary: {
        total_allocated: totalAllocated.toString(),
        remainder: remainder.toString(),
        internal: {
          allocated_reward: internalTotalReward.toString(),
          percentage_of_total_reward: totalGlobalReward.isZero() ? "0" : internalTotalReward.div(totalGlobalReward).toString()
        },
        external: {
          allocated_reward: externalTotalReward.toString(),
          percentage_of_total_reward: totalGlobalReward.isZero() ? "0" : externalTotalReward.div(totalGlobalReward).toString()
        }
      },
      periods_breakdown: periodsOutput,
      details: {
        internal_validators: internalList,
        external_validators: externalList
      }
    };

    if (!await fs.stat(outputDir).catch(() => false)) {
      await fs.mkdir(outputDir, { recursive: true });
    }
    const finalPath = path.join(outputDir, 'genesis_rewards_distribution.json');
    await fs.writeFile(finalPath, JSON.stringify(outputData, null, 2));

    console.log(`Success! Result written to: ${finalPath}`);

  } catch (error) {
    console.error('Error:', error.message, error.stack);
    process.exit(1);
  }
}

calculateTimeWeightedRewards();