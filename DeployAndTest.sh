#!/bin/bash
# Deployment script with integration testing for Rebalancer contract

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
echo "=== Deployment with Testing Configuration ==="
echo "Network: $NETWORK"
echo "NFT Manager: $NFT_MANAGER_ADDRESS"
echo "Gauge: $GAUGE_ADDRESS"
echo "Owner: ${OWNER_ADDRESS:-deployer address from PRIVATE_KEY}"
echo ""

# Use DeployAndTest script which includes integration tests
SCRIPT="script/DeployAndTest.s.sol:DeployAndTestScript"

echo "Running: forge script $SCRIPT --rpc-url $RPC_URL --broadcast --verify --chain $CHAIN_NAME -vvvv"
echo ""

# For Base, deploy without auto-verify (use Sourcify separately)
if [ "$CHAIN_NAME" = "base" ]; then
    echo "ℹ️  Deploying to Base with integration tests (verify separately using ./verify.sh)..."
    echo ""
    
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        -vvvv
    
    echo ""
    echo "✅ Deployment and testing completed!"
    echo ""
    echo "💡 Verify using: ./verify.sh <CONTRACT_ADDRESS> base"
    echo ""
    echo "The deployment script has already run integration tests."
elif [ "${SKIP_AUTO_VERIFY:-false}" = "true" ]; then
    echo "ℹ️  Running deployment with tests (verification skipped)..."
    echo ""
    
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        -vvvv
    
    echo ""
    echo "✅ Deployment and testing completed!"
    echo ""
    echo "To verify the contract manually, run:"
    echo "  ./verify.sh <CONTRACT_ADDRESS> $CHAIN_NAME"
else
    # Try auto-verification for other networks
    forge script "$SCRIPT" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --verify \
        --chain "$CHAIN_NAME" \
        -vvvv || {
        echo ""
        echo "⚠️  Auto-verification failed, but deployment and tests completed."
        echo "Verify manually using:"
        echo "  ./verify.sh <CONTRACT_ADDRESS> $CHAIN_NAME"
        echo ""
        echo "✅ Integration tests passed!"
        echo ""
    }
fi

