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
            // Verify that owner is set correctly
            address contractOwner = rebalancer.owner();
            require(contractOwner == owner, "Contract owner mismatch");
            console.log("  Contract owner:", contractOwner);
            
            // Use owner's private key if different from deployer, otherwise use deployer's key
            uint256 ownerPrivateKey;
            if (owner != deployer) {
                // Try to get owner's private key from env
                ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
                address ownerFromKey = vm.addr(ownerPrivateKey);
                require(ownerFromKey == owner, "OWNER_PRIVATE_KEY does not match OWNER_ADDRESS");
                console.log("[INFO] Using owner's private key for transactions");
            } else {
                ownerPrivateKey = deployerPrivateKey;
            }
            vm.startBroadcast(ownerPrivateKey);
            runFullFlowTests(address(rebalancer), owner);
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
        _checkTokensFromGauge(rebalancer_, gauge_, gaugeAddr);

        // Check 3: ERC20 token balance check
        _checkTokenBalances(rebalancerAddr);

        // Check 4: Current position check
        console.log("\n[Test 4] Checking current position...");
        uint256 currentTokenId = rebalancer_.currentTokenId();
        if (currentTokenId == 0) {
            console.log("[OK] No active positions (expected for new deployment)");
        } else {
            console.log("[OK] Active position found, tokenId:", currentTokenId);
        }

        // Check 5: Token symbol and name check (if available)
        _checkTokenMetadata(rebalancer_);

        // Check 6: Reward token check
        _checkRewardToken(rebalancer_, gauge_, gaugeAddr, rebalancerAddr);

        console.log("\n=== All Integration Tests Passed! ===");
    }

    function _checkTokensFromGauge(Rebalancer rebalancer_, ICLGauge gauge_, address gaugeAddr) internal view {
        console.log("\n[Test 2] Checking tokens from gauge...");
        
        uint256 gaugeCodeSize;
        assembly {
            gaugeCodeSize := extcodesize(gaugeAddr)
        }
        
        address token0Addr;
        address token1Addr;
        int24 tickSpacing;
        
        // Try to get from rebalancer first (it will call gauge internally)
        (bool success0, bytes memory data0) = address(rebalancer_).staticcall(abi.encodeWithSignature("token0()"));
        if (success0 && data0.length >= 32) {
            token0Addr = abi.decode(data0, (address));
        }
        
        (bool success1, bytes memory data1) = address(rebalancer_).staticcall(abi.encodeWithSignature("token1()"));
        if (success1 && data1.length >= 32) {
            token1Addr = abi.decode(data1, (address));
        }
        
        (bool success2, bytes memory data2) = address(rebalancer_).staticcall(abi.encodeWithSignature("tickSpacing()"));
        if (success2 && data2.length >= 32) {
            tickSpacing = abi.decode(data2, (int24));
        }
        
        // If gauge exists, try to verify values match
        if (gaugeCodeSize > 0 && token0Addr != address(0)) {
            (bool success, bytes memory data) = address(gauge_).staticcall(abi.encodeWithSignature("token0()"));
            if (success && data.length >= 32) {
                address addr = abi.decode(data, (address));
                if (addr != address(0) && addr != token0Addr) {
                    console.log("[WARN] Token0 mismatch between gauge and rebalancer");
                }
            }
        }

        if (token0Addr == address(0) || token1Addr == address(0)) {
            console.log("[WARN] Cannot get token addresses - gauge contract may not be deployed");
            console.log("[INFO] This is expected in test environments without real contracts");
            return;
        }

        require(token0Addr != token1Addr, "Token0 and Token1 must be different");
        console.log("[OK] Token0:", token0Addr);
        console.log("[OK] Token1:", token1Addr);
        console.log("[OK] TickSpacing:", uint256(int256(tickSpacing)));
    }

    function _checkTokenBalances(address rebalancerAddr) internal view {
        console.log("\n[Test 3] Checking ERC20 token balances...");
        Rebalancer rebalancer_ = Rebalancer(rebalancerAddr);
        (bool success0, bytes memory data0) = address(rebalancer_).staticcall(abi.encodeWithSignature("token0()"));
        (bool success1, bytes memory data1) = address(rebalancer_).staticcall(abi.encodeWithSignature("token1()"));
        
        if (success0 && success1 && data0.length >= 32 && data1.length >= 32) {
            address token0Addr = abi.decode(data0, (address));
            address token1Addr = abi.decode(data1, (address));
            if (token0Addr != address(0) && token1Addr != address(0)) {
                console.log("[OK] Token0 balance:", IERC20(token0Addr).balanceOf(rebalancerAddr));
                console.log("[OK] Token1 balance:", IERC20(token1Addr).balanceOf(rebalancerAddr));
            } else {
                console.log("[WARN] Token addresses are zero");
            }
        } else {
            console.log("[WARN] Cannot get token addresses for balance check");
        }
    }

    function _checkTokenMetadata(Rebalancer rebalancer_) internal view {
        console.log("\n[Test 5] Checking token metadata...");
        (bool success0, bytes memory data0) = address(rebalancer_).staticcall(abi.encodeWithSignature("token0()"));
        (bool success1, bytes memory data1) = address(rebalancer_).staticcall(abi.encodeWithSignature("token1()"));
        
        if (success0 && data0.length >= 32) {
            address token0Addr = abi.decode(data0, (address));
            if (token0Addr != address(0)) {
                try this.getTokenSymbol(token0Addr) returns (string memory symbol) {
                    console.log("[OK] Token0 symbol:", symbol);
                } catch {
                    console.log("[WARN] Token0 symbol not available");
                }
            }
        }
        
        if (success1 && data1.length >= 32) {
            address token1Addr = abi.decode(data1, (address));
            if (token1Addr != address(0)) {
                try this.getTokenSymbol(token1Addr) returns (string memory symbol) {
                    console.log("[OK] Token1 symbol:", symbol);
                } catch {
                    console.log("[WARN] Token1 symbol not available");
                }
            }
        }
    }

    function _checkRewardToken(Rebalancer rebalancer_, ICLGauge gauge_, address gaugeAddr, address rebalancerAddr) internal view {
        console.log("\n[Test 6] Checking reward token...");
        (bool success, bytes memory data) = address(rebalancer_).staticcall(abi.encodeWithSignature("rewardToken()"));
        
        if (!success || data.length < 32) {
            console.log("[WARN] Cannot get reward token from rebalancer");
            return;
        }
        
        address rewardTokenAddr = abi.decode(data, (address));
        
        if (rewardTokenAddr != address(0)) {
            console.log("[OK] Reward token:", rewardTokenAddr);
            try this.getTokenSymbol(rewardTokenAddr) returns (string memory symbol) {
                console.log("[OK] Reward token symbol:", symbol);
            } catch {
                console.log("[WARN] Reward token symbol not available");
            }
            (bool success2, bytes memory data2) = rewardTokenAddr.staticcall(
                abi.encodeWithSignature("balanceOf(address)", rebalancerAddr)
            );
            if (success2 && data2.length >= 32) {
                console.log("[OK] Reward token balance:", abi.decode(data2, (uint256)));
            }
        } else {
            console.log("[WARN] Reward token address is zero");
        }
    }

    function _calculateTicks(Rebalancer rebalancer_, uint256 amount0, uint256 amount1) internal view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = rebalancer_.tickSpacing();
        int256 spacing256 = int256(spacing);
        int256 defaultLower = -887200;
        int256 defaultUpper = 887200;
        int256 rawLower = vm.envOr("TEST_TICK_LOWER", defaultLower);
        int256 rawUpper = vm.envOr("TEST_TICK_UPPER", defaultUpper);
        tickLower = int24((rawLower / spacing256) * spacing256);
        tickUpper = int24((rawUpper / spacing256) * spacing256);
        require(tickLower < tickUpper, "tickLower must be less than tickUpper");
        require(tickLower >= -887272 && tickUpper <= 887272, "Ticks out of valid range");
        console.log("\n[Full Flow] Test Parameters:");
        console.log("  Amount0:", amount0);
        console.log("  Amount1:", amount1);
        console.log("  TickSpacing:", uint256(uint24(spacing)));
        console.log("  TickLower:", tickLower);
        console.log("  TickUpper:", tickUpper);
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
     * @notice Tests the swap method
     * @param rebalancer_ Rebalancer contract instance
     * @param token0_ Token0 instance
     * @param token1_ Token1 instance
     * @param rebalancerAddr Rebalancer contract address
     * @param depositedAmount0 Amount of token0 that was deposited
     * @param depositedAmount1 Amount of token1 that was deposited
     */
    function _testSwap(
        Rebalancer rebalancer_,
        IERC20 token0_,
        IERC20 token1_,
        address rebalancerAddr,
        uint256 depositedAmount0,
        uint256 depositedAmount1
    ) internal {
        uint256 balance0Before = token0_.balanceOf(rebalancerAddr);
        uint256 balance1Before = token1_.balanceOf(rebalancerAddr);
        console.log("  Contract Token0 balance before swap:", balance0Before);
        console.log("  Contract Token1 balance before swap:", balance1Before);
        
        // Use 80% of available amounts for swap (leaving some for gas and other operations)
        uint256 swapAmount0 = (depositedAmount0 * 80) / 100;
        uint256 swapAmount1 = (depositedAmount1 * 80) / 100;
        
        // Determine swap direction - prefer token0 -> token1 if possible
        bool swapToken0ForToken1 = balance0Before >= swapAmount0 && swapAmount0 > 0;
        uint256 actualSwapAmount = swapToken0ForToken1 ? swapAmount0 : swapAmount1;
        
        if (actualSwapAmount == 0 || (swapToken0ForToken1 ? balance0Before < swapAmount0 : balance1Before < swapAmount1)) {
            console.log("  [SKIP] Insufficient balance for swap");
            return;
        }
        
        address tokenIn = swapToken0ForToken1 ? address(token0_) : address(token1_);
        address tokenOut = swapToken0ForToken1 ? address(token1_) : address(token0_);
        
        console.log("  Using 80% of available amounts for swap:");
        console.log("    Available Token0:", depositedAmount0);
        console.log("    Available Token1:", depositedAmount1);
        console.log("    Swap amount:", actualSwapAmount);
        
        // Perform swap
        (int256 amount0Delta, int256 amount1Delta) = rebalancer_.swap(
            tokenIn,
            tokenOut,
            actualSwapAmount,
            0,
            swapToken0ForToken1
        );
        
        // Verify swap results
        // Note: amount0Delta and amount1Delta can be zero if swap didn't produce output
        // (e.g., price limit reached or insufficient liquidity)
        if (swapToken0ForToken1) {
            // Swapping token0 -> token1: amount0Delta >= 0 (we pay), amount1Delta <= 0 (we receive)
            require(amount0Delta >= 0, "amount0Delta should be non-negative");
            require(amount1Delta <= 0, "amount1Delta should be non-positive");
            // At least one delta should be non-zero for swap to have executed
            require(amount0Delta != 0 || amount1Delta != 0, "Swap did not execute");
            // If swap produced output, balances should change
            if (amount1Delta < 0) {
                // We received token1, so balance should increase
                require(token1_.balanceOf(rebalancerAddr) > balance1Before, "Token1 balance should increase");
                // We paid token0, so balance should decrease (or stay same if we had extra)
                // Note: balance might not decrease if there were tokens already in contract
            }
        } else {
            // Swapping token1 -> token0: amount1Delta >= 0 (we pay), amount0Delta <= 0 (we receive)
            require(amount1Delta >= 0, "amount1Delta should be non-negative");
            require(amount0Delta <= 0, "amount0Delta should be non-positive");
            // At least one delta should be non-zero for swap to have executed
            require(amount0Delta != 0 || amount1Delta != 0, "Swap did not execute");
            // If swap produced output, balances should change
            if (amount0Delta < 0) {
                // We received token0, so balance should increase
                require(token0_.balanceOf(rebalancerAddr) > balance0Before, "Token0 balance should increase");
                // We paid token1, so balance should decrease (or stay same if we had extra)
                // Note: balance might not decrease if there were tokens already in contract
            }
        }
        
        console.log("[OK] Swap completed successfully");
    }

    /**
     * @notice Executes full flow: deposit -> rebalance -> closeAll -> withdrawAll
     * @dev This function requires TEST_AMOUNT0, TEST_AMOUNT1, and optionally TEST_TICK_LOWER/TEST_TICK_UPPER
     */
    function runFullFlowTests(address rebalancerAddr, address ownerAddr) internal {
        Rebalancer rebalancer_ = Rebalancer(rebalancerAddr);
        
        // Try to get token addresses
        (bool success0, bytes memory data0) = address(rebalancer_).staticcall(abi.encodeWithSignature("token0()"));
        (bool success1, bytes memory data1) = address(rebalancer_).staticcall(abi.encodeWithSignature("token1()"));
        
        if (!success0 || !success1 || data0.length < 32 || data1.length < 32) {
            console.log("[ERROR] Cannot get token addresses - gauge contract may not be deployed");
            console.log("[INFO] Full flow tests require deployed gauge and token contracts");
            return;
        }
        
        address token0Addr = abi.decode(data0, (address));
        address token1Addr = abi.decode(data1, (address));
        IERC20 token0_ = IERC20(token0Addr);
        IERC20 token1_ = IERC20(token1Addr);
        
        uint256 amount0 = vm.envUint("TEST_AMOUNT0");
        uint256 amount1 = vm.envUint("TEST_AMOUNT1");
        (int24 tickLower, int24 tickUpper) = _calculateTicks(rebalancer_, amount0, amount1);
        
        console.log("\n[Step 0] Checking initial balances...");
        uint256 bal0 = token0_.balanceOf(ownerAddr);
        uint256 bal1 = token1_.balanceOf(ownerAddr);
        console.log("  Owner Token0 balance:", bal0);
        console.log("  Owner Token1 balance:", bal1);
        require(bal0 >= amount0, "Insufficient Token0 balance");
        require(bal1 >= amount1, "Insufficient Token1 balance");
        
        console.log("\n[Step 1] Approving tokens...");
        require(token0_.approve(rebalancerAddr, amount0 * 3), "Token0 approval failed");
        require(token1_.approve(rebalancerAddr, amount1 * 3), "Token1 approval failed");
        console.log("[OK] Tokens approved");
        
        console.log("\n[Step 2] Depositing tokens...");
        rebalancer_.deposit(amount0, amount1);
        uint256 balance0 = token0_.balanceOf(rebalancerAddr);
        uint256 balance1 = token1_.balanceOf(rebalancerAddr);
        console.log("  Contract Token0 balance after deposit:", balance0);
        console.log("  Contract Token1 balance after deposit:", balance1);
        require(balance0 >= amount0, "Token0 deposit failed");
        require(balance1 >= amount1, "Token1 deposit failed");
        console.log("[OK] Deposit completed");
        
        // Step 3: First Rebalance (create initial position)
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
        
        // Step 4: Test Swap (uses available balances after position creation)
        {
            console.log("\n[Step 4] Testing swap method...");
            uint256 bal0 = token0_.balanceOf(rebalancerAddr);
            uint256 bal1 = token1_.balanceOf(rebalancerAddr);
            _testSwap(rebalancer_, token0_, token1_, rebalancerAddr, bal0 > 0 ? bal0 : amount0 / 4, bal1 > 0 ? bal1 : amount1 / 4);
        }
        
        // Step 4.5: Test SwapByRatio
        {
            console.log("\n[Step 4.5] Testing swapByRatio method...");
            uint256 bal0 = token0_.balanceOf(rebalancerAddr);
            uint256 bal1 = token1_.balanceOf(rebalancerAddr);
            
            if (bal0 > 0 && bal1 > 0) {
                uint256 targetRatio = ((bal0 * 1e18) / bal1) > 15e17 ? 1e18 : 2e18;
                console.log("  Target ratio (token0/token1):", targetRatio);
                
                (int256 amount0Delta, int256 amount1Delta) = rebalancer_.swapByRatio(targetRatio, 1e16);
                
                console.log("  SwapByRatio result:");
                console.log("    amount0Delta:", amount0Delta);
                console.log("    amount1Delta:", amount1Delta);
                require(amount0Delta != 0 || amount1Delta != 0, "SwapByRatio did not execute");
                console.log("[OK] SwapByRatio completed successfully");
            } else {
                console.log("  [SKIP] Insufficient balances for swapByRatio");
            }
        }
        
        // Step 5: Second Rebalance (will close first position and create new one)
        {
            console.log("\n[Step 5] Second Rebalance (rebalancing existing position)...");
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
        
        // Step 6: Close all positions
        {
            console.log("\n[Step 6] Closing all positions...");
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
        
        // Step 7: Withdraw all funds
        {
            console.log("\n[Step 7] Withdrawing all funds...");
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
        
        // Step 8: Withdraw reward tokens (AERO)
        {
            console.log("\n[Step 8] Withdrawing reward tokens (AERO)...");
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

