const { expect } = require('chai');
const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');
const { GenesisGenerator, generateGenesisState } = require('../../../script/bootstrap/bitcoin_genesis.ts');
const { toBech32, fromHex } = require('@cosmjs/encoding');
const BitcoinClient = require('../utils/bitcoin-utils');
const { time } = require("@nomicfoundation/hardhat-network-helpers");

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

// Skip entire test suite if required environment variables are missing or invalid
const shouldSkipBitcoinTests = !TEST_CONFIG.BTC_ESPLORA_API_URL ||
  !TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY ||
  TEST_CONFIG.BTC_ESPLORA_API_URL.trim() === '' ||
  TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY.trim() === '' ||
  typeof TEST_CONFIG.BTC_ESPLORA_API_URL === 'undefined' ||
  typeof TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY === 'undefined' ||
  TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY.length !== 64; // Bitcoin private key should be 64 hex chars (32 bytes)

// Conditionally define the test suite based on environment variables
if (shouldSkipBitcoinTests) {
  describe.skip('Bitcoin Bootstrap Genesis Generation', function() {
    console.log('Skipping Bitcoin Bootstrap Genesis tests due to missing or invalid environment variables');
    it('should skip all tests', function() {
      this.skip();
    });
  });
} else {
  describe('Bitcoin Bootstrap Genesis Generation', function() {

  // Test data for OP_RETURN parsing
  const TEST_ADDRESSES = {
    VALID_IMUACHAIN: '0x742d35cc6634c0532925a3B8D8c26112bC4E1234',
    VALID_IMUACHAIN_2: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
    INVALID_IMUACHAIN_SHORT: '0x742d35Cc6634C0532925a3b8D8C26112bc4E12',
    INVALID_IMUACHAIN_LONG: '0x742d35Cc6634C0532925a3b8D8C26112bc4E123456',
    INVALID_IMUACHAIN_NO_PREFIX: '742d35Cc6634C0532925a3b8D8C26112bc4E1234',
    VALID_VALIDATOR: 'im1w9lpusfk9x7hfkz6qfcm2d3pkpn4xv5qx4z5a8n',
    VALID_VALIDATOR_2: 'im1c5x7mxphvgavjhu0au9jjqnfqcyspevt56fxe8',
    INVALID_VALIDATOR_PREFIX: 'ex1w9lpusfk9x7hfkz6qfcm2d3pkpn4xv5qx4z5a8n',
    INVALID_VALIDATOR_CHECKSUM: 'im1w9lpusfk9x7hfkz6qfcm2d3pkpn4xv5qx4z5a8x',
    INVALID_VALIDATOR_LENGTH: 'im1w9lpusfk9x7hfkz6qfcm2d3pkpn4xv5qx4z5',
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
    if (!TEST_CONFIG.BTC_ESPLORA_API_URL || !TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY ||
        TEST_CONFIG.BTC_ESPLORA_API_URL.trim() === '' || TEST_CONFIG.BTC_FAUCET_PRIVATE_KEY.trim() === '') {
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

  describe('OP_RETURN Data Parsing Tests', function() {
    let generator;

    beforeEach(async function() {
      // Create a minimal generator instance for testing
      const mockBootstrap = {
        validators: () => Promise.resolve({ name: 'Test Validator', consensusPublicKey: 'test-key' })
      };

      generator = new GenesisGenerator(
        'mock-vault-address',
        'mock-api-url',
        mockBootstrap,
        1,
        546
      );
    });

    describe('Valid OP_RETURN Data', function() {
      it('should parse valid OP_RETURN data correctly', function() {
        // Create valid OP_RETURN script
        // Format: 6a3d{20 bytes imuachain}{41 bytes validator}
        const imuachainHex = TEST_ADDRESSES.VALID_IMUACHAIN.slice(2); // Remove 0x prefix
        const validatorBytes = Buffer.from(TEST_ADDRESSES.VALID_VALIDATOR, 'utf8').toString('hex');
        const scriptPubKey = '6a3d' + imuachainHex + validatorBytes;

        const result = generator.testParseOpReturnData(scriptPubKey);

        expect(result).to.not.be.null;
        expect(result.imuachainAddressHex).to.equal(TEST_ADDRESSES.VALID_IMUACHAIN.toLowerCase());
        expect(result.validatorAddress).to.equal(TEST_ADDRESSES.VALID_VALIDATOR);
      });

      it('should parse second valid OP_RETURN data correctly', function() {
        // Test with second set of valid addresses
        const imuachainHex = TEST_ADDRESSES.VALID_IMUACHAIN_2.slice(2);
        const validatorBytes = Buffer.from(TEST_ADDRESSES.VALID_VALIDATOR_2, 'utf8').toString('hex');
        const scriptPubKey = '6a3d' + imuachainHex + validatorBytes;

        const result = generator.testParseOpReturnData(scriptPubKey);

        expect(result).to.not.be.null;
        expect(result.imuachainAddressHex).to.equal(TEST_ADDRESSES.VALID_IMUACHAIN_2.toLowerCase());
        expect(result.validatorAddress).to.equal(TEST_ADDRESSES.VALID_VALIDATOR_2);
      });

      it('should parse mixed valid addresses correctly', function() {
        // Test mixing first imuachain with second validator
        const imuachainHex = TEST_ADDRESSES.VALID_IMUACHAIN.slice(2);
        const validatorBytes = Buffer.from(TEST_ADDRESSES.VALID_VALIDATOR_2, 'utf8').toString('hex');
        const scriptPubKey = '6a3d' + imuachainHex + validatorBytes;

        const result = generator.testParseOpReturnData(scriptPubKey);

        expect(result).to.not.be.null;
        expect(result.imuachainAddressHex).to.equal(TEST_ADDRESSES.VALID_IMUACHAIN.toLowerCase());
        expect(result.validatorAddress).to.equal(TEST_ADDRESSES.VALID_VALIDATOR_2);
      });
    });

    describe('Invalid OP_RETURN Format', function() {
      it('should reject OP_RETURN with invalid prefix', function() {
        const imuachainHex = TEST_ADDRESSES.VALID_IMUACHAIN.slice(2);
        const validatorBytes = Buffer.from(TEST_ADDRESSES.VALID_VALIDATOR, 'utf8').toString('hex');
        const scriptPubKey = '6a3c' + imuachainHex + validatorBytes; // Wrong prefix

        const result = generator.testParseOpReturnData(scriptPubKey);
        expect(result).to.be.null;
      });

      it('should reject OP_RETURN with invalid data length', function() {
        const shortData = '6a3d' + 'ab'.repeat(30); // Too short
        const result = generator.testParseOpReturnData(shortData);
        expect(result).to.be.null;
      });
    });

    describe('Invalid Imuachain Address', function() {
      it('should reject short imuachain address', function() {
        const shortAddress = TEST_ADDRESSES.INVALID_IMUACHAIN_SHORT.slice(2);
        const validatorBytes = Buffer.from(TEST_ADDRESSES.VALID_VALIDATOR, 'utf8').toString('hex');
        // Pad to correct length to test address validation specifically
        const paddedAddress = shortAddress.padEnd(40, '0');
        const scriptPubKey = '6a3d' + paddedAddress + validatorBytes;

        const result = generator.testParseOpReturnData(scriptPubKey);
        expect(result).to.be.null;
      });

      it('should reject imuachain address without 0x prefix in validation', function() {
        const isValid = generator.testIsValidImuachainAddress(TEST_ADDRESSES.INVALID_IMUACHAIN_NO_PREFIX);
        expect(isValid).to.be.false;
      });

      it('should accept valid imuachain address', function() {
        const isValid = generator.testIsValidImuachainAddress(TEST_ADDRESSES.VALID_IMUACHAIN);
        expect(isValid).to.be.true;
      });

      it('should accept second valid imuachain address', function() {
        const isValid = generator.testIsValidImuachainAddress(TEST_ADDRESSES.VALID_IMUACHAIN_2);
        expect(isValid).to.be.true;
      });
    });

    describe('Invalid Validator Address', function() {
      it('should reject validator address with wrong prefix', function() {
        const isValid = generator.testIsValidValidatorAddress(TEST_ADDRESSES.INVALID_VALIDATOR_PREFIX);
        expect(isValid).to.be.false;
      });

      it('should reject validator address with invalid checksum', function() {
        const isValid = generator.testIsValidValidatorAddress(TEST_ADDRESSES.INVALID_VALIDATOR_CHECKSUM);
        expect(isValid).to.be.false;
      });

      it('should reject validator address with invalid length', function() {
        const isValid = generator.testIsValidValidatorAddress(TEST_ADDRESSES.INVALID_VALIDATOR_LENGTH);
        expect(isValid).to.be.false;
      });

      it('should accept valid validator address', function() {
        const isValid = generator.testIsValidValidatorAddress(TEST_ADDRESSES.VALID_VALIDATOR);
        expect(isValid).to.be.true;
      });

      it('should accept second valid validator address', function() {
        const isValid = generator.testIsValidValidatorAddress(TEST_ADDRESSES.VALID_VALIDATOR_2);
        expect(isValid).to.be.true;
      });
    });

    describe('UTF-8 Decoding Errors', function() {
      it('should handle invalid UTF-8 validator data gracefully', function() {
        const imuachainHex = TEST_ADDRESSES.VALID_IMUACHAIN.slice(2);
        // Create invalid UTF-8 sequence (incomplete multibyte character)
        const invalidUtf8 = 'ff'.repeat(41); // Invalid UTF-8 bytes
        const scriptPubKey = '6a3d' + imuachainHex + invalidUtf8;

        const result = generator.testParseOpReturnData(scriptPubKey, 'test-txid');
        expect(result).to.be.null;
      });
    });

    describe('Edge Cases', function() {
      it('should handle OP_RETURN data with exact boundary lengths', function() {
        // Test with exactly 20 bytes for imuachain and 41 bytes for validator
        const exactImuachainHex = 'ab'.repeat(20);
        const exactValidatorHex = Buffer.from('im1' + 'a'.repeat(38), 'utf8').toString('hex'); // 41 bytes
        const scriptPubKey = '6a3d' + exactImuachainHex + exactValidatorHex;

        const result = generator.testParseOpReturnData(scriptPubKey);
        // This should fail validation due to invalid addresses, but parsing should work
        expect(result).to.be.null; // Due to validation failure, not parsing failure
      });

      it('should provide transaction ID in error logs when specified', function() {
        const invalidScript = '6a3c' + 'ab'.repeat(61);
        const testTxId = 'test-transaction-id';

        // This should log the transaction ID in error messages
        const result = generator.testParseOpReturnData(invalidScript, testTxId);
        expect(result).to.be.null;
      });
    });
  });

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
}
