# Rebalancer Contract - Foundry Setup

A Foundry project for the Rebalancer contract with build, testing, and deployment functionality.

## Project Structure

```
.
├── src/              # Contract source code
│   └── Rebalancer.sol
├── test/             # Tests
│   ├── Rebalancer.t.sol                    # Unit tests with mocks
│   └── integration/                        # Integration tests
│       └── RebalancerIntegration.t.sol      # Tests with real contracts
├── script/           # Deployment scripts
│   ├── Deploy.s.sol          # Basic deployment script
│   └── DeployAndTest.s.sol   # Deployment script with integration tests
├── lib/              # Dependencies (OpenZeppelin, etc.)
└── foundry.toml      # Foundry configuration
```

## Installation

1. Install Foundry:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. Clone the repository and install dependencies:
```bash
git clone <repository-url>
cd copy-trading-contract
forge install
```

## Commands

### Build

```bash
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run a specific test
forge test --match-test testDeposit

# Run with verbose output
forge test -vvv
```

### Deployment

#### Setup Environment Variables

Create a `.env` file in the project root with the following variables:

```bash
PRIVATE_KEY=your_private_key_here
NFT_MANAGER_ADDRESS=0x...
GAUGE_ADDRESS=0x...
OWNER_ADDRESS=0x...  # optional, defaults to deployer address
MAINNET_RPC_URL=https://...
SEPOLIA_RPC_URL=https://...  # optional
ETHERSCAN_API_KEY=your_api_key  # for verification
```

#### Easy Deployment Scripts

Two deployment scripts are provided:

**1. Basic Deployment (`deploy.sh`)**
Simple deployment without integration tests:

```bash
./deploy.sh
```

**2. Deployment with Testing (`DeployAndTest.sh`)**
Deployment with automatic integration testing:

```bash
./DeployAndTest.sh
```

Both scripts:
- Automatically load variables from `.env` file
- Detect network (Base/Mainnet/Sepolia) from RPC URL
- Handle verification appropriately for each network
- Provide clear instructions after deployment

#### Manual Deployment

##### Local Network (Anvil)

1. Start a local node:
```bash
anvil
```

2. Load environment variables and deploy:
```bash
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url anvil --broadcast
```

##### Test Network (Sepolia)

```bash
source .env
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

##### Main Network (Mainnet)

```bash
source .env
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

### Deployment Scripts Comparison

#### deploy.sh - Basic Deployment
- Uses `script/Deploy.s.sol:DeployScript`
- Quick deployment without integration tests
- Faster for production deployments
- Use when you just need to deploy quickly

#### DeployAndTest.sh - Deployment with Testing
- Uses `script/DeployAndTest.s.sol:DeployAndTestScript`
- Deploys and runs integration tests
- Verifies contract initialization and gauge integration
- Use when you want to verify everything works after deployment

**Integration tests automatically check:**
- Contract initialization
- Token retrieval from gauge
- ERC20 token balance checks
- Current position check
- Token metadata (symbols)

**Note**: Both scripts read all values from `.env` file. Make sure `PRIVATE_KEY`, `NFT_MANAGER_ADDRESS`, and `GAUGE_ADDRESS` are set.

### Integration Tests with Real Contracts

Run integration tests on a production network fork (without real transactions):

```bash
# Load .env
source .env

# Run integration tests on Mainnet fork
forge test --match-contract RebalancerIntegrationTest \
    --fork-url $MAINNET_RPC_URL \
    -vv

# Run a specific test
forge test --match-test testGaugeTokens \
    --fork-url $MAINNET_RPC_URL \
    -vvv
```

Integration tests include:
- `testContractInitialization` - initialization check
- `testGaugeTokens` - token retrieval from gauge check
- `testTokenMetadata` - token metadata check
- `testNFTManagerInterface` - NFT Manager interface check
- `testGaugeInterface` - Gauge interface check
- `testCurrentPosition` - current position check
- `testAllReadOperations` - all view functions check
- `testAddressesAreValid` - address validation

### Contract Verification

#### Automatic Verification

Verification is attempted automatically during deployment. For Base network, auto-verification is skipped due to API V2 compatibility. After deployment, you'll see instructions for manual verification.

#### Manual Verification

Use the provided verification script:

```bash
# Verify on Base network
./verify.sh <CONTRACT_ADDRESS> base

# Verify on Ethereum Mainnet
./verify.sh <CONTRACT_ADDRESS> mainnet

# Verify on Sepolia
./verify.sh <CONTRACT_ADDRESS> sepolia
```

Or use forge directly:

```bash
# For Base network
source .env
forge verify-contract \
    <CONTRACT_ADDRESS> \
    src/Rebalancer.sol:Rebalancer \
    --chain base \
    --etherscan-api-key $BASESCAN_API_KEY \
    --num-of-optimizations 200 \
    --compiler-version 0.8.28

# For Ethereum Mainnet/Sepolia
source .env
forge verify-contract \
    <CONTRACT_ADDRESS> \
    src/Rebalancer.sol:Rebalancer \
    --chain mainnet \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --num-of-optimizations 200 \
    --compiler-version 0.8.28
```

**Note:** The configuration uses Etherscan API V2 format. For Base network, make sure to set `BASESCAN_API_KEY` in your `.env` file.

## Configuration

The `foundry.toml` file contains project settings:
- Compiler version: `0.8.28`
- Optimizer enabled (200 runs)
- Remappings for OpenZeppelin

## Tests

### Unit Tests (with mocks)

The project includes the following unit tests:
- `testConstructor` - contract initialization check
- `testDeposit` - token deposit
- `testRebalance` - position rebalancing
- `testCloseAllPositions` - closing all positions
- `testWithdrawAll` - withdrawing all funds
- `testRescueERC20` - token rescue function
- Access control tests (onlyOwner)

### Integration Tests (with real contracts)

Run on a production network fork to test interaction with real contracts.

## Dependencies

- OpenZeppelin Contracts v5.4.0
- Forge Standard Library (forge-std) v1.11.0

## License

MIT
