// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CloseAndWithdrawScript is Script {
    function run() external {
        // Load required environment variables from .env file
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get contract address from environment variable
        address rebalancerAddr = vm.envAddress("REBALANCER_ADDRESS");
        
        console.log("Executing close and withdraw operations...");
        console.log("Deployer address:", deployer);
        console.log("Rebalancer contract:", rebalancerAddr);

        Rebalancer rebalancer = Rebalancer(rebalancerAddr);
        
        // Verify deployer is owner
        address contractOwner = rebalancer.owner();
        require(contractOwner == deployer, 
            string.concat(
                "Deployer is not the owner of the contract. ",
                "Deployer: ",
                vm.toString(deployer),
                ", Owner: ",
                vm.toString(contractOwner)
            )
        );
        
        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Close all positions
        {
            console.log("\n[Step 1] Closing all positions...");
            uint256 currentTokenId = rebalancer.currentTokenId();
            
            if (currentTokenId == 0) {
                console.log("[INFO] No active positions to close");
            } else {
                console.log("  Current tokenId:", currentTokenId);
                rebalancer.closeAllPositions();
                
                uint256 tokenIdAfter = rebalancer.currentTokenId();
                require(tokenIdAfter == 0, "Failed to close all positions");
                console.log("[OK] All positions closed successfully");
            }
        }

        // Step 2: Withdraw all tokens
        {
            console.log("\n[Step 2] Withdrawing all tokens...");
            IERC20 token0_ = IERC20(address(rebalancer.token0()));
            IERC20 token1_ = IERC20(address(rebalancer.token1()));
            
            address owner = rebalancer.owner();
            uint256 token0BalanceBefore = token0_.balanceOf(address(rebalancer));
            uint256 token1BalanceBefore = token1_.balanceOf(address(rebalancer));
            uint256 ownerToken0Before = token0_.balanceOf(owner);
            uint256 ownerToken1Before = token1_.balanceOf(owner);
            
            console.log("  Contract Token0 balance:", token0BalanceBefore);
            console.log("  Contract Token1 balance:", token1BalanceBefore);
            console.log("  Owner Token0 balance before:", ownerToken0Before);
            console.log("  Owner Token1 balance before:", ownerToken1Before);
            
            if (token0BalanceBefore > 0 || token1BalanceBefore > 0) {
                rebalancer.withdrawAll();
                
                uint256 token0BalanceAfter = token0_.balanceOf(address(rebalancer));
                uint256 token1BalanceAfter = token1_.balanceOf(address(rebalancer));
                uint256 ownerToken0After = token0_.balanceOf(owner);
                uint256 ownerToken1After = token1_.balanceOf(owner);
                
                console.log("  Contract Token0 balance after:", token0BalanceAfter);
                console.log("  Contract Token1 balance after:", token1BalanceAfter);
                console.log("  Owner Token0 balance after:", ownerToken0After);
                console.log("  Owner Token1 balance after:", ownerToken1After);
                
                require(token0BalanceAfter == 0, "Token0 withdrawal failed");
                require(token1BalanceAfter == 0, "Token1 withdrawal failed");
                console.log("[OK] All tokens withdrawn successfully");
            } else {
                console.log("[INFO] No tokens to withdraw (balances are zero)");
            }
        }

        // Step 3: Withdraw reward tokens (AERO)
        {
            console.log("\n[Step 3] Withdrawing reward tokens (AERO)...");
            IERC20 rewardToken_ = IERC20(address(rebalancer.rewardToken()));
            address owner = rebalancer.owner();
            
            uint256 rewardBalanceBefore = rewardToken_.balanceOf(address(rebalancer));
            uint256 ownerRewardBalanceBefore = rewardToken_.balanceOf(owner);
            
            console.log("  Reward token address:", address(rewardToken_));
            console.log("  Contract reward token balance:", rewardBalanceBefore);
            console.log("  Owner reward token balance before:", ownerRewardBalanceBefore);
            
            if (rewardBalanceBefore > 0) {
                rebalancer.withdrawRewards();
                
                uint256 rewardBalanceAfter = rewardToken_.balanceOf(address(rebalancer));
                uint256 ownerRewardBalanceAfter = rewardToken_.balanceOf(owner);
                
                console.log("  Contract reward token balance after:", rewardBalanceAfter);
                console.log("  Owner reward token balance after:", ownerRewardBalanceAfter);
                
                require(rewardBalanceAfter == 0, "Reward token withdrawal failed");
                require(ownerRewardBalanceAfter == ownerRewardBalanceBefore + rewardBalanceBefore, 
                    "Reward tokens not transferred correctly");
                console.log("[OK] Reward tokens withdrawn successfully");
            } else {
                console.log("[INFO] No reward tokens to withdraw (balance is zero)");
            }
        }

        vm.stopBroadcast();

        console.log("\n=== Close and Withdraw Operations Completed Successfully! ===");
    }
}

