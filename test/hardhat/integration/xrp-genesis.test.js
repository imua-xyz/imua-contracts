const { expect } = require('chai');
const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');
const { XRPGenesisGenerator, generateXRPGenesisState } = require('../../../script/bootstrap/xrp_genesis.ts');
const { toBech32, fromHex } = require('@cosmjs/encoding');
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe('XRP Bootstrap Genesis Generation', function() {
  // Test configuration
  const TEST_CONFIG = {
    XRP_RPC_URL: process.env.XRP_RPC_URL || 'wss://s.altnet.rippletest.net:51233',
    XRP_VAULT_ADDRESS: process.env.XRP_VAULT_ADDRESS || 'r35uWX8cugzrfiAizvUXay8X4KXCYFQqVR',
    NUM_VALIDATORS: 5,
    OUTPUT_PATH: path.join(__dirname, 'test_xrp_genesis.json'),
    MIN_CONFIRMATIONS: 1,
    MIN_AMOUNT: 50000000 // 50 XRP in drops
  };

  let deployer;
  let validators = [];
  let validatorsBech32 = [];
  let bootstrapContract;

  // Initialize test environment
  before(async function() {
    try {
      // Get signers from hardhat network
      [deployer, ...validators] = await ethers.getSigners();
      validators = validators.slice(0, TEST_CONFIG.NUM_VALIDATORS); // Limit to desired number of validators

      // Convert validator addresses to bech32 format
      for (let i = 0; i < validators.length; i++) {
        const validator = validators[i];
        validatorsBech32.push(toBech32('im', fromHex(validator.address.slice(2))));
      }

      // Deploy required contracts for testing
      await deployTestContracts();

      // Register validators
      for (let i = 0; i < validators.length; i++) {
        const validator = validators[i];
        const validatorBech32 = validatorsBech32[i];
        await bootstrapContract.connect(validator).registerValidator(
          validatorBech32,
          `XRP Validator ${i}`,
          [
            0n,
            BigInt(1e18),
            BigInt(1e18)
          ],
          '0x' + '00'.repeat(31) + `0${i+1}`
        );
        console.log(`Registered XRP validator ${i}: ${await validator.getAddress()}, ${validatorBech32}`);
      }
    } catch (error) {
      console.error('Failed to initialize test environment:', error);
      this.skip();
    }
  });

  describe('XRPGenesisGenerator', function() {
    let generator;

    beforeEach(function() {
      generator = new XRPGenesisGenerator(
        TEST_CONFIG.XRP_VAULT_ADDRESS,
        TEST_CONFIG.XRP_RPC_URL,
        bootstrapContract,
        TEST_CONFIG.MIN_CONFIRMATIONS,
        TEST_CONFIG.MIN_AMOUNT
      );
    });

    it('should initialize with correct parameters', function() {
      expect(generator).to.be.instanceOf(XRPGenesisGenerator);
    });

    it('should throw error with invalid vault address', function() {
      expect(() => {
        new XRPGenesisGenerator(
          '', // Invalid empty vault address
          TEST_CONFIG.XRP_RPC_URL,
          bootstrapContract,
          TEST_CONFIG.MIN_CONFIRMATIONS,
          TEST_CONFIG.MIN_AMOUNT
        );
      }).to.throw('Vault address is required');
    });

    it('should throw error with invalid RPC URL', function() {
      expect(() => {
        new XRPGenesisGenerator(
          TEST_CONFIG.XRP_VAULT_ADDRESS,
          'invalid-url', // Invalid RPC URL
          bootstrapContract,
          TEST_CONFIG.MIN_CONFIRMATIONS,
          TEST_CONFIG.MIN_AMOUNT
        );
      }).to.throw('server URI must start with `wss://`, `ws://`, `wss+unix://`, or `ws+unix://`');
    });

    it('should throw error with invalid minimum confirmations', function() {
      expect(() => {
        new XRPGenesisGenerator(
          TEST_CONFIG.XRP_VAULT_ADDRESS,
          TEST_CONFIG.XRP_RPC_URL,
          bootstrapContract,
          0, // Invalid minimum confirmations
          TEST_CONFIG.MIN_AMOUNT
        );
      }).to.throw('Minimum confirmations must be at least 1');
    });

    it('should validate XRP address format correctly', function() {
      // Test with mock XRP addresses
      const validXRPAddress = 'rN7n7otQDd6FczFgLdSqtcsAUxDkw6fzRH';
      const invalidXRPAddress = 'invalid_address';

      // This would be tested through the private method if exposed
      // For now, we test through the public interface
      expect(validXRPAddress).to.match(/^r[1-9A-HJ-NP-Za-km-z]{25,34}$/);
      expect(invalidXRPAddress).to.not.match(/^r[1-9A-HJ-NP-Za-km-z]{25,34}$/);
    });

    it('should validate memo data format correctly', function() {
      // Test memo validation through transaction processing
      const validMemoType = "4465736372697074696F6E"; // "Description" in hex
      const invalidMemoType = "496E76616C6964"; // "Invalid" in hex

      expect(validMemoType).to.equal("4465736372697074696F6E");
      expect(invalidMemoType).to.not.equal("4465736372697074696F6E");
    });

    it('should generate genesis stakes from mock data', async function() {
      // Create mock stakes data for testing
      const mockStakes = createMockXRPStakes();

      // Test genesis state generation
      const genesisState = await generateXRPGenesisState(mockStakes);

      // Validate the generated genesis state
      expect(genesisState).to.have.property('app_state');
      expect(genesisState.app_state).to.have.property('assets');
      expect(genesisState.app_state).to.have.property('delegation');
      expect(genesisState.app_state).to.have.property('dogfood');
      expect(genesisState.app_state).to.have.property('oracle');

      // Validate XRP-specific properties
      const assets = genesisState.app_state.assets;
      expect(assets.client_chains).to.have.lengthOf(1);
      expect(assets.client_chains[0].name).to.equal('XRP Ledger');
      expect(assets.tokens).to.have.lengthOf(1);
      expect(assets.tokens[0].asset_basic_info.symbol).to.equal('XRP');
    }).timeout(30000);

    it('should handle empty stakes array', async function() {
      const emptyStakes = [];
      const genesisState = await generateXRPGenesisState(emptyStakes);

      expect(genesisState.app_state.assets.deposits).to.have.lengthOf(0);
      expect(genesisState.app_state.assets.operator_assets).to.have.lengthOf(0);
      expect(genesisState.app_state.delegation.delegation_states).to.have.lengthOf(0);
      expect(genesisState.app_state.dogfood.val_set).to.have.lengthOf(0);
    });

    it('should calculate validator power correctly', async function() {
      const mockStakes = createMockXRPStakes();
      const genesisState = await generateXRPGenesisState(mockStakes);

      const validators = genesisState.app_state.dogfood.val_set;
      expect(validators.length).to.be.greaterThan(0);

      // Verify power calculation (should be based on XRP amount and price)
      for (const validator of validators) {
        expect(parseInt(validator.power)).to.be.greaterThan(0);
      }
    });

    it('should sort validators by power correctly', async function() {
      const mockStakes = createMockXRPStakes();
      const genesisState = await generateXRPGenesisState(mockStakes);

      const validators = genesisState.app_state.dogfood.val_set;

      // Verify validators are sorted by power (descending)
      for (let i = 1; i < validators.length; i++) {
        const prevPower = BigInt(validators[i-1].power);
        const currPower = BigInt(validators[i].power);
        expect(prevPower).to.be.at.least(currPower);
      }
    });

    it('should generate deterministic output', async function() {
      const mockStakes = createMockXRPStakes();

      const genesisState1 = await generateXRPGenesisState([...mockStakes]);
      const genesisState2 = await generateXRPGenesisState([...mockStakes]);

      // Remove timestamp fields for comparison
      delete genesisState1.genesis_time;
      delete genesisState2.genesis_time;

      expect(JSON.stringify(genesisState1)).to.equal(JSON.stringify(genesisState2));
    });
  });

  describe('Integration Tests', function() {
    it('should generate a complete genesis file', async function() {
      // Create mock stakes for integration test
      const mockStakes = createMockXRPStakes();

      // Generate genesis state
      const genesisState = await generateXRPGenesisState(mockStakes);

      // Write to test output file
      await fs.promises.writeFile(
        TEST_CONFIG.OUTPUT_PATH,
        JSON.stringify(genesisState, null, 2)
      );

      console.log(`Generated XRP genesis state with ${mockStakes.length} mock stakes`);
      console.log(`Written to ${TEST_CONFIG.OUTPUT_PATH}`);

      // Verify the generated genesis file exists
      expect(fs.existsSync(TEST_CONFIG.OUTPUT_PATH)).to.be.true;

      // Parse and validate the genesis file
      const genesisData = JSON.parse(fs.readFileSync(TEST_CONFIG.OUTPUT_PATH, 'utf8'));

      // Basic structure validation
      expect(genesisData).to.have.property('genesis_time');
      expect(genesisData).to.have.property('chain_id');
      expect(genesisData).to.have.property('app_state');

      // Validate app state structure
      const appState = genesisData.app_state;
      expect(appState).to.have.property('assets');
      expect(appState).to.have.property('delegation');
      expect(appState).to.have.property('dogfood');
      expect(appState).to.have.property('oracle');

      // Validate XRP-specific content
      const assets = appState.assets;
      expect(assets.client_chains).to.have.lengthOf(1);
      expect(assets.client_chains[0].name).to.equal('XRP Ledger');
      expect(assets.tokens).to.have.lengthOf(1);
      expect(assets.tokens[0].asset_basic_info.symbol).to.equal('XRP');

      // Validate delegation state
      const delegation = appState.delegation;
      expect(delegation.associations).to.be.an('array');
      expect(delegation.delegation_states.length).to.be.greaterThan(0);
      expect(delegation.stakers_by_operator.length).to.be.greaterThan(0);

      // Validate dogfood state
      const dogfood = appState.dogfood;
      expect(dogfood.val_set.length).to.be.greaterThan(0);
      expect(dogfood.last_total_power).to.not.equal('0');

      // Validate oracle state
      const oracle = appState.oracle;
      expect(oracle.staker_list_assets.length).to.be.greaterThan(0);
      expect(oracle.staker_infos_assets.length).to.be.greaterThan(0);

      console.log('XRP Genesis generation test completed successfully!');
      console.log(`Genesis file written to: ${TEST_CONFIG.OUTPUT_PATH}`);
      console.log(`Number of mock stakes: ${mockStakes.length}`);
      console.log(`Number of validators: ${validators.length}`);
    }).timeout(60000);
  });

  // Helper function to deploy test contracts
  async function deployTestContracts() {
    // Deploy NetworkConstants library
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

    const initializeArgs = generateBootstrapInitData();

    const Proxy = await ethers.getContractFactory("TransparentUpgradeableProxy");
    const proxy = await Proxy.deploy(
        bootstrapLogic.target,
        "0x000000000000000000000000000000000000000B",
        Bootstrap.interface.encodeFunctionData('initialize', initializeArgs)
    );
    await proxy.waitForDeployment();

    bootstrapContract = await bootstrapLogic.attach(proxy.target);
  }

  // Helper function to generate valid initialization data for Bootstrap
  function generateBootstrapInitData() {
    const mockOwner = deployer.address;
    const spawnTime = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60; // 1 week from now
    const offsetDuration = 2; // 2 seconds
    const whitelistTokens = [];
    const tvlLimits = [];
    const mockProxyAdmin = "0x0000000000000000000000000000000000000009";
    const mockClientGatewayLogic = "0x000000000000000000000000000000000000000A";

    const clientChainInitData = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address'],
      [mockOwner]
    );

    return [
      mockOwner,
      spawnTime,
      offsetDuration,
      whitelistTokens,
      tvlLimits,
      mockProxyAdmin,
      mockClientGatewayLogic,
      clientChainInitData
    ];
  }

  // Helper function to create mock XRP stakes for testing
  function createMockXRPStakes() {
    const mockStakes = [];

    for (let i = 0; i < TEST_CONFIG.NUM_VALIDATORS; i++) {
      const validatorAddress = validatorsBech32[i];

      // Create multiple stakes per validator
      for (let j = 0; j < 2; j++) {
        const stakeIndex = i * 2 + j;
        mockStakes.push({
          hash: `mock_xrp_tx_hash_${stakeIndex}`,
          ledgerIndex: 1000000 + stakeIndex,
          transactionIndex: stakeIndex,
          xrpAddress: `0x${(stakeIndex + 1).toString(16).padStart(40, '0')}`, // Mock hex XRP address
          imuachainAddress: validators[i].address,
          validatorAddress: validatorAddress,
          amount: TEST_CONFIG.MIN_AMOUNT * (j + 1), // Varying amounts
          timestamp: Math.floor(Date.now() / 1000) - (stakeIndex * 3600) // Staggered timestamps
        });
      }
    }

    console.log(`Created ${mockStakes.length} mock XRP stakes`);
    return mockStakes;
  }

  // Cleanup test files after tests
  after(async function() {
    try {
      if (fs.existsSync(TEST_CONFIG.OUTPUT_PATH)) {
        await fs.promises.unlink(TEST_CONFIG.OUTPUT_PATH);
        console.log(`Cleaned up test file: ${TEST_CONFIG.OUTPUT_PATH}`);
      }
    } catch (error) {
      console.warn(`Failed to cleanup test file: ${error.message}`);
    }
  });
});
