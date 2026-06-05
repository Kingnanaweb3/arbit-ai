// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {ActivityLog} from "../src/ActivityLog.sol";
import {SentinelGate} from "../src/SentinelGate.sol";
import {ReputationStaking} from "../src/ReputationStaking.sol";
import {RiskGuardian} from "../src/RiskGuardian.sol";

/**
 * @title Deploy
 * @notice Deploys the full Arbit protocol stack to Arbitrum Sepolia.
 *
 *         Deployment order matters:
 *         1. PolicyRegistry  — no dependencies
 *         2. ActivityLog     — no dependencies
 *         3. RiskGuardian    — needs Pyth address
 *         4. SentinelGate    — needs PolicyRegistry, ActivityLog, RiskGuardian
 *         5. ReputationStaking — needs USDC address
 *         6. Wire everything together via completeSetup()
 */
contract Deploy is Script {

    // Arbitrum Sepolia contract addresses
    address constant PYTH_ARBITRUM_SEPOLIA =
        0x940d67A2492bf5e39Ce7AaD5E28e14E4e67D01D3;

    // Arbitrum Sepolia USDC
    // Using a mock USDC for testnet since Circle USDC may not be on Sepolia
    address constant USDC_ARBITRUM_SEPOLIA =
        0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console2.log("Deploying Arbit Protocol to Arbitrum Sepolia");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Deploy PolicyRegistry ────────────────────────────────────
        PolicyRegistry registry = new PolicyRegistry();
        console2.log("PolicyRegistry deployed:", address(registry));

        // ── Step 2: Deploy ActivityLog ────────────────────────────────────────
        ActivityLog actLog = new ActivityLog();
        console2.log("ActivityLog deployed:", address(actLog));

        // ── Step 3: Deploy RiskGuardian ───────────────────────────────────────
        RiskGuardian guardian = new RiskGuardian(
            PYTH_ARBITRUM_SEPOLIA,
            deployer
        );
        console2.log("RiskGuardian deployed:", address(guardian));

        // ── Step 4: Deploy SentinelGate ───────────────────────────────────────
        SentinelGate gate = new SentinelGate(
            address(registry),
            address(actLog),
            address(guardian),
            deployer
        );
        console2.log("SentinelGate deployed:", address(gate));

        // ── Step 5: Deploy ReputationStaking ──────────────────────────────────
        ReputationStaking staking = new ReputationStaking(
            USDC_ARBITRUM_SEPOLIA
        );
        console2.log("ReputationStaking deployed:", address(staking));

        // ── Step 6: Wire everything together ──────────────────────────────────
        // This registers SentinelGate with PolicyRegistry and ActivityLog
        gate.completeSetup();
        console2.log("SentinelGate wired to PolicyRegistry and ActivityLog");

        // Set deployer as the data reporter for RiskGuardian
        guardian.setDataReporter(deployer);
        console2.log("RiskGuardian data reporter set to deployer");

        // Set deployer as slash authority and treasury for ReputationStaking
        staking.setSlashAuthority(deployer);
        staking.setTreasury(deployer);
        console2.log("ReputationStaking slash authority and treasury set");

        vm.stopBroadcast();

        // ── Print deployment summary ───────────────────────────────────────────
        console2.log("");
        console2.log("=== ARBIT PROTOCOL DEPLOYMENT COMPLETE ===");
        console2.log("PolicyRegistry:    ", address(registry));
        console2.log("ActivityLog:       ", address(actLog));
        console2.log("RiskGuardian:      ", address(guardian));
        console2.log("SentinelGate:      ", address(gate));
        console2.log("ReputationStaking: ", address(staking));
        console2.log("==========================================");
        console2.log("Network: Arbitrum Sepolia");
        console2.log("Deployer:", deployer);
    }
}
