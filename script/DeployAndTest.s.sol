// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ICLGauge} from "../src/interfaces/ICLGauge.sol";

/**
 * @title DeployAndTestScript
 * @notice Script for deployment and integration testing in production network
 * @dev Deploys the contract and then performs basic checks with real contracts
 */
contract DeployAndTestScript is Script {
    Rebalancer public rebalancer;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Rebalancer contract ===");
        console.log("Deployer address:", deployer);

        // Get real contract addresses from environment variables
        address nftManager = vm.envAddress("NFT_MANAGER_ADDRESS");
        address gauge = vm.envAddress("GAUGE_ADDRESS");
        address owner = vm.envOr("OWNER_ADDRESS", deployer);

        console.log("NFT Manager:", nftManager);
        console.log("Gauge:", gauge);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy contract
        rebalancer = new Rebalancer(nftManager, gauge, owner);
        console.log("Rebalancer deployed at:", address(rebalancer));

        vm.stopBroadcast();

        // Integration checks (executed without transactions, read-only)
        console.log("\n=== Running Integration Tests ===");
        runIntegrationTests(address(rebalancer), nftManager, gauge, owner);

        // Full flow testing (deposit -> rebalance -> closeAll -> withdrawAll)
        // Only runs if test parameters are provided
        bool runFullFlow = vm.envOr("TEST_AMOUNT0", uint256(0)) > 0 && 
                          vm.envOr("TEST_AMOUNT1", uint256(0)) > 0;
        
        if (runFullFlow) {
            console.log("\n=== Running Full Flow Tests ===");
            vm.startBroadcast(deployerPrivateKey);
            runFullFlowTests(address(rebalancer), deployer);
            vm.stopBroadcast();
        } else {
            console.log("\n[INFO] Skipping full flow tests (TEST_AMOUNT0 and TEST_AMOUNT1 not set)");
            console.log("      Set TEST_AMOUNT0, TEST_AMOUNT1, TEST_TICK_LOWER, TEST_TICK_UPPER in .env to run full flow");
        }

        console.log("\n=== Deployment and Testing Completed! ===");
    }

    function runIntegrationTests(
        address rebalancerAddr,
        address nftManager,
        address gaugeAddr,
        address owner
    ) internal view {
        Rebalancer rebalancer_ = Rebalancer(rebalancerAddr);
        ICLGauge gauge_ = ICLGauge(gaugeAddr);

        // Check 1: Contract initialization
        console.log("\n[Test 1] Checking contract initialization...");
        require(address(rebalancer_.nft()) == nftManager, "NFT manager address mismatch");
        require(address(rebalancer_.gauge()) == gaugeAddr, "Gauge address mismatch");
        require(rebalancer_.owner() == owner, "Owner address mismatch");
        console.log("[OK] Contract initialized correctly");

        // Check 2: Get tokens from gauge
        console.log("\n[Test 2] Checking tokens from gauge...");
        address token0Addr = gauge_.token0();
        address token1Addr = gauge_.token1();
        int24 tickSpacing = gauge_.tickSpacing();

        require(token0Addr != address(0), "Token0 address is zero");
        require(token1Addr != address(0), "Token1 address is zero");
        require(token0Addr != token1Addr, "Token0 and Token1 must be different");

        address rebalancerToken0 = address(rebalancer_.token0());
        address rebalancerToken1 = address(rebalancer_.token1());

        require(rebalancerToken0 == token0Addr, "Rebalancer token0 mismatch with gauge");
        require(rebalancerToken1 == token1Addr, "Rebalancer token1 mismatch with gauge");
        require(rebalancer_.tickSpacing() == tickSpacing, "TickSpacing mismatch");

        console.log("[OK] Token0:", token0Addr);
        console.log("[OK] Token1:", token1Addr);
        console.log("[OK] TickSpacing:", uint256(int256(tickSpacing)));

        // Check 3: ERC20 token balance check
        console.log("\n[Test 3] Checking ERC20 token balances...");
        uint256 token0Balance = IERC20(token0Addr).balanceOf(rebalancerAddr);
        uint256 token1Balance = IERC20(token1Addr).balanceOf(rebalancerAddr);

        console.log("[OK] Token0 balance in Rebalancer:", token0Balance);
        console.log("[OK] Token1 balance in Rebalancer:", token1Balance);

        // Check 4: Current position check
        console.log("\n[Test 4] Checking current position...");
        uint256 currentTokenId = rebalancer_.currentTokenId();
        if (currentTokenId == 0) {
            console.log("[OK] No active positions (expected for new deployment)");
        } else {
            console.log("[OK] Active position found, tokenId:", currentTokenId);
        }

        // Check 5: Token symbol and name check (if available)
        console.log("\n[Test 5] Checking token metadata...");
        try this.getTokenSymbol(token0Addr) returns (string memory symbol) {
            console.log("[OK] Token0 symbol:", symbol);
        } catch {
            console.log("[WARN] Token0 symbol not available");
        }

        try this.getTokenSymbol(token1Addr) returns (string memory symbol) {
            console.log("[OK] Token1 symbol:", symbol);
        } catch {
            console.log("[WARN] Token1 symbol not available");
        }

        console.log("\n=== All Integration Tests Passed! ===");
    }

    // Helper function to get token symbol
    function getTokenSymbol(address token) external view returns (string memory) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("symbol()")
        );
        if (success && data.length > 0) {
            return abi.decode(data, (string));
        }
        return "";
    }

    /**
     * @notice Executes full flow: deposit -> rebalance -> closeAll -> withdrawAll
     * @dev This function requires TEST_AMOUNT0, TEST_AMOUNT1, and optionally TEST_TICK_LOWER/TEST_TICK_UPPER
     */
    function runFullFlowTests(address rebalancerAddr, address deployer) internal {
        Rebalancer rebalancer_ = Rebalancer(rebalancerAddr);
        IERC20 token0_ = rebalancer_.token0();
        IERC20 token1_ = rebalancer_.token1();
        
        // Get test parameters
        uint256 amount0 = vm.envUint("TEST_AMOUNT0");
        uint256 amount1 = vm.envUint("TEST_AMOUNT1");
        
        // Calculate valid ticks (rounded to tickSpacing)
        int24 tickLower;
        int24 tickUpper;
        {
            int24 spacing = rebalancer_.tickSpacing();
            int256 spacing256 = int256(spacing);
            
            // Try to read from env, or use defaults that are already multiples of spacing
            int256 defaultLower = -887200; // Already multiple of 100
            int256 defaultUpper = 887200;  // Already multiple of 100
            
            int256 rawLower = vm.envOr("TEST_TICK_LOWER", defaultLower);
            int256 rawUpper = vm.envOr("TEST_TICK_UPPER", defaultUpper);
            
            // Round to nearest valid tick (multiple of spacing)
            tickLower = int24((rawLower / spacing256) * spacing256);
            tickUpper = int24((rawUpper / spacing256) * spacing256);
            
            // Ensure valid range
            require(tickLower < tickUpper, "tickLower must be less than tickUpper");
            require(tickLower >= -887272 && tickUpper <= 887272, "Ticks out of valid range");
            
            console.log("\n[Full Flow] Test Parameters:");
            console.log("  Amount0:", amount0);
            console.log("  Amount1:", amount1);
            console.log("  TickSpacing:", uint256(uint24(spacing)));
            console.log("  TickLower (raw):", rawLower);
            console.log("  TickUpper (raw):", rawUpper);
            console.log("  TickLower (rounded):", tickLower);
            console.log("  TickUpper (rounded):", tickUpper);
        }
        
        // Check initial balances
        {
            console.log("\n[Step 0] Checking initial balances...");
            uint256 deployerBalance0 = token0_.balanceOf(deployer);
            uint256 deployerBalance1 = token1_.balanceOf(deployer);
            console.log("  Deployer Token0 balance:", deployerBalance0);
            console.log("  Deployer Token1 balance:", deployerBalance1);
            console.log("  Contract Token0 balance:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance:", token1_.balanceOf(rebalancerAddr));
            require(deployerBalance0 >= amount0, "Insufficient Token0 balance");
            require(deployerBalance1 >= amount1, "Insufficient Token1 balance");
        }
        
        // Step 1: Approve tokens
        {
            console.log("\n[Step 1] Approving tokens...");
            // Approve sufficient amount for operations (fees may be collected, so approve more than needed)
            require(token0_.approve(rebalancerAddr, amount0 * 3), "Token0 approval failed");
            require(token1_.approve(rebalancerAddr, amount1 * 3), "Token1 approval failed");
            console.log("[OK] Tokens approved");
        }
        
        // Step 2: Deposit tokens
        {
            console.log("\n[Step 2] Depositing tokens...");
            rebalancer_.deposit(amount0, amount1);
            uint256 balance0 = token0_.balanceOf(rebalancerAddr);
            uint256 balance1 = token1_.balanceOf(rebalancerAddr);
            console.log("  Contract Token0 balance after deposit:", balance0);
            console.log("  Contract Token1 balance after deposit:", balance1);
            require(balance0 >= amount0, "Token0 deposit failed");
            require(balance1 >= amount1, "Token1 deposit failed");
            console.log("[OK] Deposit completed");
        }
        
        // Step 3: First Rebalance
        {
            console.log("\n[Step 3] First Rebalance (creating position)...");
            console.log("  TokenId before rebalance:", rebalancer_.currentTokenId());
            rebalancer_.rebalance(tickLower, tickUpper);
            uint256 tokenId1 = rebalancer_.currentTokenId();
            require(tokenId1 != 0, "First rebalance failed: tokenId is zero");
            console.log("  TokenId after first rebalance:", tokenId1);
            console.log("  Contract Token0 balance:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance:", token1_.balanceOf(rebalancerAddr));
            console.log("[OK] First rebalance completed, position created");
        }
        
        // Step 4: Second Rebalance (will close first position and create new one)
        {
            console.log("\n[Step 4] Second Rebalance (rebalancing existing position)...");
            uint256 tokenId1 = rebalancer_.currentTokenId();
            console.log("  TokenId before second rebalance:", tokenId1);
            {
                uint256 bal0 = token0_.balanceOf(rebalancerAddr);
                uint256 bal1 = token1_.balanceOf(rebalancerAddr);
                console.log("  Contract Token0 balance before:", bal0);
                console.log("  Contract Token1 balance before:", bal1);
            }
            
            // Rebalance will close the first position and create a new one
            rebalancer_.rebalance(tickLower, tickUpper);
            
            uint256 tokenId2 = rebalancer_.currentTokenId();
            require(tokenId2 != 0, "Second rebalance failed: tokenId is zero");
            // Verify that a new position was created (tokenId should be different from the first one)
            require(tokenId2 != tokenId1, "Second rebalance should create new position with different tokenId");
            console.log("  TokenId after second rebalance:", tokenId2);
            console.log("  Contract Token0 balance after:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance after:", token1_.balanceOf(rebalancerAddr));
            console.log("[OK] Second rebalance completed, new position created (first position closed)");
        }
        
        // Step 5: Close all positions
        {
            console.log("\n[Step 5] Closing all positions...");
            uint256 tokenIdBeforeClose = rebalancer_.currentTokenId();
            require(tokenIdBeforeClose != 0, "No position to close after second rebalance");
            console.log("  TokenId before close:", tokenIdBeforeClose);
            console.log("  Contract Token0 balance before close:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance before close:", token1_.balanceOf(rebalancerAddr));
            
            rebalancer_.closeAllPositions();
            
            uint256 tokenIdAfterClose = rebalancer_.currentTokenId();
            console.log("  TokenId after close:", tokenIdAfterClose);
            console.log("  Contract Token0 balance after close:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance after close:", token1_.balanceOf(rebalancerAddr));
            
            require(tokenIdAfterClose == 0, "Close position failed: tokenId is not zero");
            console.log("[OK] All positions closed successfully");
        }
        
        // Step 6: Withdraw all funds
        {
            console.log("\n[Step 6] Withdrawing all funds...");
            address owner = rebalancer_.owner();
            uint256 ownerBalance0Before = token0_.balanceOf(owner);
            uint256 ownerBalance1Before = token1_.balanceOf(owner);
            rebalancer_.withdrawAll();
            console.log("  Owner Token0 balance:", token0_.balanceOf(owner));
            console.log("  Owner Token1 balance:", token1_.balanceOf(owner));
            console.log("  Final contract Token0 balance:", token0_.balanceOf(rebalancerAddr));
            console.log("  Final contract Token1 balance:", token1_.balanceOf(rebalancerAddr));
            require(token0_.balanceOf(rebalancerAddr) == 0, "Contract should have no Token0");
            require(token1_.balanceOf(rebalancerAddr) == 0, "Contract should have no Token1");
            console.log("[OK] Withdraw completed");
        }
        
        console.log("\n=== Full Flow Tests Completed Successfully! ===");
    }
}

