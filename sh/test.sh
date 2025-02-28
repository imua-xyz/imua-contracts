#!/bin/bash

# Step 1: Define the contract name and output path
CONTRACT_NAME="UTXOGateway"
OUTPUT_PATH="/Users/will/go/src/github.com/ExocoreNetwork/utxo-restaking"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CLIENT_CHAIN_ID=1
RPC_URL="http://127.0.0.1:8546"
BTC_ADDRESS="tb1qll4r3nktn7l6ng678g99nzcveusvnsgrmdsyhr"
BTC_ADDRESS_BYTES=$(cast --from-utf8 "$BTC_ADDRESS")
TOKEN_ADDRESS_BYTES="0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB000000000000000000000000"
BRIDGE_ADDRESS="0x0000000000000000000000000000000000000804"

# Step 2: Update ABI
forge inspect src/core/$CONTRACT_NAME.sol:$CONTRACT_NAME abi > $OUTPUT_PATH/src/abi/utxogateway.json

# Step 3: Flatten the contract and filter out compiler log information
forge flatten src/core/UTXOGateway.sol | grep -v "Compiling" | grep -v "Solc" | grep -v "Compiler run" > src/core/UTXOGatewayFlatten.sol

# Step 4: Deploy the contract and capture the output
output=$(forge create --rpc-url $RPC_URL --private-key "$PRIVATE_KEY" src/core/UTXOGatewayFlatten.sol:UTXOGateway)

# Step 5: Extract the contract address from the output
contract_address=$(echo "$output" | grep "Deployed to:" | awk '{print $3}')

# Step 6: Update the CONTRACT_ADDRESS in the .env file
sed -i "" "s/^CONTRACT_ADDRESS=.*/CONTRACT_ADDRESS=\"$contract_address\"/" $OUTPUT_PATH/.env

# Step 7: Output the deployment information
echo "$output"

# Step 8: Send a transaction to register an address
echo "Registering address..."
register_output=$(cast send --rpc-url $RPC_URL --private-key "$PRIVATE_KEY" "$contract_address" "registerAddress(bytes,bytes)" $BTC_ADDRESS_BYTES 0x70997970c51812dc3a010c7d01b50e0d17dc79c8000000000000000000000000)
echo "Register address output:"
echo "$register_output"
echo

# Step 9: Call the btcToExocoreAddress function
echo "Calling btcToExocoreAddress function..."
btc_to_exocore_output=$(cast call --rpc-url $RPC_URL "$contract_address" "btcToExocoreAddress(bytes)(bytes)" $BTC_ADDRESS_BYTES)
echo "btcToExocoreAddress output:"
echo "$btc_to_exocore_output"
echo

# Step 10: Send a transaction to deposit to an address
echo "Depositing to address..."
deposit_output=$(cast send --rpc-url $RPC_URL --private-key "$PRIVATE_KEY" --gas-limit 1000000 $BRIDGE_ADDRESS "depositTo(uint32,bytes,bytes,uint256)" ${CLIENT_CHAIN_ID} $TOKEN_ADDRESS_BYTES $BTC_ADDRESS_BYTES 2222)
echo "Deposit output:"
echo "$deposit_output"
echo

# Step 11: Call the getPrincipalBalance function
echo "Calling getPrincipalBalance function..."
balance_output=$(cast call --rpc-url $RPC_URL $BRIDGE_ADDRESS "getPrincipalBalance(uint32,bytes,bytes)(uint256)" ${CLIENT_CHAIN_ID} $TOKEN_ADDRESS_BYTES $BTC_ADDRESS_BYTES)
echo "Principal balance:"
echo "$balance_output"
echo
