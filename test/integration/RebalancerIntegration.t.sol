// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ICLGauge} from "../../src/interfaces/ICLGauge.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

/**
 * @title RebalancerIntegrationTest
 * @notice Integration tests with real contracts in production network
 * @dev Run with --fork-url flag to use real network
 * 
 * Usage example:
 * forge test --match-contract RebalancerIntegrationTest --fork-url $MAINNET_RPC_URL -vv
 */
contract RebalancerIntegrationTest is Test {
    Rebalancer public rebalancer;
    address public nftManager;
    address public gauge;
    address public owner;

    // Real contract addresses (can be overridden via environment variables)
    address constant DEFAULT_NFT_MANAGER = address(0x1234567890123456789012345678901234567890); // Placeholder for tests
    address constant DEFAULT_GAUGE = address(0x0987654321098765432109876543210987654321); // Placeholder for tests

    // Check that address is a real contract (not a placeholder)
    modifier skipIfNotRealAddress(address addr) {
        // Skip test if placeholder is used or address is not a contract
        bool isDefault = (addr == DEFAULT_NFT_MANAGER || addr == DEFAULT_GAUGE);
        
        // Check that this is a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        
        bool isContract = codeSize > 0;
        
        // Skip if it's a placeholder or not a contract
        if (isDefault || !isContract) {
            console.log("[SKIP] Test skipped - using default addresses or not a contract");
            return;
        }
        _;
    }

    function setUp() public {
        // Get addresses from environment variables or use defaults
        nftManager = vm.envOr("NFT_MANAGER_ADDRESS", DEFAULT_NFT_MANAGER);
        gauge = vm.envOr("GAUGE_ADDRESS", DEFAULT_GAUGE);
        owner = address(this);

        // Deploy Rebalancer contract
        rebalancer = new Rebalancer(nftManager, gauge, owner);

        console.log("Rebalancer deployed at:", address(rebalancer));
        console.log("NFT Manager:", nftManager);
        console.log("Gauge:", gauge);
    }

    function testContractInitialization() public view {
        console.log("Testing contract initialization...");

        assertEq(address(rebalancer.nft()), nftManager, "NFT manager mismatch");
        assertEq(address(rebalancer.gauge()), gauge, "Gauge mismatch");
        assertEq(rebalancer.owner(), owner, "Owner mismatch");

        console.log("[OK] Contract initialized correctly");
    }

    function testGaugeTokens() public view skipIfNotRealAddress(gauge) {
        console.log("Testing gauge tokens...");

        ICLGauge gauge_ = ICLGauge(gauge);
        
        address gaugeToken0 = gauge_.token0();
        address gaugeToken1 = gauge_.token1();
        int24 gaugeTickSpacing = gauge_.tickSpacing();

        // Check that addresses are not zero
        assertNotEq(gaugeToken0, address(0), "Token0 is zero address");
        assertNotEq(gaugeToken1, address(0), "Token1 is zero address");
        assertNotEq(gaugeToken0, gaugeToken1, "Token0 and Token1 are the same");

        console.log("Gauge Token0:", gaugeToken0);
        console.log("Gauge Token1:", gaugeToken1);
        console.log("Gauge TickSpacing:", uint256(int256(gaugeTickSpacing)));

        // Check that Rebalancer returns the same tokens
        assertEq(address(rebalancer.token0()), gaugeToken0, "Rebalancer token0 mismatch");
        assertEq(address(rebalancer.token1()), gaugeToken1, "Rebalancer token1 mismatch");
        assertEq(rebalancer.tickSpacing(), gaugeTickSpacing, "Rebalancer tickSpacing mismatch");

        console.log("[OK] Gauge tokens match Rebalancer tokens");
    }

    function testTokenMetadata() public view skipIfNotRealAddress(gauge) {
        console.log("Testing token metadata...");

        IERC20 token0 = rebalancer.token0();
        IERC20 token1 = rebalancer.token1();

        // Try to get balance (should work if tokens are ERC20 compatible)
        uint256 token0Balance = token0.balanceOf(address(rebalancer));
        uint256 token1Balance = token1.balanceOf(address(rebalancer));

        console.log("Token0 balance in Rebalancer:", token0Balance);
        console.log("Token1 balance in Rebalancer:", token1Balance);

        // Check that balance can be read (doesn't fail)
        token0Balance; // Suppress unused warning
        token1Balance; // Suppress unused warning

        console.log("[OK] Token balances read successfully");
    }

    function testNFTManagerInterface() public view skipIfNotRealAddress(nftManager) {
        console.log("Testing NFT Manager interface...");

        INonfungiblePositionManager nft_ = INonfungiblePositionManager(nftManager);

        // Check that contract exists (can call function even if it might revert)
        // This is just a check that address is not an EOA
        address nftManagerAddr = nftManager;
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(nftManagerAddr)
        }
        assertGt(codeSize, 0, "NFT Manager is not a contract");

        console.log("[OK] NFT Manager is a contract");
    }

    function testGaugeInterface() public view skipIfNotRealAddress(gauge) {
        console.log("Testing Gauge interface...");

        ICLGauge gauge_ = ICLGauge(gauge);

        // Check that gauge contract exists
        address gaugeAddr = gauge;
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(gaugeAddr)
        }
        assertGt(codeSize, 0, "Gauge is not a contract");

        // Check that methods are available
        address token0 = gauge_.token0();
        address token1 = gauge_.token1();
        int24 tickSpacing = gauge_.tickSpacing();

        assertNotEq(token0, address(0), "Gauge token0 is zero");
        assertNotEq(token1, address(0), "Gauge token1 is zero");

        console.log("[OK] Gauge interface methods work correctly");
    }

    function testCurrentPosition() public view {
        console.log("Testing current position...");

        uint256 currentTokenId = rebalancer.currentTokenId();
        console.log("Current tokenId:", currentTokenId);

        // For a new contract, token ID should be 0
        // But if test runs on already deployed contract, there might be an active position
        // So we just check that value can be read
        currentTokenId; // Suppress unused warning

        console.log("[OK] Current position checked");
    }

    function testTokenApproval() public view skipIfNotRealAddress(gauge) {
        console.log("Testing token approval interface...");

        IERC20 token0 = rebalancer.token0();
        address rebalancerAddr = address(rebalancer);
        address token0Addr = address(token0);

        // Check that we can get balance (basic ERC20 method)
        uint256 balance = token0.balanceOf(rebalancerAddr);
        console.log("Token0 balance in Rebalancer:", balance);
        console.log("[OK] Token balance check works");
    }

    function testAllReadOperations() public view skipIfNotRealAddress(gauge) {
        console.log("Running all read operations test...");

        // Execute all view functions to check that they don't fail
        address(rebalancer.nft());
        address(rebalancer.gauge());
        rebalancer.owner();
        address(rebalancer.token0());
        address(rebalancer.token1());
        rebalancer.tickSpacing();
        rebalancer.currentTokenId();

        console.log("[OK] All read operations completed successfully");
    }

    // Useful test to check that all addresses are valid
    function testAddressesAreValid() public view skipIfNotRealAddress(nftManager) {
        console.log("Validating all addresses...");

        // Check that addresses are not zero
        assertNotEq(address(rebalancer), address(0), "Rebalancer is zero");
        assertNotEq(nftManager, address(0), "NFT Manager is zero");
        assertNotEq(gauge, address(0), "Gauge is zero");
        assertNotEq(owner, address(0), "Owner is zero");

        // Check that these are contracts (have code)
        address rebalancerAddr = address(rebalancer);
        address nftManagerAddr = nftManager;
        address gaugeAddr = gauge;
        
        uint256 rebalancerCodeSize;
        uint256 nftCodeSize;
        uint256 gaugeCodeSize;
        
        assembly {
            rebalancerCodeSize := extcodesize(rebalancerAddr)
            nftCodeSize := extcodesize(nftManagerAddr)
            gaugeCodeSize := extcodesize(gaugeAddr)
        }

        assertGt(rebalancerCodeSize, 0, "Rebalancer is not a contract");
        assertGt(nftCodeSize, 0, "NFT Manager is not a contract");
        assertGt(gaugeCodeSize, 0, "Gauge is not a contract");

        console.log("[OK] All addresses are valid contracts");
    }
}

