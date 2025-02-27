# Imua Contracts

The imua-contracts repository contains a set of smart contracts deployed on both Imuachain and the target client chains, which facilitate assets deposit and withdrawal, cross-chain communication, and restaking operations for native assets and liquid staking tokens (LSTs), ensuring secure interactions and efficient management of restaked assets.

## Getting Started

* [Documentation](#documentation)
* [Building and Running Tests](#building-and-running-tests)
* [Deployments](#deployments)

## Documentation

### Basics

Our docs site is [here](https://docs.imua.xyz/components/smart-contracts). It contains tutorials, explainers, and smart contract documentation. If you'd like to view these docs on github instead, check out [the docs](/docs) repo:

- [Contracts summary](./docs/summary.md)
- [Architecture diagrams](/docs/architecture.svg)
- [LST restaking flow diagrams](/docs/lst-flow.svg)

### Dive

For the latest and most detailed technical documentation, visit [/docs](/docs) directory. If you're an advanced coder, this is the perfect place to get an overview of the contracts before you start exploring the code.

To understand how users interact with these contracts, take a look at our [Tests](./test/).

## Building and Testing

This repository utilizes Foundry. For more information on installation and usage, refer to the [Foundry documentation](https://book.getfoundry.sh/). If you already have Foundry installed, you can build this project and run tests using the following commands:

```
foundryup

git clone --recurse-submodules git@github.com:imua-xyz/imua-contracts.git && cd imua-contracts

forge build

forge test
```

### Running localnet tests

We have several tests against the local anvil testnet. To pass these tests, you need to set the environment variable. Refer to `.env.example` for guidance. Once your environment is set up, running `forge script/test` should show these tests passing.

`source .env`

Then run the test like:

`forge script script/1_Prerequisites.s.sol --broadcast -vvvv`

`forge test -vvvv --match-path/--match-path xxxx`

Deposit & Withdraw e2e test:

`forge test -vvvv --match-test test_DepositWithdraw`

### Running Static Analysis

1. Install [solhint](https://github.com/protofire/solhint), then run:

`solhint 'src/contracts/**/*.sol'`

2. Install [slither](https://github.com/crytic/slither), then run:

`slither .`


## Deployments

### Current Testnet Deployment

You can view the deployed contract addresses below, or check out the code itself on the [`main`](https://github.com/imua-xyz/imua-contracts/tree/main) branch.

#### Core

For the latest deployment addresses, see [script/deployments/deployedContracts.json](./script/deployments/deployedContracts.json).
