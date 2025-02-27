# Cross-Chain Communication Model

## 1:N

While there could be multiple client chains and `ClientChainGateway`s, there is only one Imuachain that serves as the source of truth. Similarly, there is only one `ImuachainGateway` contract that manages the communication between a client chains and Imuachain internals. This contract receives messages from the client chains and forwards them to Imuachain chain, or sends requests to the client chains. Therefore, the communication between `ImuachainGateway` and `ClientChainGateway`s is 1:N.

## Ordered Message Execution

Both `ClientChainGateway` and `ImuachainGateway` ensure ordered message execution for requests and responses using a message nonce mechanism:

1. The first message sent by the sender contract has a nonce of 1, and each subsequent message has a unique nonce.
2. After successfully sending a message, the sender contract increments the nonce by 1.
3. The receiver contract expects messages with a nonce matching the next expected nonce, starting from 1.
4. Upon successful receipt of a message, the receiver contract increments the next expected nonce by 1.
5. If a message with a nonce lower than the next expected nonce is received, it indicates the message has already been processed and is not executed again.
6. Receipt of a message with a nonce higher than the next expected nonce implies message loss, which is not expected to occur.

This nonce management is specific to each client chain and `ClientChainGateway`, ensuring message ordering per client chain.

## Blocking Message Execution

Both `ClientChainGateway` and `ImuachainGateway` handle messages in a blocking manner. This ensures that the receiver contract does not process the next message until the current one is successfully executed. Specifically, if the relayer forwards a message to the receiver contract and the contract fails to execute the message, the message is not stored and the nonce is not incremented, preventing the message with the next expected nonce from being received.

## Request-Response

Given the above properties, we could conclude:

1. The receiver contract must successfully execute every request or response message to prevent protocol halting.
2. The receiver contract should only revert transactions due to critical or unrecoverable errors.
3. To prevent protocol halting:
   1. No successfully sent message should be lost.
   2. The receiver contract should not revert transactions except for critical or unrecoverable errors.
4. For potentially failing request or response messages, the receiver contract's handler function should not revert transactions, including expected failure cases.
5. Response messages are not required for every request message, especially if the sender contract does not perform asynchronous operations based on the response.
6. For must-success request messages, the sender contract can assume successful execution by the receiver contract and does not require a response message.
