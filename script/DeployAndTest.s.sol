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
}

