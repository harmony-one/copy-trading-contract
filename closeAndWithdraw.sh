#!/bin/bash
# Script to close all positions and withdraw all tokens and rewards from Rebalancer contract

set -e

# Check if contract address is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <REBALANCER_CONTRACT_ADDRESS>"
    echo ""
    echo "Example: $0 0x1234567890123456789012345678901234567890"
    exit 1
fi

REBALANCER_ADDRESS="$1"

# Validate address format (basic check - 0x followed by 40 hex characters)
if [[ ! "$REBALANCER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Error: Invalid contract address format: $REBALANCER_ADDRESS"
    echo "Expected format: 0x followed by 40 hexadecimal characters"
    exit 1
fi

# Load .env file if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env file..."
    # Use set -a to automatically export all variables
    set -a
    # Source .env with error handling
    if ! source .env 2>/dev/null; then
        echo "Warning: Some errors occurred while loading .env file, continuing..."
    fi
    set +a
else
    echo "Warning: .env file not found. Make sure environment variables are set."
fi

# Check required variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY is not set in .env file"
    exit 1
fi

# Validate PRIVATE_KEY format (should start with 0x and be 66 characters)
if [[ ! "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "Error: Invalid PRIVATE_KEY format in .env file"
    echo "Expected format: 0x followed by 64 hexadecimal characters"
    exit 1
fi

# Determine RPC URL and network name
if [ -n "$MAINNET_RPC_URL" ]; then
    RPC_URL="$MAINNET_RPC_URL"
    # Check if it's Base network
    if echo "$MAINNET_RPC_URL" | grep -qi "base"; then
        NETWORK="base"
        CHAIN_NAME="base"
    else
        NETWORK="mainnet"
        CHAIN_NAME="mainnet"
    fi
elif [ -n "$SEPOLIA_RPC_URL" ]; then
    RPC_URL="$SEPOLIA_RPC_URL"
    NETWORK="sepolia"
    CHAIN_NAME="sepolia"
else
    echo "Error: MAINNET_RPC_URL or SEPOLIA_RPC_URL must be set in .env file"
    exit 1
fi

echo ""
echo "=========================================="
echo "Close and Withdraw Operations"
echo "=========================================="
echo "Network: $CHAIN_NAME"
echo "Contract Address: $REBALANCER_ADDRESS"
echo "RPC URL: ${RPC_URL:0:30}..."
echo ""

# Export contract address as environment variable for the script
export REBALANCER_ADDRESS

# Execute the script
echo "Executing close and withdraw operations..."
if forge script script/CloseAndWithdraw.s.sol:CloseAndWithdrawScript \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    -vvv; then
    echo ""
    echo "=========================================="
    echo "Operations completed successfully!"
    echo "=========================================="
    exit 0
else
    echo ""
    echo "=========================================="
    echo "Error: Script execution failed!"
    echo "=========================================="
    exit 1
fi

