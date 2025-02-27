# Governance

## Overview

The contract has privileged functions accessible only to the contract owner, excluding most user-facing functionalities. These functions are utilized for:

- **Configuration**: Setting key contract parameters, such as the whitelist for stakeable assets.
- **Pause/Unpause**: Temporarily halting the contract in emergencies and resuming it once resolved.
- **Enable Messaging**: Activating or deactivating LayerZero messaging capabilities.
- **Upgradeability**: Transitioning the contract to a new implementation.

The contract owner is effectively the protocol's governor, with governance primarily operating through the owner's proposal and execution of tasks. To facilitate governance and mitigate centralization risks, a two-tier governance structure is implemented for the contract owner:

1. **CustomTimelockController**: A custom timelock controller contract that owns the business contract, allowing tasks to be proposed and executed through it. This custom controller features a circuit breaker role, enabling emergency contract pauses without waiting for the timelock period.
2. **Multisig**: Utilizing Safe Multisig wallets as the proposer/canceler, executor, circuit breaker, and even the admin of the custom timelock controller contract to avoid single point of failure.

## `CustomTimelockController`

`CustomTimelockController` is a custom timelock controller contract that inherits from the OpenZeppelin `TimelockController` contract. It has a special role named circuit breaker, which can be used to pause the contract in case of emergency without waiting for the timelock period(not applied to unpause). The main roles for the `CustomTimelockController` are:

- **Proposer/Canceler**: Propose a new task or cancel a proposed task.
- **Executor**: Execute a task after the timelock period.
- **Circuit Breaker**: Pause the contract in case of emergency.
- **Admin**: Set the roles for the `CustomTimelockController`.

## Safe Multisig

We use the Safe Multisig wallets as the proposer/canceler, executor, circuit breaker and even the admin of the `CustomTimelockController`. For chains like Ethereum, we create the Safe Multisig wallets from deployed Safe proxy factory contract, and set the implementation as the deployed Safe. And for Imuachain specifically, we deploy the set of Safe contracts, especially for the `GnosisSafeProxyFactory` and the `GnosisSafe`, `GnosisSafeL2` singletons. The deployed Safe contracts address can be found in the [deployment json file](../script/deployments/safe_contracts_on_imuachain.json).

## Governance Test

We have some fuzzing tests to make sure governance works as expected. Please refer to the [governance test](../test/foundry/Governance.t.sol) for more details.

## Governance in Production

When the protocol is ready for production, we will set the Safe Multisig wallets as the proposer/canceler, executor, circuit breaker and even the admin of the `CustomTimelockController`, and manage our contracts through the timelock controller. At that time, we will decide the multisig wallet for each role, the threshold for each multisig wallet, the signers for each multisig wallet, and the timelock period for timelock controller.