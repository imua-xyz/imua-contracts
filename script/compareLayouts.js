const fs = require('fs');
const { getStorageUpgradeReport } = require('@openzeppelin/upgrades-core');

// Mapping of deployed and compiled file names
const fileMappings = [
  { before: 'Bootstrap.deployed.json', after: 'Bootstrap.compiled.json', mustExist: true },
  { before: 'ClientChainGateway.deployed.json', after: 'ClientChainGateway.compiled.json', mustExist: true },
  { before: 'Vault.deployed.json', after: 'Vault.compiled.json', mustExist: true },
  { before: 'RewardVault.deployed.json', after: 'RewardVault.compiled.json', mustExist: true },
  { before: 'ImuaCapsule.deployed.json', after: 'ImuaCapsule.compiled.json', mustExist: true },
  { before: 'ImuachainGateway.base.json', after: 'ImuachainGateway.compiled.json', mustExist: true },
  { before: 'Bootstrap.compiled.json', after: 'ClientChainGateway.compiled.json', mustExist: true },
];

// Loop through each mapping, load JSON files, and run the comparison
fileMappings.forEach(({ before, after, mustExist }) => {
  console.log(`🔍 Comparing ${before} and ${after}...`);

  try {
    // Ensure files exist
    const beforeExists = fs.existsSync(before);
    const afterExists = fs.existsSync(after);

    if (!beforeExists || !afterExists) {
      if (mustExist) {
        throw new Error(`❌ Required file(s) missing: ${beforeExists ? '' : before} ${afterExists ? '' : after}`);
      }
      console.log(`⚠️ Skipping: Missing file(s): ${beforeExists ? '' : before} ${afterExists ? '' : after}`);
      return;
    }

    // Load the JSON files
    const deployedData = JSON.parse(fs.readFileSync(before, 'utf8'));
    const compiledData = JSON.parse(fs.readFileSync(after, 'utf8'));

    // Run the storage upgrade comparison
    const report = getStorageUpgradeReport(deployedData, compiledData, { unsafeAllowCustomTypes: true });

    // Print the report if issues are found
    if (!report.ok) {
      console.log(`⚠️ Issues found in ${before} and ${after}:`);
      console.log(report.explain());
      process.exitCode = 1;
    } else {
      console.log(`✅ No issues detected between ${before} and ${after}.`);
    }
  } catch (error) {
    console.error(`❌ Error processing ${before} and ${after}: ${error.message}`);
    process.exitCode = 1;
  }
});
