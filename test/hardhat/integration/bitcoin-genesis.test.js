const { expect } = require('chai');
const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');
const { GenesisGenerator, generateGenesisState } = require('../../../script/bootstrap/bitcoin_genesis.ts');
const { toBech32, fromHex } = require('@cosmjs/encoding');
const BitcoinClient = require('../utils/bitcoin-utils');
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe('Bitcoin Bootstrap Genesis Generation', function() {
  // Test configuration
  const TEST_CONFIG = {
    BTC_ESPLORA_API_URL: process.env.BITCOIN_ESPLORA_API_URL,
    BTC_FAUCET_PRIVATE_KEY: process.env.BITCOIN_FAUCET_PRIVATE_KEY,
    NUM_VALIDATORS: 5,
    NUM_STAKERS: 10,
    NUM_STAKES: 1,
    OUTPUT_PATH: path.join(__dirname, 'test_genesis.json'),
    STAKE_AMOUNT: 1000000n, // 0.01 BTC in satoshis
    MIN_CONFIRMATIONS: 1,
    MIN_AMOUNT: 546
  };

  let deployer;
  let validators = [];
  let validatorsBech32 = [];
  let bootstrapContract;
  let stakingTxids = [];
  let bitcoinClient;
  let btcVault;

  // Skip if not running in CI or if BITCOIN_E2E flag is not set
  before(async function() {
    if (!TEST_CONFIG.BTC_ESPLORA_API_URL || !TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY) {
      console.log('Missing required environment variables for Bitcoin tests.');
      this.skip();
      return;
    }

    // Initialize Bitcoin client
    bitcoinClient = new BitcoinClient({
      esploraApiUrl: TEST_CONFIG.BTC_ESPLORA_API_URL,
      faucetPrivateKey: TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY,
      txFee: 1000,
      dustThreshold: 546
    });

    // generate random btc vault address
    btcVault = bitcoinClient.generateKeyPair().address;
    console.log("Generate random vault address:", btcVault);

    // Get signers
    const signers = await ethers.getSigners();
    deployer = signers[0];
    validators = signers.slice(1, TEST_CONFIG.NUM_VALIDATORS + 1);
    for (let i = 0; i < validators.length; i++) {
      const validator = validators[i];
      validatorsBech32.push(toBech32('im', fromHex(validator.address.slice(2))));
    }

    // First deploy NetworkConstants library
    console.log('Deploying NetworkConstants library...');
    const NetworkConstants = await ethers.getContractFactory('NetworkConstants');
    const networkConstants = await NetworkConstants.deploy();
    await networkConstants.waitForDeployment();
    console.log(`NetworkConstants library deployed at: ${networkConstants.target}`);

    // Deploy EndpointMock
    console.log("Deploying Endpoint mock...");
    const Endpoint = await ethers.getContractFactory("NonShortCircuitEndpointV2Mock");
    const endpoint = await Endpoint.deploy(2, deployer.address);
    await endpoint.waitForDeployment();
    console.log(`Endpoint deployed at: ${endpoint.target}`);

    // Deploy Bootstrap contract with library linking
    console.log('Deploying Bootstrap contract...');
    const Bootstrap = await ethers.getContractFactory('Bootstrap', {
      libraries: {
        NetworkConstants: networkConstants.target
      }
    });
    
    const bootstrapLogic = await Bootstrap.deploy(
      endpoint.target,
      {
        imuachainChainId: 1,
        beaconOracleAddress: "0x0000000000000000000000000000000000000001",
        vaultBeacon: "0x0000000000000000000000000000000000000002",
        imuaCapsuleBeacon: "0x0000000000000000000000000000000000000003",
        beaconProxyBytecode: "0x0000000000000000000000000000000000000004",
        networkConfig: ethers.ZeroAddress
      }
    );
    await bootstrapLogic.waitForDeployment();
    console.log(`Bootstrap contract logic deployed at: ${bootstrapLogic.target}`);

    const ProxyAdmin = await ethers.getContractFactory("ProxyAdmin");
    const proxyAdmin = await ProxyAdmin.deploy();
    await proxyAdmin.waitForDeployment();
    console.log(`ProxyAdmin deployed at: ${proxyAdmin.target}`);

    const currentTimestamp = await time.latest();
    console.log(`Current timestamp: ${currentTimestamp}`);

    const initializeArgs = await generateBootstrapInitData();

    const Proxy = await ethers.getContractFactory("TransparentUpgradeableProxy");
    const proxy = await Proxy.deploy(
        bootstrapLogic.target,
        "0x000000000000000000000000000000000000000B",
        Bootstrap.interface.encodeFunctionData('initialize', initializeArgs)
    );
    await proxy.waitForDeployment();

    bootstrapContract = await bootstrapLogic.attach(proxy.target)

    // Register validators
    for (let i = 0; i < validators.length; i++) {
      const validator = validators[i];
      const validatorBech32 = validatorsBech32[i];
      await bootstrapContract.connect(validator).registerValidator(
        validatorBech32,
        `Validator ${i}`,
        [
          0n,
          BigInt(1e18),
          BigInt(1e18)
        ],
        '0x' + '00'.repeat(31) + `0${i+1}`
      );
      console.log(`Registered validator ${i}: ${await validator.getAddress()}, ${validatorBech32}`);
    }
  });

  it('should generate a valid genesis file', async function() {
    // Send Bitcoin staking transactions
    stakingTxids = await sendBitcoinStakingTransactions();    

    // Wait for confirmations
    for (const txid of stakingTxids) {
      await bitcoinClient.waitForConfirmation(txid, 1);
    }

    const generator = new GenesisGenerator(
      btcVault,
      TEST_CONFIG.BTC_ESPLORA_API_URL,
      bootstrapContract,
      TEST_CONFIG.MIN_CONFIRMATIONS,
      TEST_CONFIG.MIN_AMOUNT
    );
  
    const stakes = await generator.generateGenesisStakes();
    console.log(`Found ${stakes.length} stakes`);
    const genesisState = await generateGenesisState(stakes);
  
    await fs.promises.writeFile(
      TEST_CONFIG.OUTPUT_PATH,
      JSON.stringify(genesisState, null, 2)
    );
  
    console.log(`Generated genesis state with ${stakes.length} valid stakes`);
    console.log(`Written to ${TEST_CONFIG.OUTPUT_PATH}`);

    // Verify the generated genesis file exists
    expect(fs.existsSync(TEST_CONFIG.OUTPUT_PATH)).to.be.true;

    // Parse and validate the genesis file
    const genesisData = JSON.parse(fs.readFileSync(TEST_CONFIG.OUTPUT_PATH, 'utf8'));
    
    // Basic validation
    expect(genesisData).to.have.property('app_state');
    expect(genesisData.app_state).to.have.property('assets');
    expect(genesisData.app_state).to.have.property('delegation');
    expect(genesisData.app_state).to.have.property('dogfood');
    expect(genesisData.app_state).to.have.property('oracle');

    // Validate assets
    const assets = genesisData.app_state.assets;
    expect(assets.deposits.length).to.be.greaterThan(0);
    expect(assets.operator_assets.length).to.be.greaterThan(0);

    // Validate delegation
    const delegation = genesisData.app_state.delegation;
    expect(delegation.associations).to.be.an('array');
    expect(delegation.delegation_states.length).to.be.greaterThan(0);
    expect(delegation.stakers_by_operator.length).to.be.greaterThan(0);

    // Validate dogfood
    const dogfood = genesisData.app_state.dogfood;
    expect(dogfood.val_set.length).to.be.greaterThan(0);
    expect(dogfood.last_total_power).to.not.equal('0');

    // Validate oracle
    const oracle = genesisData.app_state.oracle;
    expect(oracle.staker_list_assets.length).to.be.greaterThan(0);
    expect(oracle.staker_infos_assets.length).to.be.greaterThan(0);

    console.log('Genesis generation test completed successfully!');
    console.log(`Genesis file written to: ${TEST_CONFIG.OUTPUT_PATH}`);
    console.log(`Number of stakes: ${stakingTxids.length}`);
    console.log(`Number of validators: ${validators.length}`);
  }).timeout(300000); // 5 minutes timeout

  // Helper function to send Bitcoin staking transactions
  async function sendBitcoinStakingTransactions() {
    console.log('Sending Bitcoin staking transactions...');
    const txids = [];
    
    // Generate a fixed number of staker wallets
    const stakerWallets = [];
    for (let i = 0; i < TEST_CONFIG.NUM_STAKERS; i++) {
      stakerWallets.push(bitcoinClient.generateKeyPair());
      console.log(`Generated staker wallet ${i}: ${stakerWallets[i].address}`);
    }
    
    // Send a fixed number of staking transactions
    for (let i = 0; i < TEST_CONFIG.NUM_STAKES; i++) {
      // Randomly select a staker wallet
      const stakerIndex = Math.floor(Math.random() * stakerWallets.length);
      const stakerWallet = stakerWallets[stakerIndex];
      
      // Randomly select a validator
      const validatorIndex = Math.floor(Math.random() * validators.length);
      const validator = validators[validatorIndex];
      const validatorAddress = toBech32('im', fromHex((await validator.getAddress()).slice(2)));
      
      // Create staking transaction
      const txid = await bitcoinClient.createStakingTransaction(
        stakerWallet.privateKey,
        btcVault,
        TEST_CONFIG.STAKE_AMOUNT,
        validatorAddress
      );
      
      txids.push(txid);
      console.log(`Sent staking transaction ${i+1}/${TEST_CONFIG.NUM_STAKES} with txid ${txid} from staker ${stakerIndex} to validator ${validatorIndex} (${validatorAddress})`);
    }
    
    console.log(`Total staking transactions sent: ${txids.length}`);
    return txids;
  }

  // Helper function to generate valid initialization data for Bootstrap
  function generateBootstrapInitData() {
    // Mock addresses for initialization
    const mockOwner = deployer.address;
    const spawnTime = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60; // 1 week from now
    const offsetDuration = 2; // 2 seconds
    
    // Whitelist tokens and TVL limits
    const whitelistTokens = [];
    const tvlLimits = [];
    
    // Mock proxy admin
    const mockProxyAdmin = "0x0000000000000000000000000000000000000009";
    
    // Mock client chain gateway logic
    const mockClientGatewayLogic = "0x000000000000000000000000000000000000000A";
    
    // Mock client chain initialization data
    // This should be the encoded call to ClientChainGateway.initialize(owner)
    const clientChainInitData = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address'],
      [mockOwner]
    );
    
    // These are the raw arguments for the initialize function
    const initializeArgs = [
      mockOwner,
      spawnTime,
      offsetDuration,
      whitelistTokens,
      tvlLimits,
      mockProxyAdmin,
      mockClientGatewayLogic,
      clientChainInitData
    ];

    console.log('initializeArgs', initializeArgs);
    
    return initializeArgs;
  }

});
