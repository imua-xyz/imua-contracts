import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import "dotenv/config";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  allowUnlimitedContractSize: true,
  networks: {
    hardhat: {
      chainId: 1,
    },
    imuachain_localnet: {
      url: "http://127.0.0.1:8545",
      chainId: 232,
      accounts: [
        process.env.LOCAL_IMUACHAIN_FUNDED_ACCOUNT_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_ONE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_TWO_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_THREE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_FOUR_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_FIVE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_SIX_PRIVATE_KEY,
      ]
    },
    imuachain_testnet: {
      url: "https://api-eth.exocore-restaking.com",
      chainId: 233,
      accounts: [
        process.env.TEST_ACCOUNT_THREE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_ONE_PRIVATE_KEY,
        process.env.TEST_ACCOUNT_TWO_PRIVATE_KEY,
      ]
    }
  },
  etherscan: {
    // not needed for imuachain_testnet
    apiKey: "https://exoscan.org/api",
    customChains: [
      {
        network: "imuachain_testnet",
        chainId: 233,
        urls: {
          apiURL: "https://exoscan.org/api  ",
          browserURL: "https://exoscan.org"
        }
      }
    ]
  },
};
