// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Rebalancer contract...");
        console.log("Deployer address:", deployer);

        // Get addresses from environment variables or use defaults for testing
        address nftManager = vm.envOr("NFT_MANAGER_ADDRESS", address(0x1230000000000000000000000000000000000000));
        address gauge = vm.envOr("GAUGE_ADDRESS", address(0x4560000000000000000000000000000000000000));
        address owner = vm.envOr("OWNER_ADDRESS", deployer);

        console.log("NFT Manager:", nftManager);
        console.log("Gauge:", gauge);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        Rebalancer rebalancer = new Rebalancer(nftManager, gauge, owner);

        console.log("Rebalancer deployed at:", address(rebalancer));
        
        // Tokens are now automatically retrieved from gauge
        console.log("Token0 (from gauge):", address(rebalancer.token0()));
        console.log("Token1 (from gauge):", address(rebalancer.token1()));
        console.log("TickSpacing (from gauge):", rebalancer.tickSpacing());

        vm.stopBroadcast();

        console.log("Deployment completed!");
    }
}

