const { ethers } = require("hardhat");
const fs = require('fs');
const path = require('path');
const { assert } = require("console");

const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
const CREATE2_DESTINATION = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const CREATE3_DESTINATION = "0x6aA3D87e99286946161dCA02B97C5806fC5eD46F";
const CREATE3_SALT = ethers.zeroPadValue("0x", 32);
const CREATE3_INIT_CODE = "0x608060405234801561001057600080fd5b5061063b806100206000396000f3fe6080604052600436106100295760003560e01c806350f1c4641461002e578063cdcb760a14610077575b600080fd5b34801561003a57600080fd5b5061004e610049366004610489565b61008a565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b61004e6100853660046104fd565b6100ee565b6040517fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606084901b166020820152603481018290526000906054016040516020818303038152906040528051906020012091506100e78261014c565b9392505050565b6040517fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003360601b166020820152603481018390526000906054016040516020818303038152906040528051906020012092506100e78383346102b2565b604080518082018252601081527f67363d3d37363d34f03d5260086018f30000000000000000000000000000000060209182015290517fff00000000000000000000000000000000000000000000000000000000000000918101919091527fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003060601b166021820152603581018290527f21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f60558201526000908190610228906075015b6040516020818303038152906040528051906020012090565b6040517fd69400000000000000000000000000000000000000000000000000000000000060208201527fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606083901b1660228201527f010000000000000000000000000000000000000000000000000000000000000060368201529091506100e79060370161020f565b6000806040518060400160405280601081526020017f67363d3d37363d34f03d5260086018f30000000000000000000000000000000081525090506000858251602084016000f5905073ffffffffffffffffffffffffffffffffffffffff811661037d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601160248201527f4445504c4f594d454e545f4641494c454400000000000000000000000000000060448201526064015b60405180910390fd5b6103868661014c565b925060008173ffffffffffffffffffffffffffffffffffffffff1685876040516103b091906105d6565b60006040518083038185875af1925050503d80600081146103ed576040519150601f19603f3d011682016040523d82523d6000602084013e6103f2565b606091505b50509050808015610419575073ffffffffffffffffffffffffffffffffffffffff84163b15155b61047f576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601560248201527f494e495449414c495a4154494f4e5f4641494c454400000000000000000000006044820152606401610374565b5050509392505050565b6000806040838503121561049c57600080fd5b823573ffffffffffffffffffffffffffffffffffffffff811681146104c057600080fd5b946020939093013593505050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6000806040838503121561051057600080fd5b82359150602083013567ffffffffffffffff8082111561052f57600080fd5b818501915085601f83011261054357600080fd5b813581811115610555576105556104ce565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561059b5761059b6104ce565b816040528281528860208487010111156105b457600080fd5b8260208601602083013760006020848301015280955050505050509250929050565b6000825160005b818110156105f757602081860181015185830152016105dd565b50600092019182525091905056fea2646970667358221220fd377c185926b3110b7e8a544f897646caf36a0e82b2629de851045e2a5f937764736f6c63430008100033";
const DEPLOYED_CONTRACTS_PATH = path.join(__dirname, '../deployments/deployedContracts.json');
const REQUIRED_PROOFS = 3;

async function main() {
  // Load existing deployments if any
  let deployedContracts = {};
  if (fs.existsSync(DEPLOYED_CONTRACTS_PATH)) {
    deployedContracts = JSON.parse(fs.readFileSync(DEPLOYED_CONTRACTS_PATH, 'utf8'));
  } else {
    console.log("Cannot find json file of deployed contracts")
  }

  // Check if contracts are already deployed
  if (deployedContracts.imuachain?.utxoGateway) {
    const utxoGatewayCode = await ethers.provider.getCode(deployedContracts.imuachain.utxoGateway);
    if (utxoGatewayCode !== "0x") {
      console.log("Using existing UTXOGateway deployment:", deployedContracts.imuachain.utxoGateway);
      return;
    }
  }

  const [deployer, owner, witness1] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // transfer 0.1 ether gas tokens to all accounts
  for (const account of [deployer, owner, witness1]) {
      const tx = await deployer.sendTransaction({
          to: account.address,
          value: ethers.parseEther("0.1"),
      });
      await tx.wait();
      assert(await ethers.provider.getBalance(account.address) > 0, "no enough balance for account")
  }

  try {

    // Check CREATE2 factory
    const create2Code = await ethers.provider.getCode(CREATE2_DESTINATION);
    if (create2Code === "0x") {
      throw new Error("CREATE2 factory must be predeployed at " + CREATE2_DESTINATION);
    }

    // Check/Deploy CREATE3 factory
    const create3Code = await ethers.provider.getCode(CREATE3_DESTINATION);
    if (create3Code === "0x") {
      console.log("Deploying CREATE3 factory...");

      // Use low-level call to deploy CREATE3 factory
      const tx = await deployer.sendTransaction({
        to: CREATE2_DESTINATION,
        data: ethers.concat([CREATE3_SALT, CREATE3_INIT_CODE])
      });

      await tx.wait();

      // Verify deployment
      const newCode = await ethers.provider.getCode(CREATE3_DESTINATION);
      if (newCode === "0x") {
        throw new Error("Failed to deploy CREATE3 factory");
      }

      console.log("CREATE3 factory deployed to:", CREATE3_DESTINATION);
    }

    // Deploy UTXOGateway Logic
    console.log("\nDeploying UTXOGateway Logic...");
    const UTXOGatewayFactory = await ethers.getContractFactory("UTXOGateway");
    const utxoGatewayLogic = await UTXOGatewayFactory.connect(deployer).deploy();
    await utxoGatewayLogic.waitForDeployment();
    console.log("UTXOGateway Logic deployed to:", await utxoGatewayLogic.getAddress());

    // Get or Deploy ProxyAdmin
    let proxyAdmin;
    if (deployedContracts.imuachain?.imuachainProxyAdmin) {
      console.log("\nUsing existing ProxyAdmin at:", deployedContracts.imuachain.imuachainProxyAdmin);
      const ProxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
      proxyAdmin = ProxyAdminFactory.attach(deployedContracts.imuachain.imuachainProxyAdmin);
    } else {
      console.log("\nDeploying new ProxyAdmin...");
      const ProxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
      proxyAdmin = await ProxyAdminFactory.connect(deployer).deploy();
      await proxyAdmin.waitForDeployment();
      console.log("ProxyAdmin deployed to:", await proxyAdmin.getAddress());
    }

    // Deploy Proxy using CREATE3
    console.log("\nDeploying UTXOGateway Proxy via CREATE3...");

    // Generate deterministic salt for UTXOGateway
    const PROXY_SALT = ethers.id("UTXOGateway_v2");

    // Prepare proxy creation code with constructor args
    const ProxyFactory = await ethers.getContractFactory("TransparentUpgradeableProxy");
    const proxyCreationCode = ethers.concat([
      ProxyFactory.bytecode,
      ProxyFactory.interface.encodeDeploy([
        await utxoGatewayLogic.getAddress(),
        await proxyAdmin.getAddress(),
        UTXOGatewayFactory.interface.encodeFunctionData("initialize", [
          owner.address,
          [witness1.address],
          REQUIRED_PROOFS
        ])
      ])
    ]);

    // Deploy via CREATE3
    const create3FF = await ethers.getContractFactory("CREATE3Factory");
    const create3Factory = create3FF.attach(CREATE3_DESTINATION);

    // Check if already deployed
    const predictedAddress = await create3Factory.getDeployed(deployer.address, PROXY_SALT);
    console.log("Predicted UTXOGateway address:", predictedAddress);

    if ((await ethers.provider.getCode(predictedAddress)) === "0x") {
      const deployTx = await create3Factory.connect(deployer).deploy(PROXY_SALT, proxyCreationCode);
      await deployTx.wait();
      console.log("UTXOGateway deployed to:", predictedAddress);
    } else {
      console.log("UTXOGateway already deployed at:", predictedAddress);
    }

    // Get UTXOGateway interface at the predicted address
    const utxoGateway = UTXOGatewayFactory.attach(predictedAddress);

    // 4. Set UTXOGateway as authorized in Assets precompile
    console.log("\nAuthorizing UTXOGateway in Assets precompile...");
    const assetsPrecompile = await ethers.getContractAt("IAssets", ASSETS_PRECOMPILE_ADDRESS);
    
    // Check for existing authorized gateways first
    const imuachainGateway = deployedContracts.imuachain?.imuachainGateway;
    const authorizedGateways = [await utxoGateway.getAddress()];

    // Add the imuachainGateway to the list if it exists
    if (imuachainGateway) {
      console.log("Found existing imuachainGateway:", imuachainGateway);
      console.log("Adding it to the authorized gateways list to maintain its authorization");
      authorizedGateways.push(imuachainGateway);
    }

    console.log("Setting authorized gateways:", authorizedGateways);
    const authTx = await assetsPrecompile.connect(deployer).updateAuthorizedGateways(authorizedGateways);
    await authTx.wait();

    // 5. Activate staking for Bitcoin and XRP
    console.log("\nActivating staking for Bitcoin...");
    const activateBtcTx = await utxoGateway.connect(owner).activateStakingForClientChain(1); // 1 for Bitcoin
    await activateBtcTx.wait();

    console.log("\nActivating staking for XRP...");
    const activateXrpTx = await utxoGateway.connect(owner).activateStakingForClientChain(2); // 2 for XRP
    await activateXrpTx.wait();

    // 6. Verify Bitcoin and XRP setup with assertions
    console.log("\nVerifying setup...");
    const [utxoAuthSuccess, isUtxoAuthorized] = await assetsPrecompile.isAuthorizedGateway(await utxoGateway.getAddress());
    
    // Assert the setup is correct
    assert(utxoAuthSuccess && isUtxoAuthorized, "UTXOGateway is not properly authorized");
    
    // Also verify imuachainGateway authorization if it exists
    if (imuachainGateway) {
      const [imuaAuthSuccess, isImuaAuthorized] = await assetsPrecompile.isAuthorizedGateway(imuachainGateway);
      assert(imuaAuthSuccess && isImuaAuthorized, "IMUAChain Gateway is not properly authorized");
      console.log("✅ Both UTXOGateway and IMUAChain Gateway are authorized");
    }
    
    // Verify chain registrations
    const [bitcoinChainSuccess, isBitcoinChainRegistered] = await assetsPrecompile.isRegisteredClientChain(1);
    const [XRPChainSuccess, isXRPChainRegistered] = await assetsPrecompile.isRegisteredClientChain(2);

    assert(bitcoinChainSuccess && isBitcoinChainRegistered, "Bitcoin chain is not properly registered");
    assert(XRPChainSuccess && isXRPChainRegistered, "XRPL chain is not properly registered");

    const actualRequiredProofs = await utxoGateway.requiredProofs();
    assert(actualRequiredProofs == REQUIRED_PROOFS, "Required proofs mismatch");

    const isAuthorizedWitness = await utxoGateway.authorizedWitnesses(witness1.address);
    assert(isAuthorizedWitness, "Witness is not authorized");
    console.log("✅ All assertions passed");

    // 7. Save deployment information
    const deploymentInfo = {
      network: network.name,
      utxoGatewayProxy: await utxoGateway.getAddress(),
      utxoGatewayLogic: await utxoGatewayLogic.getAddress(),
      proxyAdmin: await proxyAdmin.getAddress(),
      owner: owner.address,
      witnesses: [witness1.address],
      requiredProofs: 3,
      isAuthorized: isUtxoAuthorized,
      isBitcoinChainRegistered,
      isXRPChainRegistered,
      timestamp: new Date().toISOString()
    };

    // Save detailed deployment info
    const deploymentsDir = path.join(__dirname, '../deployments');
    if (!fs.existsSync(deploymentsDir)) {
      fs.mkdirSync(deploymentsDir);
    }
    fs.writeFileSync(
      path.join(deploymentsDir, `utxo-gateway-${network.name}.json`),
      JSON.stringify(deploymentInfo, null, 2)
    );

    // Update deployedContracts.json
    if (!deployedContracts.imuachain) {
        deployedContracts.imuachain = {};
    }

    deployedContracts.imuachain.utxoGateway = await utxoGateway.getAddress();
    deployedContracts.imuachain.utxoGatewayLogic = await utxoGatewayLogic.getAddress();

    fs.writeFileSync(
      DEPLOYED_CONTRACTS_PATH,
      JSON.stringify(deployedContracts, null, 2)
    );

    console.log("\nDeployment Summary:");
    console.log("-------------------");
    console.log(deploymentInfo);
    console.log("\n✅ Deployment successful and verified!");

  } catch (error) {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  }
}

// Use CommonJS exports
module.exports = main;

// Only run if script is run directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
