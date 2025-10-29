#!/bin/bash
# Basic deployment script for Rebalancer contract

set -e

# Load .env file if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env file..."
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Warning: .env file not found. Make sure environment variables are set."
fi

# Check required variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY is not set in .env file"
    exit 1
fi

if [ -z "$NFT_MANAGER_ADDRESS" ]; then
    echo "Error: NFT_MANAGER_ADDRESS is not set in .env file"
    exit 1
fi

if [ -z "$GAUGE_ADDRESS" ]; then
    echo "Error: GAUGE_ADDRESS is not set in .env file"
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
echo "=== Deployment Configuration ==="
echo "Network: $NETWORK"
echo "NFT Manager: $NFT_MANAGER_ADDRESS"
echo "Gauge: $GAUGE_ADDRESS"
echo "Owner: ${OWNER_ADDRESS:-deployer address from PRIVATE_KEY}"
echo ""

# Deployment script to use
SCRIPT="${1:-script/Deploy.s.sol:DeployScript}"

echo "Running: forge script $SCRIPT --rpc-url $RPC_URL --broadcast --verify --chain $CHAIN_NAME -vvvv"
echo ""

# Check if we should skip auto-verification
SKIP_VERIFY="${SKIP_AUTO_VERIFY:-false}"

if [ "$SKIP_VERIFY" = "true" ]; then
    echo "ℹ️  Running deployment without auto-verify..."
    echo ""
    
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        -vvvv
    
    echo ""
    echo "✅ Deployment completed!"
    echo ""
    echo "To verify the contract manually, run:"
    echo "  ./verify.sh <CONTRACT_ADDRESS> $CHAIN_NAME"
elif [ "$CHAIN_NAME" = "base" ]; then
    # For Base, deploy without auto-verify (use Sourcify separately)
    echo "ℹ️  Deploying to Base (verify separately using ./verify.sh)..."
    echo ""
    
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        -vvvv
    
    echo ""
    echo "✅ Deployment completed!"
    echo ""
    echo "💡 Verify using: ./verify.sh <CONTRACT_ADDRESS> base"
else
    # Try auto-verification for other networks
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --verify \
        --chain "$CHAIN_NAME" \
        -vvvv || {
        echo ""
        echo "⚠️  Auto-verification failed. Verify manually using:"
        echo "  ./verify.sh <CONTRACT_ADDRESS> $CHAIN_NAME"
        echo ""
    }
fi
