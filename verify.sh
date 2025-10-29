#!/bin/bash
# Manual verification script for contract after deployment

set -e

# Load .env file if it exists
if [ -f .env ]; then
    source .env
fi

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: ./verify.sh <CONTRACT_ADDRESS> [CHAIN_NAME]"
    echo ""
    echo "Example:"
    echo "  ./verify.sh 0x1234... base"
    echo "  ./verify.sh 0x1234... mainnet"
    exit 1
fi

CONTRACT_ADDRESS="$1"
CHAIN_NAME="${2:-base}"

echo "=== Contract Verification ==="
echo "Contract: $CONTRACT_ADDRESS"
echo "Chain: $CHAIN_NAME"
echo ""

# Determine API key based on chain
if [ "$CHAIN_NAME" = "base" ]; then
    API_KEY="${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY}}"
    if [ -z "$API_KEY" ]; then
        echo "Error: BASESCAN_API_KEY or ETHERSCAN_API_KEY must be set"
        exit 1
    fi
    echo "Using Basescan API..."
elif [ "$CHAIN_NAME" = "mainnet" ] || [ "$CHAIN_NAME" = "sepolia" ]; then
    API_KEY="${ETHERSCAN_API_KEY}"
    if [ -z "$API_KEY" ]; then
        echo "Error: ETHERSCAN_API_KEY must be set"
        exit 1
    fi
    echo "Using Etherscan API..."
else
    echo "Error: Unsupported chain: $CHAIN_NAME"
    exit 1
fi

echo ""
echo "Verifying contract..."
echo ""

# For Base network, we need to use Basescan API V2 endpoint
if [ "$CHAIN_NAME" = "base" ]; then
    # Try using flattened contract for better compatibility
    echo "Creating flattened contract for verification..."
    forge flatten src/Rebalancer.sol > /tmp/RebalancerFlattened.sol 2>/dev/null || echo "Note: Flatten may have warnings"
    
    echo "Attempting verification..."
    echo ""
    echo "ℹ️  Using Sourcify verifier for Base (Basescan API has V2 compatibility issues)..."
    echo ""
    
    # Use Sourcify verifier for Base as it works better with Base network
    if forge verify-contract \
        "$CONTRACT_ADDRESS" \
        src/Rebalancer.sol:Rebalancer \
        --chain base \
        --verifier sourcify \
        --num-of-optimizations 200 \
        --compiler-version 0.8.28 \
        --watch 2>&1; then
        echo ""
        echo "✅ Verification successful via Sourcify!"
        echo "   Contract verified at: https://sourcify.dev/#/lookup/$CONTRACT_ADDRESS"
    else
        echo ""
        echo "⚠️  Sourcify verification failed. Trying Basescan API as fallback..."
        echo ""
        
        # Fallback to Basescan API
        if forge verify-contract \
            "$CONTRACT_ADDRESS" \
            src/Rebalancer.sol:Rebalancer \
            --chain base \
            --etherscan-api-key "$API_KEY" \
            --num-of-optimizations 200 \
            --compiler-version 0.8.28 \
            --watch 2>&1; then
            echo ""
            echo "✅ Verification successful via Basescan!"
        else
            echo ""
            echo "⚠️  Automatic verification failed. Use manual verification:"
            echo ""
            echo "📋 Manual Verification on Basescan:"
            echo "1. Visit: https://basescan.org/address/$CONTRACT_ADDRESS#code"
            echo "2. Click 'Verify and Publish' tab"
            echo "3. Use flattened contract:"
            echo "   forge flatten src/Rebalancer.sol > RebalancerFlattened.sol"
            echo ""
            echo "Settings: Compiler 0.8.28, Optimization 200 runs, EVM Paris"
        fi
    fi
else
    forge verify-contract \
        "$CONTRACT_ADDRESS" \
        src/Rebalancer.sol:Rebalancer \
        --chain "$CHAIN_NAME" \
        --etherscan-api-key "$API_KEY" \
        --num-of-optimizations 200 \
        --compiler-version 0.8.28 \
        --watch
fi

echo ""
echo "✅ Verification complete!"

