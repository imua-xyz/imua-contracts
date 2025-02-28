#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f "${PROJECT_ROOT}/.env" ]; then
    source "${PROJECT_ROOT}/.env"
else
    echo -e "${RED}Error: .env file not found in ${PROJECT_ROOT}${NC}"
    exit 1
fi

# Check required environment variables
check_env() {
    local missing_vars=0

    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Error: PRIVATE_KEY is not set${NC}"
        missing_vars=1
    fi

    if [ -z "$IMUACHAIN_LOCALNET_RPC" ]; then
        echo -e "${RED}Error: IMUACHAIN_LOCALNET_RPC is not set${NC}"
        missing_vars=1
    fi

    if [ -z "$CLIENT_CHAIN_RPC" ]; then
        echo -e "${RED}Error: CLIENT_CHAIN_RPC is not set${NC}"
        missing_vars=1
    fi

    if [ $missing_vars -eq 1 ]; then
        exit 1
    fi
}

# Check if foundry is installed
check_foundry() {
    if ! command -v forge &> /dev/null; then
        echo -e "${RED}Error: forge command not found. Please install Foundry${NC}"
        exit 1
    fi
}

# Deploy function
deploy() {
    local network=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_dir="${PROJECT_ROOT}/logs"
    local log_file="deploy_${network}_${timestamp}.log"

    echo -e "${YELLOW}Starting deployment to ${network}...${NC}"
    echo -e "${YELLOW}Logging to ${log_file}${NC}"

    # Create logs directory if it doesn't exist
    mkdir -p "${log_dir}"

    # Run deployment from project root
    cd "${PROJECT_ROOT}"

    forge script script/23_DeployUTXOGateway.s.sol:DeployUTXOGateway \
        --rpc-url "$network" \
        --broadcast \
        2>&1 | tee "${log_dir}/${log_file}"

    local deploy_status=${PIPESTATUS[0]}

    if [ $deploy_status -eq 0 ]; then
        echo -e "${GREEN}Deployment completed successfully!${NC}"
        echo -e "${GREEN}Log file: logs/${log_file}${NC}"

        echo -e "\n${YELLOW}Extracting deployed addresses...${NC}"
        grep "Deployed contracts:" -A 5 "${log_dir}/${log_file}" > "${log_dir}/deployed_addresses_${network}_${timestamp}.txt"
        echo -e "${GREEN}Deployed addresses saved to: logs/deployed_addresses_${network}_${timestamp}.txt${NC}"
    else
        echo -e "${RED}Deployment failed!${NC}"
        echo -e "${RED}Check logs/${log_file} for details${NC}"
        exit 1
    fi
}

# Main execution
main() {
    echo -e "${GREEN}=== UTXOGateway Deployment Script ===${NC}"
    echo -e "${GREEN}Project root: ${PROJECT_ROOT}${NC}"

    # Check dependencies
    check_foundry
    check_env

    # Parse arguments
    local network=$1

    case $network in
        mainnet)
            echo -e "${YELLOW}WARNING: You are about to deploy to MAINNET${NC}"
            echo -e "${YELLOW}Please verify your settings:${NC}"
            echo -e "- Network: MAINNET"
            echo -e "- Script: script/23_DeployUTXOGateway.s.sol"
            echo -e "- RPC URL: ${EXOCORE_LOCAL_RPC}"
            read -p "Are you sure you want to continue? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                deploy mainnet
            else
                echo -e "${YELLOW}Deployment cancelled${NC}"
                exit 0
            fi
            ;;
        testnet)
            echo -e "${YELLOW}Deploying to TESTNET${NC}"
            echo -e "- Script: script/23_DeployUTXOGateway.s.sol"
            echo -e "- RPC URL: ${CLIENT_CHAIN_RPC}"
            deploy testnet
            ;;
        *)
            echo "Usage: $0 [mainnet|testnet]"
            echo "Example:"
            echo "  $0 testnet    # Deploy to testnet"
            echo "  $0 mainnet    # Deploy to mainnet"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
