// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RiskGuardian} from "../src/RiskGuardian.sol";

/**
 * @title SetupProtocols
 * @notice Registers real DeFi protocols and Pyth price feed IDs
 *         into the deployed RiskGuardian contract.
 *
 *         Pyth feed IDs are identical across all networks.
 *         Chainlink feeds are mainnet-only — left as address(0) on testnet.
 */
contract SetupProtocols is Script {

    // Deployed RiskGuardian address on Arbitrum Sepolia
    address constant RISK_GUARDIAN =
        0x9C11eadBFd6c55c049A8F8AC6B77c6F93C915b04;

    // Real Pyth price feed IDs — same on all networks
    bytes32 constant PYTH_ETH_USD  =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant PYTH_BTC_USD  =
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    // Protocol addresses we are registering
    // Using well-known Arbitrum mainnet addresses as identifiers
    // On testnet these serve as scoreable protocol IDs
    address constant UNISWAP_V3_ARBITRUM =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant AAVE_V3_ARBITRUM    =
        0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address constant GMX_ARBITRUM        =
        0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;

    // Reference TVL values in USD (6 decimals, USDC scale)
    // Approximate real TVL figures as of 2026
    uint256 constant UNISWAP_TVL  = 5_000_000_000e6;  // $5B
    uint256 constant AAVE_TVL     = 8_000_000_000e6;  // $8B
    uint256 constant GMX_TVL      = 500_000_000e6;    // $500M

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        RiskGuardian guardian = RiskGuardian(RISK_GUARDIAN);

        // Register Uniswap V3
        guardian.registerProtocol(
            UNISWAP_V3_ARBITRUM,
            PYTH_ETH_USD,
            address(0),          // no Chainlink on Arbitrum Sepolia
            5,                   // low base security score — well audited
            1609459200,          // audit timestamp Jan 2021
            false,
            UNISWAP_TVL
        );
        console2.log("Uniswap V3 registered");

        // Register Aave V3
        guardian.registerProtocol(
            AAVE_V3_ARBITRUM,
            PYTH_ETH_USD,
            address(0),
            5,                   // well audited
            1625097600,          // audit timestamp July 2021
            false,
            AAVE_TVL
        );
        console2.log("Aave V3 registered");

        // Register GMX
        guardian.registerProtocol(
            GMX_ARBITRUM,
            PYTH_ETH_USD,
            address(0),
            15,                  // moderate security score
            1635724800,          // audit timestamp Nov 2021
            false,
            GMX_TVL
        );
        console2.log("GMX registered");

        // Update current TVLs to match reference (healthy baseline)
        guardian.updateProtocolTVL(UNISWAP_V3_ARBITRUM, UNISWAP_TVL);
        guardian.updateProtocolTVL(AAVE_V3_ARBITRUM,    AAVE_TVL);
        guardian.updateProtocolTVL(GMX_ARBITRUM,        GMX_TVL);
        console2.log("TVLs updated");

        vm.stopBroadcast();

        console2.log("=== PROTOCOL SETUP COMPLETE ===");
        console2.log("Uniswap V3:", UNISWAP_V3_ARBITRUM);
        console2.log("Aave V3:   ", AAVE_V3_ARBITRUM);
        console2.log("GMX:       ", GMX_ARBITRUM);
    }
}
