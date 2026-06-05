import { ethers } from "ethers";
declare const ADDRESSES: {
    readonly policyRegistry: "0x9189dd93ae978aa83d5aedfa3c394af2a569231a";
    readonly activityLog: "0xf9923df74ffa56cdccead8d4c2d16b32c61ab632";
    readonly riskGuardian: "0x9C11eadBFd6c55c049A8F8AC6B77c6F93C915b04";
    readonly sentinelGate: "0x5787801F722Ef909c5F7ad3d7c5D915804e2E80A";
    readonly reputationStaking: "0x97EbB088b367B2aB75bC428Ee2841f8518373f1c";
};
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
export declare class Arbit {
    private provider;
    private signer;
    private policyRegistry;
    private sentinelGate;
    private activityLog;
    private reputationStaking;
    private riskGuardian;
    /**
     * Create a new Arbit SDK instance.
     *
     * @param signerOrProvider - An ethers Signer (for write operations) or
     *                           Provider (for read-only operations)
     */
    constructor(signerOrProvider: ethers.Signer | ethers.Provider);
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
    createPolicy(config: PolicyConfig): Promise<{
        policyId: string;
        txHash: string;
    }>;
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
    executeAction(params: ExecuteActionParams): Promise<{
        entryIndex: number;
        txHash: string;
        riskScore: number;
    }>;
    /**
     * Permanently revoke a policy. The agent is immediately disarmed.
     * This action is irreversible — the agent cannot be reactivated
     * under this policy. Register a new policy to restart the agent.
     *
     * @example
     * await arbit.revokePolicy("0xPolicyId");
     */
    revokePolicy(policyId: string): Promise<{
        txHash: string;
    }>;
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
    hireAgent(policyId: string, sellerAddress: string, minReputation?: number): Promise<{
        entryIndex: number;
        txHash: string;
        reputationScore: number;
    }>;
    /**
     * Approve SentinelGate to spend tokens on behalf of the agent.
     * Must be called by the agent wallet before any executeAction calls.
     *
     * @example
     * await arbit.approveGate("0xUSDCAddress", 500n * 10n**6n);
     */
    approveGate(tokenAddress: string, amount?: bigint): Promise<{
        txHash: string;
    }>;
    getPolicy(policyId: string): Promise<any>;
    getRemainingBudget(policyId: string): Promise<bigint>;
    isPolicyActive(policyId: string): Promise<boolean>;
    getActivePolicyForAgent(agentAddress: string): Promise<string>;
    getRiskScore(policyId: string, protocol: string): Promise<number>;
    getActivityLog(policyId: string): Promise<any[]>;
    verifyLogChain(): Promise<{
        intact: boolean;
        brokenAt: number;
    }>;
    getActiveMarketplaceListings(): Promise<string[]>;
    getReputationScore(agentAddress: string): Promise<number>;
    private _requireSigner;
}
export { ADDRESSES };
export declare const ACTION_TYPES: {
    readonly DATA_FEED: 0;
    readonly DEX_SWAP: 1;
    readonly LENDING: 2;
    readonly MARKETPLACE: 3;
    readonly YIELD: 4;
};
export default Arbit;
//# sourceMappingURL=index.d.ts.map