const { ethers } = require("hardhat");
const fs = require('fs');
const path = require('path');
const { assert } = require("console");

const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
const DEPLOYED_CONTRACTS_PATH = path.join(__dirname, '../deployments/deployedContracts.json');

async function main() {
  console.log("Running fix for authorized gateways...");
  
  // 1. Read both gateway addresses from deployedContracts.json
  let deployedContracts = {};
  if (fs.existsSync(DEPLOYED_CONTRACTS_PATH)) {
    deployedContracts = JSON.parse(fs.readFileSync(DEPLOYED_CONTRACTS_PATH, 'utf8'));
  } else {
    console.error("Cannot find json file of deployed contracts");
    process.exit(1);
  }

  // Get both gateway addresses
  const imuachainGateway = deployedContracts.imuachain?.imuachainGateway;
  const utxoGateway = deployedContracts.imuachain?.utxoGateway;

  if (!imuachainGateway || !utxoGateway) {
    console.error("Missing gateway addresses in deployedContracts.json");
    console.log("imuachainGateway:", imuachainGateway);
    console.log("utxoGateway:", utxoGateway);
    process.exit(1);
  }

  console.log("Gateway addresses found:");
  console.log("- imuachainGateway:", imuachainGateway);
  console.log("- utxoGateway:", utxoGateway);

  // 2. Set both gateways as authorized
  try {
    const [deployer] = await ethers.getSigners();
    console.log("Using account:", deployer.address);

    // Connect to the Assets precompile
    const assetsPrecompile = await ethers.getContractAt("IAssets", ASSETS_PRECOMPILE_ADDRESS);
    
    // Update authorized gateways to include both gateways
    console.log("Authorizing both gateways...");
    const authTx = await assetsPrecompile.connect(deployer).updateAuthorizedGateways([
      imuachainGateway,
      utxoGateway
    ]);
    await authTx.wait();
    console.log("Authorization transaction completed.");

    // 3. Verify that both gateways are authorized
    const [imuaSuccess, isImuaAuthorized] = await assetsPrecompile.isAuthorizedGateway(imuachainGateway);
    const [utxoSuccess, isUtxoAuthorized] = await assetsPrecompile.isAuthorizedGateway(utxoGateway);

    console.log("\nVerification results:");
    console.log(`imuachainGateway authorized: ${isImuaAuthorized} (success: ${imuaSuccess})`);
    console.log(`utxoGateway authorized: ${isUtxoAuthorized} (success: ${utxoSuccess})`);

    // Assert both gateways are authorized
    assert(imuaSuccess && isImuaAuthorized, "imuachainGateway is not properly authorized");
    assert(utxoSuccess && isUtxoAuthorized, "utxoGateway is not properly authorized");
    
    console.log("\n✅ Both gateways are now properly authorized!");
  } catch (error) {
    console.error("❌ Failed to update authorized gateways:", error);
    process.exit(1);
  }
}

// Run the script
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = main;
