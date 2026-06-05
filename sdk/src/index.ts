import { ethers } from "ethers";

// ─── Deployed contract addresses on Arbitrum Sepolia ─────────────────────────
const ADDRESSES = {
  policyRegistry:    "0x9189dd93ae978aa83d5aedfa3c394af2a569231a",
  activityLog:       "0xf9923df74ffa56cdccead8d4c2d16b32c61ab632",
  riskGuardian:      "0x9C11eadBFd6c55c049A8F8AC6B77c6F93C915b04",
  sentinelGate:      "0x5787801F722Ef909c5F7ad3d7c5D915804e2E80A",
  reputationStaking: "0x21040c936e19691138D639C5718339B6d8AcB279",
  mockUsdc:          "0x16F2041585688AAF60dFd206d13246FD81aD515C",
} as const;

// ─── Minimal ABIs — only what the SDK needs ───────────────────────────────────
const POLICY_REGISTRY_ABI = [
  "function registerPolicy(address agent, address token, uint256 maxBudget, uint256 maxTransactionSize, uint256 expiry, uint8 riskCeiling, uint8[] calldata permittedActions) external returns (bytes32)",
  "function revokePolicy(bytes32 policyId) external",
  "function getPolicy(bytes32 policyId) external view returns (tuple(address owner, address agent, address token, uint256 maxBudget, uint256 spentAmount, uint256 maxTransactionSize, uint256 expiry, uint8 riskCeiling, bool isActive, uint8[] permittedActions))",
  "function getRemainingBudget(bytes32 policyId) external view returns (uint256)",
  "function isPolicyActive(bytes32 policyId) external view returns (bool)",
  "function getActivePolicyForAgent(address agent) external view returns (bytes32)",
  "event PolicyRegistered(bytes32 indexed policyId, address indexed owner, address indexed agent, uint256 maxBudget, uint256 expiry)",
  "event PolicyRevoked(bytes32 indexed policyId, address indexed revokedBy, uint256 timestamp)",
];

const SENTINEL_GATE_ABI = [
  "function executePayment(bytes32 policyId, address recipient, uint256 amount, uint8 actionType, address protocol) external returns (uint256 entryIndex)",
  "event PaymentExecuted(bytes32 indexed policyId, address indexed agent, address indexed recipient, uint256 amount, uint8 riskScore, uint256 entryIndex)",
  "event PaymentBlocked(bytes32 indexed policyId, address indexed agent, uint256 amount, uint8 riskScore, string reason)",
];

const ACTIVITY_LOG_ABI = [
  "function getEntry(uint256 index) external view returns (tuple(bytes32 policyId, address agent, uint8 actionType, uint256 amount, uint8 riskScoreAtTime, bytes32 reason, uint256 timestamp, bytes32 previousEntryHash, bytes32 entryHash))",
  "function getEntriesForPolicy(bytes32 policyId) external view returns (uint256[])",
  "function getEntriesForAgent(address agent) external view returns (uint256[])",
  "function verifyChain(uint256 startIndex) external view returns (bool intact, uint256 brokenAt)",
  "function entryCount() external view returns (uint256)",
];

const REPUTATION_STAKING_ABI = [
  "function listService(uint256 stakeAmount, uint256 pricePerCall, uint8 category, bytes32 description) external",
  "function delistService() external",
  "function increaseStake(uint256 additionalAmount) external",
  "function getListing(address agent) external view returns (tuple(address agent, uint256 pricePerCall, uint8 category, uint8 status, uint256 stakedAmount, uint256 successfulCalls, uint256 failedCalls, uint256 listedAt, bytes32 description))",
  "function isListed(address agent) external view returns (bool)",
  "function getReputationScore(address agent) external view returns (uint8)",
  "function getActiveListings() external view returns (address[])",
];

const RISK_GUARDIAN_ABI = [
  "function getScore(bytes32 policyId, address protocol) external view returns (uint8 score)",
  "function isProtocolRegistered(address protocol) external view returns (bool)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
];

// ─── Types ────────────────────────────────────────────────────────────────────

export interface PolicyConfig {
  /** Agent wallet address that this policy governs */
  agent: string;
  /** ERC-20 token address for the budget (typically USDC) */
  token: string;
  /** Total budget in token units (e.g. 500e6 for 500 USDC) */
  maxBudget: bigint;
  /** Maximum single payment in token units */
  maxTransactionSize: bigint;
  /** Policy expiry as a Unix timestamp */
  expiry: number;
  /** Risk score ceiling 1-100. Payments blocked above this threshold */
  riskCeiling: number;
  /** Array of permitted action types (0=data, 1=swap, 2=lending, 3=marketplace, 4=yield) */
  permittedActions: number[];
}

export interface ExecuteActionParams {
  /** The active policy ID governing this payment */
  policyId: string;
  /** Recipient address */
  recipient: string;
  /** Amount in token units */
  amount: bigint;
  /** Action type (0-4) */
  actionType: number;
  /** Protocol address for risk scoring. Use ethers.ZeroAddress for agent-to-agent */
  protocol?: string;
}

export interface ServiceListingConfig {
  /** Amount of USDC to stake (minimum 100e6) */
  stakeAmount: bigint;
  /** Price per service call in USDC */
  pricePerCall: bigint;
  /** Service category (0-4) */
  category: number;
  /** Short description as a bytes32 hex string */
  description: string;
}

// ─── Main SDK class ───────────────────────────────────────────────────────────

export class Arbit {
  private provider: ethers.Provider;
  private signer: ethers.Signer | null;
  private policyRegistry: ethers.Contract;
  private sentinelGate: ethers.Contract;
  private activityLog: ethers.Contract;
  private reputationStaking: ethers.Contract;
  private riskGuardian: ethers.Contract;

  /**
   * Create a new Arbit SDK instance.
   *
   * @param signerOrProvider - An ethers Signer (for write operations) or
   *                           Provider (for read-only operations)
   */
  constructor(signerOrProvider: ethers.Signer | ethers.Provider) {
    if ("provider" in signerOrProvider && signerOrProvider.provider) {
      this.signer   = signerOrProvider as ethers.Signer;
      this.provider = signerOrProvider.provider;
    } else if (signerOrProvider instanceof ethers.AbstractSigner) {
      this.signer   = signerOrProvider;
      this.provider = signerOrProvider.provider!;
    } else {
      this.signer   = null;
      this.provider = signerOrProvider as ethers.Provider;
    }

    const connection = this.signer ?? this.provider;

    this.policyRegistry    = new ethers.Contract(ADDRESSES.policyRegistry,    POLICY_REGISTRY_ABI,    connection);
    this.sentinelGate      = new ethers.Contract(ADDRESSES.sentinelGate,      SENTINEL_GATE_ABI,      connection);
    this.activityLog       = new ethers.Contract(ADDRESSES.activityLog,       ACTIVITY_LOG_ABI,       connection);
    this.reputationStaking = new ethers.Contract(ADDRESSES.reputationStaking, REPUTATION_STAKING_ABI, connection);
    this.riskGuardian      = new ethers.Contract(ADDRESSES.riskGuardian,      RISK_GUARDIAN_ABI,      connection);
  }

  // ── Core function 1: createPolicy ─────────────────────────────────────────

  /**
   * Register a new policy for an AI agent on Arbit.
   *
   * This is the first thing a developer calls when onboarding their agent.
   * The returned policyId is used in all subsequent operations.
   *
   * @example
   * const { policyId } = await arbit.createPolicy({
   *   agent: "0xAgentAddress",
   *   token: "0xUSDCAddress",
   *   maxBudget: 500n * 10n**6n,
   *   maxTransactionSize: 50n * 10n**6n,
   *   expiry: Math.floor(Date.now()/1000) + 30 * 24 * 60 * 60,
   *   riskCeiling: 70,
   *   permittedActions: [0, 1, 3],
   * });
   */
  async createPolicy(config: PolicyConfig): Promise<{
    policyId: string;
    txHash: string;
  }> {
    this._requireSigner();

    const tx = await this.policyRegistry.registerPolicy(
      config.agent,
      config.token,
      config.maxBudget,
      config.maxTransactionSize,
      config.expiry,
      config.riskCeiling,
      config.permittedActions,
    );

    const receipt = await tx.wait();

    // Extract policyId from the PolicyRegistered event
    const iface   = new ethers.Interface(POLICY_REGISTRY_ABI);
    let policyId  = "";

    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed && parsed.name === "PolicyRegistered") {
          policyId = parsed.args[0];
          break;
        }
      } catch {}
    }

    console.log(`[Arbit] Policy created: ${policyId}`);
    return { policyId, txHash: receipt.hash };
  }

  // ── Core function 2: executeAction ────────────────────────────────────────

  /**
   * Execute a payment on behalf of an agent through SentinelGate.
   *
   * This wraps every payment with policy validation and risk scoring.
   * The agent must have approved SentinelGate to spend their tokens first.
   * Use approveGate() to handle the approval.
   *
   * @example
   * const result = await arbit.executeAction({
   *   policyId: "0x...",
   *   recipient: "0xDataProviderAddress",
   *   amount: 10n * 10n**6n,
   *   actionType: 0,
   * });
   */
  async executeAction(params: ExecuteActionParams): Promise<{
    entryIndex: number;
    txHash: string;
    riskScore: number;
  }> {
    this._requireSigner();

    const protocol = params.protocol ?? ethers.ZeroAddress;

    const tx      = await this.sentinelGate.executePayment(
      params.policyId,
      params.recipient,
      params.amount,
      params.actionType,
      protocol,
    );

    const receipt = await tx.wait();

    // Extract entryIndex and riskScore from PaymentExecuted event
    const iface = new ethers.Interface(SENTINEL_GATE_ABI);
    let entryIndex = 0;
    let riskScore  = 0;

    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed && parsed.name === "PaymentExecuted") {
          entryIndex = Number(parsed.args[5]);
          riskScore  = Number(parsed.args[4]);
          break;
        }
      } catch {}
    }

    console.log(`[Arbit] Payment executed. Entry: ${entryIndex}, Risk: ${riskScore}`);
    return { entryIndex, txHash: receipt.hash, riskScore };
  }

  // ── Core function 3: revokePolicy ─────────────────────────────────────────

  /**
   * Permanently revoke a policy. The agent is immediately disarmed.
   * This action is irreversible — the agent cannot be reactivated
   * under this policy. Register a new policy to restart the agent.
   *
   * @example
   * await arbit.revokePolicy("0xPolicyId");
   */
  async revokePolicy(policyId: string): Promise<{ txHash: string }> {
    this._requireSigner();
    const tx      = await this.policyRegistry.revokePolicy(policyId);
    const receipt = await tx.wait();
    console.log(`[Arbit] Policy revoked: ${policyId}`);
    return { txHash: receipt.hash };
  }

  // ── Core function 4: hireAgent ────────────────────────────────────────────

  /**
   * Discover and hire a listed agent from the Arbit marketplace.
   * Checks reputation score before executing the payment.
   *
   * @param policyId         Your agent's policy ID
   * @param sellerAddress    The agent you want to hire
   * @param minReputation    Minimum acceptable reputation score (0-100)
   *
   * @example
   * const result = await arbit.hireAgent(
   *   "0xYourPolicyId",
   *   "0xSellerAgentAddress",
   *   75
   * );
   */
  async hireAgent(
    policyId: string,
    sellerAddress: string,
    minReputation: number = 50,
  ): Promise<{ entryIndex: number; txHash: string; reputationScore: number }> {
    this._requireSigner();

    // Check seller is listed
    const isListed = await this.reputationStaking.isListed(sellerAddress);
    if (!isListed) {
      throw new Error(`[Arbit] Agent ${sellerAddress} is not listed on the marketplace`);
    }

    // Check reputation score
    const score = Number(await this.reputationStaking.getReputationScore(sellerAddress));
    if (score < minReputation) {
      throw new Error(
        `[Arbit] Agent reputation score ${score} is below minimum ${minReputation}`
      );
    }

    // Get listing details for price
    const listing = await this.reputationStaking.getListing(sellerAddress);
    const price   = listing.pricePerCall;

    console.log(`[Arbit] Hiring agent ${sellerAddress} (reputation: ${score}) for ${price} tokens`);

    // Execute the payment through SentinelGate
    const result = await this.executeAction({
      policyId,
      recipient:  sellerAddress,
      amount:     price,
      actionType: 3, // ACTION_MARKETPLACE
    });

    return { ...result, reputationScore: score };
  }

  // ── Utility: approveGate ──────────────────────────────────────────────────

  /**
   * Approve SentinelGate to spend tokens on behalf of the agent.
   * Must be called by the agent wallet before any executeAction calls.
   *
   * @example
   * await arbit.approveGate("0xUSDCAddress", 500n * 10n**6n);
   */
  async approveGate(
    tokenAddress: string,
    amount: bigint = ethers.MaxUint256,
  ): Promise<{ txHash: string }> {
    this._requireSigner();
    const token   = new ethers.Contract(tokenAddress, ERC20_ABI, this.signer!);
    const tx      = await token.approve(ADDRESSES.sentinelGate, amount);
    const receipt = await tx.wait();
    console.log(`[Arbit] Approved SentinelGate to spend tokens`);
    return { txHash: receipt.hash };
  }

  // ── Read functions ─────────────────────────────────────────────────────────

  async getPolicy(policyId: string) {
    return this.policyRegistry.getPolicy(policyId);
  }

  async getRemainingBudget(policyId: string): Promise<bigint> {
    return this.policyRegistry.getRemainingBudget(policyId);
  }

  async isPolicyActive(policyId: string): Promise<boolean> {
    return this.policyRegistry.isPolicyActive(policyId);
  }

  async getActivePolicyForAgent(agentAddress: string): Promise<string> {
    return this.policyRegistry.getActivePolicyForAgent(agentAddress);
  }

  async getRiskScore(policyId: string, protocol: string): Promise<number> {
    return Number(await this.riskGuardian.getScore(policyId, protocol));
  }

  async getActivityLog(policyId: string) {
    const indices = await this.activityLog.getEntriesForPolicy(policyId);
    const entries = await Promise.all(
      indices.map((i: bigint) => this.activityLog.getEntry(i))
    );
    return entries;
  }

  async verifyLogChain(): Promise<{ intact: boolean; brokenAt: number }> {
    const [intact, brokenAt] = await this.activityLog.verifyChain(0);
    return { intact, brokenAt: Number(brokenAt) };
  }

  async getActiveMarketplaceListings(): Promise<string[]> {
    return this.reputationStaking.getActiveListings();
  }

  async getReputationScore(agentAddress: string): Promise<number> {
    return Number(await this.reputationStaking.getReputationScore(agentAddress));
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  private _requireSigner() {
    if (!this.signer) {
      throw new Error(
        "[Arbit] This operation requires a Signer. Pass an ethers.Signer to the constructor."
      );
    }
  }
}

// ─── Convenience exports ──────────────────────────────────────────────────────

export { ADDRESSES };

export const ACTION_TYPES = {
  DATA_FEED:   0,
  DEX_SWAP:    1,
  LENDING:     2,
  MARKETPLACE: 3,
  YIELD:       4,
} as const;

export default Arbit;
