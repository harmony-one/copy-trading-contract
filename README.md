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

#### Local Network (Anvil)

1. Start a local node:
```bash
anvil
```

2. Configure environment variables (create a `.env` file):
```bash
PRIVATE_KEY=your_private_key_here
NFT_MANAGER_ADDRESS=0x123...
GAUGE_ADDRESS=0x456...
OWNER_ADDRESS=0x789...
```

3. Load environment variables and deploy:
```bash
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url anvil --broadcast
```

#### Test Network (Sepolia)

```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

#### Main Network (Mainnet)

```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

### Deployment with Automatic Testing

#### DeployAndTest Script

The `DeployAndTest.s.sol` script deploys the contract and then performs integration checks with real contracts:

```bash
# Set up environment variables (NFT_MANAGER_ADDRESS and GAUGE_ADDRESS are required)
export PRIVATE_KEY=your_private_key
export NFT_MANAGER_ADDRESS=0x...
export GAUGE_ADDRESS=0x...
export MAINNET_RPC_URL=https://...

# Deploy and test on Mainnet
forge script script/DeployAndTest.s.sol:DeployAndTestScript \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

The script automatically checks:
- Contract initialization
- Token retrieval from gauge
- ERC20 token balance checks
- Current position check
- Token metadata (symbols)

### Integration Tests with Real Contracts

Run integration tests on a production network fork (without real transactions):

```bash
# Set real contract addresses
export NFT_MANAGER_ADDRESS=0x...
export GAUGE_ADDRESS=0x...

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

```bash
forge verify-contract \
    <CONTRACT_ADDRESS> \
    src/Rebalancer.sol:Rebalancer \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --chain sepolia
```

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
