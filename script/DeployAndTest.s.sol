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

        // Check 6: Reward token check
        console.log("\n[Test 6] Checking reward token...");
        address rewardTokenAddr = gauge_.rewardToken();
        require(rewardTokenAddr != address(0), "Reward token address is zero");
        
        address rebalancerRewardToken = address(rebalancer_.rewardToken());
        require(rebalancerRewardToken == rewardTokenAddr, "Rebalancer reward token mismatch with gauge");
        
        console.log("[OK] Reward token:", rewardTokenAddr);
        try this.getTokenSymbol(rewardTokenAddr) returns (string memory symbol) {
            console.log("[OK] Reward token symbol:", symbol);
        } catch {
            console.log("[WARN] Reward token symbol not available");
        }
        
        uint256 rewardBalance = IERC20(rewardTokenAddr).balanceOf(address(rebalancer_));
        console.log("[OK] Reward token balance in Rebalancer:", rewardBalance);

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
            console.log("  Required Token0 amount:", amount0);
            console.log("  Required Token1 amount:", amount1);
            console.log("  Deployer Token0 balance:", deployerBalance0);
            console.log("  Deployer Token1 balance:", deployerBalance1);
            console.log("  Contract Token0 balance:", token0_.balanceOf(rebalancerAddr));
            console.log("  Contract Token1 balance:", token1_.balanceOf(rebalancerAddr));
            
            // Check if we have at least one token (contract can work with single token)
            bool hasToken0 = deployerBalance0 >= amount0;
            bool hasToken1 = deployerBalance1 >= amount1;
            
            if (!hasToken0 && !hasToken1) {
                console.log("  [ERROR] Insufficient balances for both tokens!");
                console.log("    Need Token0:", amount0, "Have:", deployerBalance0);
                console.log("    Need Token1:", amount1, "Have:", deployerBalance1);
                revert("Insufficient balances: need at least one token (Token0 or Token1) to proceed");
            }
            
            if (!hasToken0) {
                console.log("  [WARN] Insufficient Token0 balance - will test with Token1 only");
                console.log("    Need Token0:", amount0, "Have:", deployerBalance0);
                amount0 = 0; // Set to zero to allow single token test
            }
            
            if (!hasToken1) {
                console.log("  [WARN] Insufficient Token1 balance - will test with Token0 only");
                console.log("    Need Token1:", amount1, "Have:", deployerBalance1);
                amount1 = 0; // Set to zero to allow single token test
            }
            
            if (hasToken0 && hasToken1) {
                console.log("  [OK] Sufficient balances for both tokens");
            } else {
                console.log("  [INFO] Will proceed with single token test (as supported by rebalance function)");
            }
        }
        
        // Step 1: Approve tokens
        {
            console.log("\n[Step 1] Approving tokens...");
            // Approve sufficient amount for operations (fees may be collected, so approve more than needed)
            // Only approve if amount > 0 (allows single token operation)
            if (amount0 > 0) {
                require(token0_.approve(rebalancerAddr, amount0 * 3), "Token0 approval failed");
                console.log("  Token0 approved:", amount0 * 3);
            }
            if (amount1 > 0) {
                require(token1_.approve(rebalancerAddr, amount1 * 3), "Token1 approval failed");
                console.log("  Token1 approved:", amount1 * 3);
            }
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
            
            // Check deposits - allow zero amounts for single token operations
            if (amount0 > 0) {
                require(balance0 >= amount0, "Token0 deposit failed");
            }
            if (amount1 > 0) {
                require(balance1 >= amount1, "Token1 deposit failed");
            }
            console.log("[OK] Deposit completed");
        }
        
        // Step 3: First Rebalance
        {
            console.log("\n[Step 3] First Rebalance (creating position)...");
            console.log("  TokenId before rebalance:", rebalancer_.currentTokenId());
            
            uint256 balance0Before = token0_.balanceOf(rebalancerAddr);
            uint256 balance1Before = token1_.balanceOf(rebalancerAddr);
            console.log("  Contract Token0 balance before rebalance:", balance0Before);
            console.log("  Contract Token1 balance before rebalance:", balance1Before);
            
            rebalancer_.rebalance(tickLower, tickUpper);
            
            uint256 tokenId1 = rebalancer_.currentTokenId();
            require(tokenId1 != 0, "First rebalance failed: tokenId is zero");
            console.log("  TokenId after first rebalance:", tokenId1);
            
            uint256 balance0After = token0_.balanceOf(rebalancerAddr);
            uint256 balance1After = token1_.balanceOf(rebalancerAddr);
            console.log("  Contract Token0 balance after rebalance:", balance0After);
            console.log("  Contract Token1 balance after rebalance:", balance1After);
            
            // Check that most tokens were used (allow small remainder for rounding/approximation)
            // Typically, if price is within range, both tokens should be mostly used
            // If price is outside range, one token should be fully used, other may remain
            // We allow up to 1% remainder or 1000 wei (whichever is larger) for rounding errors
            uint256 threshold0 = balance0Before / 100 > 1000 ? balance0Before / 100 : 1000;
            uint256 threshold1 = balance1Before / 100 > 1000 ? balance1Before / 100 : 1000;
            
            bool token0UsedWell = balance0After <= threshold0 || balance0Before == 0;
            bool token1UsedWell = balance1After <= threshold1 || balance1Before == 0;
            
            // At least one token should be well utilized (or both if price is in range)
            require(token0UsedWell || token1UsedWell, 
                "Balance utilization check failed: significant amounts of both tokens remain unused");
            
            uint256 utilization0 = balance0Before > 0 && balance0After < balance0Before 
                ? ((balance0Before - balance0After) * 100) / balance0Before 
                : 0;
            uint256 utilization1 = balance1Before > 0 && balance1After < balance1Before 
                ? ((balance1Before - balance1After) * 100) / balance1Before 
                : 0;
            
            console.log("  Token0 utilization: % used, % remaining", utilization0, balance0After);
            console.log("  Token1 utilization: % used, % remaining", utilization1, balance1After);
            
            if (balance0After > threshold0 && balance1After > threshold1) {
                console.log("  [WARN] Both tokens have significant remainders - price may be outside tick range");
            } else {
                console.log("  [OK] Balance utilization is acceptable");
            }
            
            console.log("[OK] First rebalance completed, position created");
        }
        
        // Step 4: Second Rebalance (will close first position and create new one)
        {
            console.log("\n[Step 4] Second Rebalance (rebalancing existing position)...");
            uint256 tokenId1;
            uint256 balance0Before;
            uint256 balance1Before;
            {
                tokenId1 = rebalancer_.currentTokenId();
                console.log("  TokenId before second rebalance:", tokenId1);
                
                balance0Before = token0_.balanceOf(rebalancerAddr);
                balance1Before = token1_.balanceOf(rebalancerAddr);
                console.log("  Contract Token0 balance before:", balance0Before);
                console.log("  Contract Token1 balance before:", balance1Before);
            }
            
            // Rebalance will close the first position and create a new one
            rebalancer_.rebalance(tickLower, tickUpper);
            
            {
                uint256 tokenId2 = rebalancer_.currentTokenId();
                require(tokenId2 != 0, "Second rebalance failed: tokenId is zero");
                // Verify that a new position was created (tokenId should be different from the first one)
                require(tokenId2 != tokenId1, "Second rebalance should create new position with different tokenId");
                console.log("  TokenId after second rebalance:", tokenId2);
            }
            
            {
                uint256 balance0After = token0_.balanceOf(rebalancerAddr);
                uint256 balance1After = token1_.balanceOf(rebalancerAddr);
                console.log("  Contract Token0 balance after:", balance0After);
                console.log("  Contract Token1 balance after:", balance1After);
                
                // After closing the first position and creating new one, we should have:
                // 1. Tokens from closed position collected
                // 2. Most tokens should be used in the new position
                // Check utilization after second rebalance
                uint256 threshold0 = balance0Before / 100 > 1000 ? balance0Before / 100 : 1000;
                uint256 threshold1 = balance1Before / 100 > 1000 ? balance1Before / 100 : 1000;
                
                bool token0UsedWell = balance0After <= threshold0 || balance0Before == 0;
                bool token1UsedWell = balance1After <= threshold1 || balance1Before == 0;
                
                // At least one token should be well utilized
                require(token0UsedWell || token1UsedWell, 
                    "Balance utilization check failed after second rebalance: significant amounts of both tokens remain unused");
                
                uint256 utilization0 = balance0Before > 0 && balance0After < balance0Before 
                    ? ((balance0Before - balance0After) * 100) / balance0Before 
                    : 0;
                uint256 utilization1 = balance1Before > 0 && balance1After < balance1Before 
                    ? ((balance1Before - balance1After) * 100) / balance1Before 
                    : 0;
                
                console.log("  Token0 utilization: % used, % remaining", utilization0, balance0After);
                console.log("  Token1 utilization: % used, % remaining", utilization1, balance1After);
                
                if (balance0After > threshold0 && balance1After > threshold1) {
                    console.log("  [WARN] Both tokens have significant remainders after second rebalance");
                } else {
                    console.log("  [OK] Balance utilization after second rebalance is acceptable");
                }
            }
            
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
        
        // Step 7: Withdraw reward tokens (AERO)
        {
            console.log("\n[Step 7] Withdrawing reward tokens (AERO)...");
            address owner = rebalancer_.owner();
            IERC20 rewardToken_ = rebalancer_.rewardToken();
            
            uint256 rewardBalanceBefore = rewardToken_.balanceOf(rebalancerAddr);
            uint256 ownerRewardBalanceBefore = rewardToken_.balanceOf(owner);
            
            console.log("  Contract reward token balance before:", rewardBalanceBefore);
            console.log("  Owner reward token balance before:", ownerRewardBalanceBefore);
            console.log("  Reward token address:", address(rewardToken_));
            
            if (rewardBalanceBefore > 0) {
                rebalancer_.withdrawRewards();
                
                uint256 rewardBalanceAfter = rewardToken_.balanceOf(rebalancerAddr);
                uint256 ownerRewardBalanceAfter = rewardToken_.balanceOf(owner);
                
                console.log("  Contract reward token balance after:", rewardBalanceAfter);
                console.log("  Owner reward token balance after:", ownerRewardBalanceAfter);
                
                require(rewardBalanceAfter == 0, "Contract should have no reward tokens after withdrawal");
                require(ownerRewardBalanceAfter == ownerRewardBalanceBefore + rewardBalanceBefore, "Reward tokens not transferred correctly");
                console.log("[OK] Reward tokens withdrawn successfully");
            } else {
                console.log("  No reward tokens to withdraw (balance is zero)");
                // Even with zero balance, withdrawRewards should work
                rebalancer_.withdrawRewards();
                console.log("[OK] withdrawRewards() executed successfully with zero balance");
            }
        }
        
        console.log("\n=== Full Flow Tests Completed Successfully! ===");
    }
}

