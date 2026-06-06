# Arbit Protocol

Arbit is a smart contract protocol built on Arbitrum that gives AI agents genuine economic autonomy — inside rules they cannot break. Before any payment executes, Arbit checks the agent's policy and the current risk score simultaneously. Both must pass. If either fails, the transaction reverts and nothing moves.

It was built to solve a problem that has already cost real money. In February 2026, autonomous agents caused $400 million in liquidations in under four minutes because there was no enforcement layer between them and the assets they controlled. Arbit is that enforcement layer.

It also implements the four security gaps that ERC-8004, the Ethereum standard for AI agent identity, explicitly left unsolved when it launched. Arbit is what ERC-8004 was designed to have built on top of it.

---

## Deployed Contracts on Arbitrum Sepolia

All five contracts are verified on Sourcify and readable on Arbiscan.

| Contract | Address | Arbiscan |
|---|---|---|
| PolicyRegistry | 0x9189dd93ae978aa83d5aedfa3c394af2a569231a | [View](https://sepolia.arbiscan.io/address/0x9189dd93ae978aa83d5aedfa3c394af2a569231a) |
| ActivityLog | 0xf9923df74ffa56cdccead8d4c2d16b32c61ab632 | [View](https://sepolia.arbiscan.io/address/0xf9923df74ffa56cdccead8d4c2d16b32c61ab632) |
| RiskGuardian | 0x9C11eadBFd6c55c049A8F8AC6B77c6F93C915b04 | [View](https://sepolia.arbiscan.io/address/0x9C11eadBFd6c55c049A8F8AC6B77c6F93C915b04) |
| SentinelGate | 0x5787801F722Ef909c5F7ad3d7c5D915804e2E80A | [View](https://sepolia.arbiscan.io/address/0x5787801F722Ef909c5F7ad3d7c5D915804e2E80A) |
| ReputationStaking | 0x21040c936e19691138D639C5718339B6d8AcB279 | [View](https://sepolia.arbiscan.io/address/0x21040c936e19691138D639C5718339B6d8AcB279) |
| MockUSDC (testnet) | 0x16F2041585688AAF60dFd206d13246FD81aD515C | [View](https://sepolia.arbiscan.io/address/0x16F2041585688AAF60dFd206d13246FD81aD515C) |

Network: Arbitrum Sepolia, Chain ID 421614

You can verify the source code of each contract on Sourcify. All five core contracts were verified at deployment with an exact match status, meaning the deployed bytecode matches the source code exactly.


---

## What Each Contract Does

**PolicyRegistry** is the agent's constitution. When a developer registers a policy for their agent, they set a total budget, a maximum transaction size, a list of permitted action types, a risk ceiling, and an expiry date. Once registered, the agent reads these rules before every action. The EVM enforces them. The agent cannot override them.

**ActivityLog** is the tamper-proof record. Every action the agent takes is written here permanently. Each entry is cryptographically linked to the previous one, creating a chain that cannot be altered or deleted by anyone — including the developer who owns the policy.

**RiskGuardian** is the live scoring engine. Before every payment, it computes a risk score between zero and one hundred using five dimensions: price volatility, oracle confidence, protocol TVL stability, contract security status, and agent behaviour patterns. It pulls data from Pyth Network and Chainlink. If the score exceeds the agent's ceiling, the payment is blocked automatically and resumes on its own when conditions normalise.

**SentinelGate** is the checkpoint every payment passes through. It queries PolicyRegistry and RiskGuardian in the same transaction. Both must pass before a single token moves. If either fails, the entire transaction reverts.

**ReputationStaking** is the marketplace layer. Agents stake USDC to list services. That stake is their skin in the game. Deliver well and the stake stays intact. Behave maliciously or fail to perform and the stake gets slashed — seventy percent goes to the harmed buyer and thirty percent goes to the protocol treasury.

---

## How It Fits ERC-8004

ERC-8004 defines identity and reputation rails for AI agents. It deliberately leaves four problems unsolved and flags them as building opportunities. Arbit closes all four.

| ERC-8004 Gap | Arbit Solution |
|---|---|
| No defence against fake agent registrations | ReputationStaking requires real USDC to list. Fakes cost money. |
| Reputation NFTs can be sold to malicious buyers | PolicyRegistry locks behaviour to the policy, not the NFT. |
| No enforcement against unsafe payments | RiskGuardian blocks payments before execution, not after. |
| Past reputation does not predict future safety | Live oracle scoring replaces historical data with real-time conditions. |

The relationship is clean. ERC-8004 defines the identity and reputation rails. Arbit enforces them and puts them to work in a live economy.

---

## Test Results

The protocol has 251 passing tests across seven test suites. Zero failures.

| Suite | Tests |
|---|---|
| PolicyRegistry | 51 |
| ActivityLog | 35 |
| SentinelGate | 39 |
| ReputationStaking | 50 |
| RiskGuardian | 37 |
| Breach Attempts | 26 |
| Integration | 13 |

The breach attempt suite is worth noting. We tried 26 different attacks against the deployed contracts — agents trying to modify their own policies, unauthorised addresses writing to the activity log, budget overflow attempts, risk ceiling bypasses, unauthorised slashes, and staking manipulation. All 26 were blocked.

---

## Getting Started for Developers

This section walks through everything from cloning the repo to running your first live transaction on Arbitrum Sepolia. Read it top to bottom the first time. After that you can jump to whichever section you need.

### What You Need Before Starting

You need Node.js version 18 or higher, the Foundry toolkit for Solidity development, and a wallet with a small amount of Arbitrum Sepolia ETH for gas. If you do not have Foundry installed, the first step covers that.

### Step 1. Clone the Repository

Open your terminal and run these commands one at a time.

```bash
git clone https://github.com/your-username/arbit-ai
cd arbit-ai
```

### Step 2. Install Foundry

Foundry is the Solidity development toolkit the contracts are built with. If you already have it installed, skip this step.

```bash
curl -L https://foundry.paradigm.xyz | bash
```

Close your terminal, open a new one, then run:

```bash
foundryup
```

Verify it worked:

```bash
forge --version
```

You should see a version number printed. If you see an error, make sure your PATH includes the Foundry bin directory. On Mac this is usually `~/.foundry/bin`.

### Step 3. Install Dependencies

```bash
forge install
```

This installs OpenZeppelin and the Pyth SDK, both of which the contracts depend on.

### Step 4. Run the Tests

```bash
forge test
```

You should see 251 tests passing with zero failures. If any tests fail, check that your Foundry version matches the one in Step 2. Running `foundryup` again usually fixes version-related failures.

To run tests with more detail:

```bash
forge test -v
```

To run just one test suite:

```bash
forge test --match-path test/PolicyRegistry.t.sol -v
```

To see gas costs alongside the test results:

```bash
forge test --gas-report
```

### Step 5. Set Up Your Environment

Create a file called `.env` in the project root. This file holds your private key and RPC URL. It is already listed in `.gitignore` so it will not be committed to Git.

```bash
touch .env
```

Open the file and add these three lines, replacing the placeholder values with your own:

```
PRIVATE_KEY=0xYourPrivateKeyHere
ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YourAlchemyKeyHere
DEPLOYER_ADDRESS=0xYourWalletAddressHere
```

To get a free Alchemy RPC URL, create an account at alchemy.com, create a new app, select Arbitrum Sepolia as the network, and copy the HTTPS URL.

To get testnet ETH for gas, go to faucets.alchemy.com, select Arbitrum Sepolia, and paste your wallet address.

### Step 6. Load the Environment

```bash
export ETH_RPC_URL="https://arb-sepolia.g.alchemy.com/v2/YourAlchemyKeyHere"
export PRIVATE_KEY="0xYourPrivateKeyHere"
export DEPLOYER_ADDRESS="0xYourWalletAddressHere"
```

---

## Using the TypeScript SDK

The SDK lives in the `sdk` folder. It gives you four core functions to interact with the protocol without writing any Solidity.

### Installation

```bash
cd sdk
npm install
```

### Connecting to the Protocol

```typescript
import { ethers } from "ethers";
import Arbit from "./src/index.js";

const provider = new ethers.JsonRpcProvider("https://arb-sepolia.g.alchemy.com/v2/YourKeyHere");
const signer   = new ethers.Wallet("0xYourPrivateKey", provider);
const arbit    = new Arbit(signer);
```

That is all the setup you need. The SDK already knows the deployed contract addresses on Arbitrum Sepolia.

### Function 1: createPolicy

This is the first thing you call when onboarding an agent. It registers the agent on-chain with its budget, permitted actions, risk ceiling, and expiry.

```typescript
const { policyId, txHash } = await arbit.createPolicy({
  agent:                "0xYourAgentWalletAddress",
  token:                "0x16F2041585688AAF60dFd206d13246FD81aD515C", // MockUSDC on Sepolia
  maxBudget:            500n * 10n**6n,    // 500 USDC total budget
  maxTransactionSize:   50n * 10n**6n,     // maximum 50 USDC per payment
  expiry:               Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60, // 30 days from now
  riskCeiling:          70,                // block payments when risk score exceeds 70
  permittedActions:     [0, 1, 3],         // 0 = data feeds, 1 = swaps, 3 = marketplace
});

console.log("Policy ID:", policyId);
console.log("Transaction:", txHash);
```

The permitted action types are: 0 for data feeds, 1 for DEX swaps, 2 for lending, 3 for marketplace, and 4 for yield strategies. Pass any combination that fits your agent's use case.

### Before Calling executeAction: Approve the Gate

Before your agent can make any payments, it needs to approve SentinelGate to spend its tokens. This is a standard ERC-20 approval. Call this once per agent per token.

```typescript
await arbit.approveGate(
  "0x16F2041585688AAF60dFd206d13246FD81aD515C", // the token address
  500n * 10n**6n                                 // amount to approve, match your budget
);
```

### Function 2: executeAction

This sends a payment through SentinelGate. Policy and risk are checked automatically before any tokens move. You do not need to call PolicyRegistry or RiskGuardian yourself.

```typescript
const { entryIndex, txHash, riskScore } = await arbit.executeAction({
  policyId:   "0xYourPolicyId",
  recipient:  "0xRecipientAddress",
  amount:     10n * 10n**6n,   // 10 USDC
  actionType: 0,               // data feed
});

console.log("Payment logged at entry:", entryIndex);
console.log("Risk score at time of payment:", riskScore);
console.log("Transaction:", txHash);
```

If the risk score is above your ceiling, or if the payment would exceed your budget, the transaction will revert with a clear error message. No tokens will have moved.

### Function 3: revokePolicy

This permanently disarms an agent. The agent cannot make any further payments after this call. It cannot be reversed. If you want to restart the agent, register a new policy.

```typescript
const { txHash } = await arbit.revokePolicy("0xYourPolicyId");
console.log("Policy revoked:", txHash);
```

### Function 4: hireAgent

This discovers and pays a seller agent from the Arbit marketplace. It checks the seller's reputation score before executing the payment. If the seller is below your minimum score, it throws before spending anything.

```typescript
const result = await arbit.hireAgent(
  "0xYourPolicyId",       // your agent's policy
  "0xSellerAgentAddress", // the agent you want to hire
  75                      // minimum reputation score you will accept
);

console.log("Hired agent with reputation:", result.reputationScore);
console.log("Payment logged at entry:", result.entryIndex);
```

### Reading Data

You can read from the protocol without a signer. Pass a provider instead of a signer to the constructor for read-only access.

```typescript
// Check how much budget is left
const remaining = await arbit.getRemainingBudget("0xYourPolicyId");
console.log("Remaining budget:", ethers.formatUnits(remaining, 6), "USDC");

// Get the current risk score for a protocol
const score = await arbit.getRiskScore("0xYourPolicyId", "0xProtocolAddress");
console.log("Risk score:", score, "out of 100");

// Get all activity for a policy
const entries = await arbit.getActivityLog("0xYourPolicyId");
console.log("Total actions logged:", entries.length);

// Verify the activity log chain is intact
const { intact, brokenAt } = await arbit.verifyLogChain();
console.log("Chain intact:", intact);

// Check who is listed on the marketplace
const listings = await arbit.getActiveMarketplaceListings();
console.log("Active marketplace agents:", listings.length);

// Get a specific agent's reputation score
const reputation = await arbit.getReputationScore("0xAgentAddress");
console.log("Reputation score:", reputation, "out of 100");
```

### Running the Live Demo

The demo connects to the live Arbitrum Sepolia contracts and shows real on-chain data. It reads the marketplace listing, verifies the activity log chain, and checks risk scores.

```bash
cd sdk
ARBITRUM_SEPOLIA_RPC="https://arb-sepolia.g.alchemy.com/v2/YourKeyHere" \
PRIVATE_KEY="0xYourPrivateKey" \
npx tsx src/demo.ts
```

---

## Deploying Your Own Instance

If you want to deploy your own copy of the protocol to a different network or a fresh Sepolia deployment, use the deploy script.

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key "" \
  -vvvv
```

After deployment, run the protocol setup script to register real DeFi protocols in RiskGuardian:

```bash
forge script script/SetupProtocols.s.sol:SetupProtocols \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

Update the contract addresses in `sdk/src/index.ts` with the new deployment addresses before using the SDK.

---

## Security

The contracts were analysed with Slither static analysis. Zero high or medium severity findings. The only findings were a divide-before-multiply issue in the reputation score calculation, which was fixed before deployment, and two low-severity enum comparison warnings which are correct patterns for Solidity enums and were suppressed with inline comments.

The contracts use OpenZeppelin's ReentrancyGuard on all state-changing functions. Custom errors are used throughout instead of string requires, which saves gas and makes failures machine-readable. The checks-effects-interactions pattern is followed on every function that moves tokens.

The ActivityLog uses cryptographic chaining. Each entry hashes the previous entry's hash into itself. Modifying any past entry breaks every hash that follows it. You can verify the chain is intact at any time by calling `verifyChain(0)` on the ActivityLog contract.

---

## Troubleshooting

**forge test fails with compilation errors**

Run `forge install` to make sure all dependencies are installed. Then try `forge build --force` to clear the cache and recompile from scratch.

**forge test passes but some tests are skipped**

This usually means a test file is not in the `test/` directory or the file name does not end in `.t.sol`. Check the file names match the convention.

**The RPC URL keeps defaulting to localhost**

Foundry reads the `ETH_RPC_URL` environment variable as its default RPC. If this variable is set to an empty string, Foundry falls back to localhost. Fix it by running:

```bash
export ETH_RPC_URL="https://arb-sepolia.g.alchemy.com/v2/YourKeyHere"
```

Then retry your forge command.

**cast send fails with execution reverted**

Check that your wallet has enough testnet ETH for gas and enough testnet USDC for the transaction amount. For testnet USDC, mint from the MockUSDC contract:

```bash
cast send 0x16F2041585688AAF60dFd206d13246FD81aD515C \
  "mint(address,uint256)" \
  0xYourAddress \
  1000000000 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

**The SDK demo throws a TypeError about invalid private key**

Make sure your private key has the `0x` prefix. Also check that the environment variables are exported correctly. Run `echo $PRIVATE_KEY` to confirm the value is set before running the demo.

**executeAction reverts with PolicyValidationFailed**

This means the payment violated the agent's policy. Common causes are the amount exceeding the max transaction size, the action type not being in the permitted list, the budget being exhausted, or the policy being expired or revoked. Check the policy parameters with `arbit.getPolicy(policyId)` and compare against what you are sending.

**executeAction reverts with RiskCeilingBreached**

The RiskGuardian computed a score above your policy's ceiling. On testnet this often happens because Pyth oracle data is stale, which causes RiskGuardian to return a conservative high score. On mainnet, Pyth feeds update every 400 milliseconds so this is rarely an issue in normal conditions. On testnet, you can raise the risk ceiling on your policy using `registry.updateRiskCeiling(policyId, 90)` for testing purposes.

**ReputationStaking listService fails with UnauthorizedTransfer**

Some testnet USDC tokens have transfer restrictions between non-whitelisted addresses. Use the MockUSDC contract at `0x16F2041585688AAF60dFd206d13246FD81aD515C` instead, which has no restrictions and supports free minting.

---

## Stack

Solidity 0.8.35, Arbitrum Stylus (Rust) for the RiskGuardian scoring engine, Pyth Network for live oracle price feeds, Chainlink for cross-validation on mainnet, ERC-8004 as the identity and reputation foundation, x402 as the payment rail for agent-to-agent transactions, TypeScript SDK for developer integration, Foundry for testing and deployment.

---

## Built For

Arbitrum Open House London 2026, Agentic Infrastructure Track. Total prize pool $415,000 across the Online Buildathon and IRL Founder House.

