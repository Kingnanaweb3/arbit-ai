/**
 * Arbit SDK — Live Integration Test
 *
 * Tests all four core SDK functions against real deployed contracts
 * on Arbitrum Sepolia. Every transaction is real and visible on Arbiscan.
 *
 * Run with:
 * ARBITRUM_SEPOLIA_RPC=... PRIVATE_KEY=... npx tsx src/test-live.ts
 */

import { ethers } from "ethers";
import Arbit, { ACTION_TYPES, ADDRESSES } from "./index.js";

const RPC_URL     = process.env.ARBITRUM_SEPOLIA_RPC!;
const PRIVATE_KEY = process.env.PRIVATE_KEY!;
const MOCK_USDC   = "0x16F2041585688AAF60dFd206d13246FD81aD515C";
const MOCK_USDC_ABI = [
  "function mint(address to, uint256 amount) external",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
];

// Simple pass/fail tracker
let passed = 0;
let failed = 0;

function pass(test: string) {
  console.log(`  PASS  ${test}`);
  passed++;
}

function fail(test: string, error: any) {
  console.log(`  FAIL  ${test}`);
  console.log(`        ${error?.shortMessage || error?.message || error}`);
  failed++;
}

function section(title: string) {
  console.log(`\n--- ${title} ---`);
}

async function main() {
  console.log("\n=== ARBIT SDK LIVE TEST ===");
  console.log("Network: Arbitrum Sepolia");
  console.log("Contracts: live deployed instances\n");

  const provider  = new ethers.JsonRpcProvider(RPC_URL);
  const signer    = new ethers.Wallet(PRIVATE_KEY, provider);
  const deployer  = await signer.getAddress();
  const arbit     = new Arbit(signer);

  console.log("Deployer:", deployer);

  // Create a fresh agent wallet for testing
  const agentWallet = ethers.Wallet.createRandom().connect(provider);
  console.log("Agent:   ", agentWallet.address);

  // ── Setup: mint USDC and fund agent ───────────────────────────────────────
  section("SETUP");

  const usdc = new ethers.Contract(MOCK_USDC, MOCK_USDC_ABI, signer);

  try {
    // Mint USDC to deployer
    const mintTx = await usdc.mint(deployer, 500n * 10n**6n);
    await mintTx.wait();
    pass("Minted 500 USDC to deployer");
  } catch (e) {
    fail("Mint USDC", e);
  }

  // Send ETH to agent for gas
  try {
    const ethTx = await signer.sendTransaction({
      to:    agentWallet.address,
      value: ethers.parseEther("0.005"),
    });
    await ethTx.wait();
    pass("Funded agent wallet with 0.005 ETH for gas");
  } catch (e) {
    fail("Fund agent ETH", e);
  }

  // Transfer USDC to agent
  const usdcTransferAbi = ["function transfer(address to, uint256 amount) external returns (bool)"];
  const usdcWithTransfer = new ethers.Contract(MOCK_USDC, usdcTransferAbi, signer);
  try {
    const transferTx = await usdcWithTransfer.transfer(agentWallet.address, 300n * 10n**6n);
    await transferTx.wait();
    pass("Transferred 300 USDC to agent");
  } catch (e) {
    fail("Transfer USDC to agent", e);
  }

  // ── Test 1: createPolicy ──────────────────────────────────────────────────
  section("TEST 1: createPolicy");

  let policyId = "";
  try {
    const result = await arbit.createPolicy({
      agent:              agentWallet.address,
      token:              MOCK_USDC,
      maxBudget:          200n * 10n**6n,
      maxTransactionSize: 50n * 10n**6n,
      expiry:             Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
      riskCeiling:        90,  // high ceiling so testnet stale oracle does not block
      permittedActions:   [ACTION_TYPES.DATA_FEED, ACTION_TYPES.DEX_SWAP, ACTION_TYPES.MARKETPLACE],
    });
    policyId = result.policyId;
    pass(`Policy created: ${policyId.slice(0, 20)}...`);
    pass(`Transaction: https://sepolia.arbiscan.io/tx/${result.txHash}`);
  } catch (e) {
    fail("createPolicy", e);
  }

  if (!policyId) {
    console.log("\nCannot continue without a policyId. Stopping.");
    return;
  }

  // Verify policy is active
  try {
    const active = await arbit.isPolicyActive(policyId);
    active ? pass("isPolicyActive returns true") : fail("isPolicyActive", "returned false");
  } catch (e) {
    fail("isPolicyActive", e);
  }

  // Verify budget is correct
  try {
    const remaining = await arbit.getRemainingBudget(policyId);
    const expected  = 200n * 10n**6n;
    remaining === expected
      ? pass(`getRemainingBudget returns ${ethers.formatUnits(remaining, 6)} USDC`)
      : fail("getRemainingBudget", `expected ${expected} got ${remaining}`);
  } catch (e) {
    fail("getRemainingBudget", e);
  }

  // ── Test 2: approveGate + executeAction ───────────────────────────────────
  section("TEST 2: executeAction");

  const agentArbit = new Arbit(agentWallet);

  // Agent approves SentinelGate
  try {
    await agentArbit.approveGate(MOCK_USDC, 200n * 10n**6n);
    pass("Agent approved SentinelGate to spend USDC");
  } catch (e) {
    fail("approveGate", e);
  }

  // Execute a real payment
  let entryIndex = -1;
  try {
    const result = await agentArbit.executeAction({
      policyId,
      recipient:  deployer,      // pay back to deployer for test purposes
      amount:     10n * 10n**6n, // 10 USDC
      actionType: ACTION_TYPES.DATA_FEED,
    });
    entryIndex = result.entryIndex;
    pass(`Payment executed — entry index: ${entryIndex}, risk score: ${result.riskScore}`);
    pass(`Transaction: https://sepolia.arbiscan.io/tx/${result.txHash}`);
  } catch (e) {
    fail("executeAction", e);
  }

  // Verify budget decreased
  try {
    const remaining = await arbit.getRemainingBudget(policyId);
    const expected  = 190n * 10n**6n;
    remaining === expected
      ? pass(`Budget correctly decreased to ${ethers.formatUnits(remaining, 6)} USDC`)
      : fail("Budget after payment", `expected 190 got ${ethers.formatUnits(remaining, 6)}`);
  } catch (e) {
    fail("Budget check after payment", e);
  }

  // Verify ActivityLog entry exists
  try {
    const entries = await arbit.getActivityLog(policyId);
    entries.length > 0
      ? pass(`ActivityLog has ${entries.length} entry for this policy`)
      : fail("ActivityLog", "no entries found");
  } catch (e) {
    fail("getActivityLog", e);
  }

  // Verify chain is intact
  try {
    const { intact } = await arbit.verifyLogChain();
    intact
      ? pass("ActivityLog chain integrity verified — INTACT")
      : fail("verifyLogChain", "chain is broken");
  } catch (e) {
    fail("verifyLogChain", e);
  }

  // ── Test 3: revokePolicy ──────────────────────────────────────────────────
  section("TEST 3: revokePolicy");

  // Create a second policy to revoke (do not revoke the main one yet)
  let revokePolicyId = "";
  try {
    const agentB = ethers.Wallet.createRandom();
    const result = await arbit.createPolicy({
      agent:              agentB.address,
      token:              MOCK_USDC,
      maxBudget:          50n * 10n**6n,
      maxTransactionSize: 10n * 10n**6n,
      expiry:             Math.floor(Date.now() / 1000) + 1 * 24 * 60 * 60,
      riskCeiling:        90,
      permittedActions:   [ACTION_TYPES.DATA_FEED],
    });
    revokePolicyId = result.policyId;
    pass(`Second policy created for revocation test: ${revokePolicyId.slice(0, 20)}...`);
  } catch (e) {
    fail("Create policy for revocation", e);
  }

  if (revokePolicyId) {
    try {
      await arbit.revokePolicy(revokePolicyId);
      pass("revokePolicy executed successfully");
    } catch (e) {
      fail("revokePolicy", e);
    }

    try {
      const active = await arbit.isPolicyActive(revokePolicyId);
      !active
        ? pass("Revoked policy correctly shows as inactive")
        : fail("isPolicyActive after revoke", "policy still shows active");
    } catch (e) {
      fail("isPolicyActive after revoke", e);
    }
  }

  // ── Test 4: hireAgent (marketplace) ──────────────────────────────────────
  section("TEST 4: hireAgent");

  const REPUTATION_STAKING = "0x21040c936e19691138D639C5718339B6d8AcB279";
  const stakingAbi = ["function isListed(address agent) external view returns (bool)"];
  const staking    = new ethers.Contract(REPUTATION_STAKING, stakingAbi, provider);

  const isListed = await staking.isListed(deployer);
  if (isListed) {
    try {
      // Agent tries to hire the deployer who is listed on the marketplace
      // We need to update the agent's policy to include MARKETPLACE action
      const result = await agentArbit.hireAgent(
        policyId,
        deployer,
        0   // minimum reputation 0 — just testing the flow works
      );
      pass(`hireAgent executed — reputation: ${result.reputationScore}, entry: ${result.entryIndex}`);
      pass(`Transaction: https://sepolia.arbiscan.io/tx/${result.txHash}`);
    } catch (e) {
      fail("hireAgent", e);
    }
  } else {
    console.log("  SKIP  hireAgent — deployer is not listed on marketplace");
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("\n=== RESULTS ===");
  console.log(`Passed: ${passed}`);
  console.log(`Failed: ${failed}`);
  console.log(`Total:  ${passed + failed}`);

  if (failed === 0) {
    console.log("\nAll SDK functions verified against live Arbitrum Sepolia contracts.");
    console.log("Every transaction is real and visible on Arbiscan.");
  } else {
    console.log("\nSome tests failed. Check the errors above.");
  }

  console.log("\nArbiscan links:");
  console.log("PolicyRegistry:    https://sepolia.arbiscan.io/address/0x9189dd93ae978aa83d5aedfa3c394af2a569231a");
  console.log("ActivityLog:       https://sepolia.arbiscan.io/address/0xf9923df74ffa56cdccead8d4c2d16b32c61ab632");
  console.log("SentinelGate:      https://sepolia.arbiscan.io/address/0x5787801F722Ef909c5F7ad3d7c5D915804e2E80A");
  console.log("ReputationStaking: https://sepolia.arbiscan.io/address/0x21040c936e19691138D639C5718339B6d8AcB279");
}

main().catch(console.error);
