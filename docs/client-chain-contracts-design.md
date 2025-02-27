# Client Chain Contracts Design

## Overview

Imua client chain smart contracts refer to a set of smart contracts that are deployed on multiple chains (EVM-compatible chains for current version), and provided for Imua users (mainly stakers) to interact with Imua system from specific client chains. The administrative functionalities of these contracts are via their owner, which ideally should be a multi-sig.

The two main functionalities of client chain smart contracts include:

1. Take user funds into custody when users ask to enter Imua system, update user balance periodically and deal with withdrawal request of user based on withdrawable balance.
2. Forward user request from client chain side to Imuachain, as well as receive response from Imuachain to update state or execute some operations.

We have these components included in Imua client chain smart contracts architecture:

1. `Bootstrap`: The contract is used for bootstraping the Imua system, including accepting registration of validators and delegations from client chain stakers, and generate the valid genesis that could be used to bootstrap Imuachain.
2. `ClientChainGateway`: This is the entry point where client chain users make requests to Imuachain, as well as the endpoint that receives cross-chain messages from Imuachain.
3. `Vault`: This is where user funds are taken into custody and managed. Within `Vault`, user balance is updated on-demand by Imuachain validator set through cross-chain message to reveal user’s real position (after slashing, rewarding and other impact). Users can withdraw from `Vault` based on grant from the gateway. Every specific asset should have a standalone `Vault`.
4. `LSTRestakingController`: The controller is responsible for managing multiple `Vault`s. It should be the entry point for operations on `Vault`, as well as the entry point for user’s interactions with the gateway. It is inherited / implemented by the `Gateway`.
5. `ImuaCapsule`: The contract is used as the withdrawal destination for Ethereum native restaking. The Ethereum stakers who want to restake their staked ETH into Imua should create an owned `ImuaCapsule` contract through `NativeRestakingController` and point the withdrawal credentials of beacon chain validator to the `ImuaCapsule` contract.
6. `NativeRestakingController`: The controller is responsible for managing multiple `ImuaCapsule` instances. It provide functions for Ethereum native restaking, so that Ethereum beacon chain stakers could deposit their staked ETH into Imua without relying on any derived LST. It is inherited / implemented by the `ClientChainGateway` on Ethereum.

## Upgrade

Upgradeable contracts rely on three components: storage contract, logic contract, proxy contract. All upgradeable contracts architecture utilizes the fact that inside a proxy contract, if we `delegatecall` the logic contract, the code of the logic contract would be loaded in the context of the proxy contract. Therefore, the proxy contract actually forwards the call to a logic contract but reads and writes the proxy’s own state variables. That way, a proxy contract can inherit the old state (and even add state variables) even if the logic contract is replaced.

After the upgrade, the new logic contract (with the new implementation) must align the storage with the previous storage layout by extending it. It means that no state variables should be removed, and the type as well as the order of state variable should remain the same. All future versions of the logic contract must inherit the same storage contract to make the storage layout compatible after upgrade. Afterward, by replacing the old logic contract address with the address of new logic contract, we can upgrade a contract without violating its storage.

In this architecture, proxy contracts do not inherit the storage contract and are kept as stateless as possible.

For the purpose of allowing adding state variables to proxy contract, we need to retain some unused slots at the end of storage contract so that we can add new state variables and override the unused slots.

```solidity
contract GatewayStorage {
......
/**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[44] private __gap;
}
```

Besides all of these techniques, there are other details that we need to handle when designing upgradeable contracts, like function signature collision and forbidding initializing state variables in `constructor` and so on. Openzeppelin’s `TransparentUpgradeableProxy` and upgradeable implementation of token standards like `ERC20Upgradeable` handle these details properly.

1. `TransparentUpgradeableProxy` would store the meta state variables like logic contract address to random slots to avoid state variable storage layout collision.
2. [OpenZeppelin/openzeppelin-contracts-upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) follows the upgradeable design through the following:

> constructors are replaced by initializer functions, state variables are initialized in initializer functions, and we additionally check for storage incompatibilities across minor versions.

In most of the cases, we cannot directly use implementations linked above and need to implement our own upgradeable contracts. When we write our own upgradeable smart contracts, we must follow these principles:

1. Our upgradeable contracts should always inherit from OZ's upgradeable contracts.
2. Do not assign an initial value to state variables when declaring them, except `immutable` and `constant`.
3. Do not assign initial value to state variables in `constructor` except `immutable` .
4. Replace `constructor` with openzeppelin’s `initializer` modifier.
5. Disable initializers in `constructor` to prevent anyone else directly initialize the contract without calling the proxy.

Upgradable contract actually means the logic contract in our upgradeable contract architecture. So every upgradeable contract should be put behind a proxy contract.

Most commonly, community uses openzeppelin’s `[TransparentUpgradeableProxy](https://docs.openzeppelin.com/contracts/4.x/api/proxy#TransparentUpgradeableProxy)` implementation. Take EigenLayer contracts for example:

```solidity
/**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        emptyContract = new EmptyContract();
        delegation = DelegationManager(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );
        .....

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        DelegationManager delegationImplementation = new DelegationManager(strategyManager, slasher);
        .....

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(delegation))),
            address(delegationImplementation),
            abi.encodeWithSelector(
                DelegationManager.initialize.selector,
                eigenLayerReputedMultisig,
                eigenLayerPauserReg,
                0/*initialPausedStatus*/
            )
        );
        .....
```

It follow these steps:

1. First, deploy upgradeable proxy contracts that will point to the implementations. Since the implementation contracts are not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
2. Second, deploy the implementation contracts, using the proxy contracts as inputs.
3. Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.

On the other hand, openzeppelin’s doc suggests using `[UUPSUpgradeable](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)` while `[TransparentUpgradeableProxy](https://docs.openzeppelin.com/contracts/4.x/api/proxy#TransparentUpgradeableProxy)` being the most popular upgradeable proxy. We could explore `[UUPSUpgradeable](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)` while we reserve the plan of using `[TransparentUpgradeableProxy](https://docs.openzeppelin.com/contracts/4.x/api/proxy#TransparentUpgradeableProxy)` .

For more details please refer to these docs:

[Proxy Upgrade Pattern - OpenZeppelin Docs](https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies#the-constructor-caveat)

[Writing Upgradeable Contracts - OpenZeppelin Docs](https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable)

## `Gateway`

Similar to LayerZero `endpoint`, `ClientChainGateway` is mainly responsible for sending cross-chain messages and receiving cross-chain messages. The validity of cross-chain messages are guaranteed by LayerZero oracle and relayer if integrated with LayerZero protocol, otherwise `Gateway` itself should validate the cross-chain messages.

Eventually, the governance system of Imuachain should be the owner of `ClientChainGateway` so that it can update some state variables or even upgrade it in the future. In the early stages, a more controlled way to upgrade is needed, for example, a multi-sig.

We have made `ClientChainGateway` contract upgradeable so that the state can be retained while adding or removing some features in the future.

```solidity
contract BaseRestakingController {
    /// @dev Sends a message to Imuachain.
    /// @param action The action to be performed.
    /// @param actionArgs The encodePacked arguments for the action.
    function _sendMsgToImuachain(Action action, bytes memory actionArgs);

    /// @inheritdoc OAppReceiverUpgradeable
    function _lzReceive(Origin calldata _origin, bytes calldata payload);
}
```

### `_sendMsgToImuachain`

This internal function is used to send a message, over LayerZero, from the client chain to Imuachain. It encodes the action to perform, along with its payload, and forwards the packed data. The fees for this cross-chain message is provided by the calling address.

### `_lzReceive`

This internal function is called via LayerZero upon the receipt of a cross-chain message. In the context of the `ClientChainGateway`, it is used to handle the response provided by Imuachain against an outgoing message. For example, if a withdrawal request is initiated by a user, and sent by the `ClientChainGateway` to Imuachain, a response is received indicating whether the withdrawal is valid. Based on this validity, `ClientChainGateway` marks the funds available for the user to claim.

## `Vault`

Every whitelisted native token on the client chain has a standalone `Vault` used for user funds custody. Each `Vault` contract takes into custody the user's assets and stores them on their behalf. A user can enter the system by providing approval to the `Vault` contract and then depositing in it through the `ClientChainGateway`. Similarly, a user can exit the system by undelegating and withdrawing their assets and claiming them from the vault.

The assets in a `Vault` include the principal deposited as well as any rewards that may have accrued to the staker and any reductions for slashing. While each `Vault` contract stores some data, Imuachain is the single source of truth for the accurate withdrawable, deposited and staked balances.

```solidity
interface IVault {

    /// @notice Withdraws a specified amount from the vault.
    /// @param withdrawer The address initiating the withdrawal.
    /// @param recipient The address receiving the withdrawn amount.
    /// @param amount The amount to be withdrawn.
    function withdraw(address withdrawer, address recipient, uint256 amount) external;

    /// @notice Deposits a specified amount into the vault.
    /// @param depositor The address initiating the deposit.
    /// @param amount The amount to be deposited.
    function deposit(address depositor, uint256 amount) external;

    /// @notice Unlock and increase the withdrawable balance of a user for later withdrawal.
    /// @param staker The address of the staker whose principal balance is being unlocked.
    /// @param amount The amount of principal to be unlocked.
    function unlockPrincipal(address staker, uint256 amount) external;

    /// @notice Returns the address of the underlying token.
    /// @return The address of the underlying token.
    function getUnderlyingToken() external returns (address);

    /// @notice Sets the TVL limit for the vault.
    /// @param tvlLimit_ The new TVL limit for the vault.
    /// @dev It is possible to reduce or increase the TVL limit. Even if the consumed TVL limit is more than the new TVL
    /// limit, this transaction will go through and future deposits will be blocked until sufficient withdrawals are
    /// made.
    function setTvlLimit(uint256 tvlLimit_) external;

    /// @notice Gets the TVL limit for the vault.
    /// @return The TVL limit for the vault.
    // This is a function so that IVault can be used in other contracts without importing the Vault contract.
    function getTvlLimit() external returns (uint256);

    /// @notice Gets the total value locked in the vault.
    /// @return The total value locked in the vault.
    // This is a function so that IVault can be used in other contracts without importing the Vault contract.
    function getConsumedTvl() external returns (uint256);

}
```

`principalBalance` refers to the principal that the user deposits into the `ClientChainGateway`. It is separated from the rewards earned by the users, since such rewards could be distributed on Imuachain or on another client chain, while the user principal is taken in custody on this chain. Besides, we assume that the principal balance can only be influenced during slashing and that it is not transferable to any other address. In other words, the principal balance to be withdrawn can never be greater than the originally deposited principal balance.

### `deposit`

The implementation of this function transfers user funds into `Vault` address and updates the user's principal balance correspondingly.

This function is only accessible for `ClientChainGateway` so that this function could only work as part of the process of the whole deposit workflow and ensure the whole workflow is controlled by `ClientChainGateway`.

Whenever a `deposit` request is received by the `ClientChainGateway`, it first deposits the amount into the `Vault`. Then, it forwards the transaction to Imuachain, where it is appropriately processed, in line with the `checks-effects-interactions` pattern.

### `withdraw`

This function allows a user to claim their withdrawable assets. The quantity of the withdrawable assets is set by the `ClientChainGateway` in response to a withdrawal request, after receiving a response from Imuachain.

## `LSTRestakingController`

`LSTRestakingController` is the manager of all `Vaults`, as well as the entry point where users call to interact with Imua.

Ideally, the Imuachain validator set, via governance, should own `LSTRestakingController` so that upgrades can be made trustlessly.

```solidity
interface IBaseRestakingController {

    /// @notice Delegates a specified amount of tokens to a given operator.
    /// @param operator The address of the operator to delegate tokens to.
    /// @param token The address of the token to be delegated.
    /// @param amount The amount of tokens to delegate.
    function delegateTo(string calldata operator, address token, uint256 amount) external payable;

    /// @notice Undelegates a specified amount of tokens from a given operator.
    /// @param operator The address of the operator to undelegate tokens from.
    /// @param token The address of the token to be undelegated.
    /// @param amount The amount of tokens to undelegate.
    function undelegateFrom(string calldata operator, address token, uint256 amount) external payable;

    /// @notice Client chain users call to withdraw their unlocked assets from the vault.
    /// @dev This function assumes that the withdrawable assets should have been unlocked before calling this.
    /// @dev This function does not interact with Imuachain.
    /// @param token The address of specific token that the user wants to claim from the vault.
    /// @param amount The amount of @param token that the user wants to claim from the vault.
    /// @param recipient The destination address that the assets would be transfered to.
    function withdrawPrincipal(address token, uint256 amount, address recipient) external;

    /// @notice Submits reward to the reward module on behalf of the AVS
    /// @param token The address of the specific token that the user wants to submit as a reward.
    /// @param rewardAmount The amount of reward tokens that the user wants to submit.
    function submitReward(address token, address avs, uint256 rewardAmount) external payable;

    /// @notice Claims reward tokens from Imuachain.
    /// @param token The address of the specific token that the user wants to claim as a reward.
    /// @param rewardAmount The amount of reward tokens that the user wants to claim.
    function claimRewardFromImuachain(address token, uint256 rewardAmount) external payable;

    /// @notice Withdraws reward tokens from vault to the recipient.
    /// @param token The address of the specific token that the user wants to withdraw as a reward.
    /// @param recipient The address of the recipient of the reward tokens.
    /// @param rewardAmount The amount of reward tokens that the user wants to withdraw.
    function withdrawReward(address token, address recipient, uint256 rewardAmount) external;

}
```

### `deposit` into the `ILSTRestakingController`

See [`deposit`](#deposit).

Once the assets have been deposited into the `Vault`, the `ClientChainGateway` sends a cross-chain message to Imuachain, which is obviously asynchronous. Upon receiving the message, Imuachain will consider the deposit, and must respond that the message succeeded. This is because our design requires that deposits can never fail.

### `delegateTo`

This function controls the delegation workflow originating from the client chain. It requires that the caller has previously deposited enough tokens into the system, failing which, the transaction will fail.

The delegation workflow involves only one transaction from the user: call `ClientChainGateway.sendInterchainMsg` to send delegate request to Imuachain. And there is no response from Imuachain, since the event emitted by `ImuachainGateway` to tell whether the delegation is successful or not.

Since the `ClientChainGateway` by itself does not store enough information to check whether a delegation will be successful, this method must not make any state alterations to the balance.

### `undelegateFrom`

This function is the reverse of [`delegateTo`](#delegateto), except that it requires an unbonding period before the undelegation is released for withdrawal. The unbonding period is determined by Imuachain based on all the AVSs in which the operator was participating at the time of undelegation.

### `claimPrincipalFromImuachain`

This function is aimed for user claiming principal from Imuachain to client chain. This involves the correct accounting on Imuachain as well as the correct update of user's `principalBalance` and claimable balance. If this process is successful, user should be able to withdraw the corresponding assets on client chain to destination address.

The principal withdrawal workflow is separated into two transactions:

1. Transaction from the user: call `ClientChainGateway.sendInterchainMsg` to send principal withdrawal request to Imuachain.
2. Response from Imuachain: call `ClientChainGateway.receiveInterchainMsg` to receive the response from Imuachain, and call `unlockPrincipal` to update user's `principalBalance` and claimable balance. If response indicates failure, no user balance should be modified.

The claimable amount of principal is defined as follows:

1. The asset is not staked (delegated) on any operators.
2. The asset is not frozen/slashed.
3. The asset is not in unbonding state.

### `withdrawPrincipal`

This function is aimed for user withdrawing the unlocked amount of principal. Before withdrawing, user must make sure that there is enough principal unlocked by calling `claimPrincipalFromImuachain`. The implementation of this function should check against user's claimable balance and transfer tokens to the destination address that the user specified.

### `depositThenDelegateTo`

It is an ease-of-use feature to allow deposit and then delegation in one transaction. It has the same assumptions as the underlying two features.