
### Bootstrap
The Bootstrap smart contract is designed to manage token whitelisting, operator registration, deposits, and withdrawals. It ensures that operations are locked during specific periods (before mainnet/testnet launch) for security. This contract is independent and upgrades itself to ClientChainGateway after the mainnet/testnet launch.

### ImuachainGateway
The ImuachainGateway contract handles cross-chain messaging and interactions with Imuachain. This contract provides functionalities such as deposits, delegations, undelegations, and the withdrawal of principal and rewards. It facilitates cross-chain communication through the LayerZero protocol.

### ClientChainGateway
The ClientChainGateway contract acts as a cross-chain gateway, transmitting information and commands between Imuachain's core layer and the client chain. It verifies and executes signed commands such as deposits, withdrawals, and delegation, manages whitelisted assets and their Vault deployments, allows stakers to interact with the core layer through events, and provides emergency pause and resume functions to ensure system stability.

### BaseRestakingController
The BaseRestakingController contract is an abstract contract. It primarily handles the fundamental logic related to restaking, including declarations, delegations, undelegations, and messaging with Imuachain.

### LSTRestakingController
The LSTRestakingController contract  an abstract contract, which provides functionalities for users to deposit tokens, withdraw principal from Imuachain, and withdraw rewards from Imuachain. It primarily handles operations related to Liquid Staking Tokens (LST).

### NativeRestakingController
The NativeRestakingController contract is an abstract contract, which primarily handles the logic for native Ethereum restaking. It includes functionalities such as staking, creating Imuaapsule contracts, and managing deposits and partial/full withdrawals for Beacon Chain validators.

### Vault
The Vault smart contract manages deposits, withdrawals, and balance updates for users interacting with the system. It ensures secure handling of ERC20 tokens and implements business logic to maintain accurate records of user balances, including principal and reward amounts.

### ImuaCapsule
The ImuaCapsule contract is designed to handle specific operations related to native Ethereum restaking tokens. It provides functionalities for depositing and withdrawing these tokens, ensuring secure and efficient management of virtual staked assets.
