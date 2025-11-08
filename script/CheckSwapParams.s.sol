// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/**
 * @title CheckSwapParamsScript
 * @notice Script to call calculateSwapByRatioParamsView on Rebalancer contract
 * @dev Reads REBALANCER_ADDRESS, TARGET_RATIO, and SLIPPAGE from environment variables
 */
contract CheckSwapParamsScript is Script {
    function run() external view {
        // Get contract address from environment
        address rebalancerAddress = vm.envAddress("REBALANCER_ADDRESS");
        
        // Get parameters from environment (with defaults)
        uint256 targetRatio = vm.envOr("TARGET_RATIO", uint256(100000000000000000000000)); // Default: 1e23
        uint256 slippage = vm.envOr("SLIPPAGE", uint256(10000000000000000)); // Default: 1% (1e16)
        
        console.log("=== Checking Swap Parameters ===");
        console.log("Rebalancer Address:", rebalancerAddress);
        console.log("Target Ratio:", targetRatio);
        console.log("Slippage:", slippage);
        console.log("");
        
        // Get contract instance
        Rebalancer rebalancer = Rebalancer(rebalancerAddress);
        
        // Get balances for debugging
        IERC20 token0_ = rebalancer.token0();
        IERC20 token1_ = rebalancer.token1();
        address token0Addr = address(token0_);
        address token1Addr = address(token1_);
        uint8 decimals0 = rebalancer.token0Decimals();
        uint8 decimals1 = rebalancer.token1Decimals();
        
        uint256 balance0 = token0_.balanceOf(rebalancerAddress);
        uint256 balance1 = token1_.balanceOf(rebalancerAddress);
        
        console.log("Contract Balances:");
        console.log("  Token0 (", token0Addr, "): ", balance0);
        console.log("  Token1 (", token1Addr, "): ", balance1);
        console.log("  Decimals0: ", decimals0);
        console.log("  Decimals1: ", decimals1);
        console.log("");
        
        // Calculate current ratio for reference
        uint256 scale0 = 10 ** decimals0;
        uint256 scale1 = 10 ** decimals1;
        uint256 currentRatio = 0;
        if (balance1 > 0) {
            currentRatio = (balance0 * scale1 * 1e18) / (balance1 * scale0);
        }
        console.log("Current ratio (token0/token1): ", currentRatio);
        console.log("Target ratio (token0/token1): ", targetRatio);
        console.log("");
        
        // Calculate needed0 for debugging
        uint256 needed0 = (balance1 * targetRatio * scale0) / (scale1 * 1e18);
        console.log("Calculation details:");
        console.log("  needed0 (target token0 amount): ", needed0);
        console.log("  balance0 (current token0): ", balance0);
        if (needed0 > balance0) {
            uint256 amount0Needed = needed0 - balance0;
            console.log("  amount0 needed: ", amount0Needed);
            uint256 amount1_est = (amount0Needed * balance1 * scale0) / (balance0 * scale1);
            console.log("  amount1_est (before limits): ", amount1_est);
            uint256 maxAmount1 = (balance1 * 9900) / 10000; // 99% of balance1
            console.log("  maxAmount1 (99% of balance1): ", maxAmount1);
            if (amount1_est > maxAmount1) {
                console.log("  [INFO] amount1_est limited to maxAmount1");
            }
        } else {
            uint256 amount0ToSell = balance0 - needed0;
            console.log("  amount0 to sell: ", amount0ToSell);
        }
        console.log("");
        
        // Call the view function
        Rebalancer.SwapParams memory params = rebalancer.calculateSwapByRatioParamsView(
            targetRatio,
            slippage
        );
        
        // Output results
        console.log("==========================================");
        console.log("Swap Parameters:");
        console.log("==========================================");
        console.log("shouldSwap:   ", params.shouldSwap);
        console.log("tokenIn:      ", params.tokenIn);
        console.log("tokenOut:     ", params.tokenOut);
        console.log("amountIn:     ", params.amountIn);
        console.log("amountOutMin: ", params.amountOutMin);
        console.log("isBuy:        ", params.isBuy);
        console.log("");
        
        // Interpret the results
        if (params.shouldSwap) {
            console.log("[OK] Swap is needed");
            if (params.isBuy) {
                console.log("  Direction: Selling token0, buying token1");
            } else {
                console.log("  Direction: Selling token1, buying token0");
            }
            console.log("  Amount to swap: ", params.amountIn);
            console.log("  Minimum output: ", params.amountOutMin);
        } else {
            console.log("[INFO] No swap needed (ratio is already correct)");
        }
        
        console.log("");
    }
}

