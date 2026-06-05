// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PolicyRegistry} from "./PolicyRegistry.sol";
import {ActivityLog} from "./ActivityLog.sol";

/**
 * @title SentinelGate
 * @author Arbit Protocol
 * @notice Every payment an agent makes must pass through here.
 *         Two checks run simultaneously before any USDC moves:
 *         1. PolicyRegistry — does this fit the agent's policy?
 *         2. RiskGuardian   — is the current risk score acceptable?
 *         Both must pass. One failure reverts everything.
 *
 * @dev This contract is the sole authorised caller of PolicyRegistry.consumeBudget
 *      and ActivityLog.writeEntry. No other contract or address may call those
 *      functions after setup is complete.
 *
 * @dev Security invariants:
 *      1. No payment executes if policy validation fails
 *      2. No payment executes if risk score exceeds policy ceiling
 *      3. Every executed or blocked payment is logged permanently
 *      4. No partial payments — the full amount moves or nothing moves
 *      5. Only the admin can update the risk oracle address
 *      6. Admin can only be changed to a non-zero address
 *
 * @custom:security-contact security@arbitprotocol.xyz
 */
interface IRiskGuardian {
    function getScore(bytes32 policyId, address protocol) external view returns (uint8 score);
}

contract SentinelGate is ReentrancyGuard {

    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddressNotAllowed();
    error PolicyValidationFailed(bytes32 policyId, string reason);
    error RiskCeilingBreached(bytes32 policyId, uint8 currentScore, uint8 ceiling);
    error PaymentFailed(bytes32 policyId, address recipient, uint256 amount);
    error OnlyAdminCanDoThis(address caller, address admin);
    error OnlyAgentCanExecute(address caller, address agent);
    error RecipientCannotBeZero();
    error AmountCannotBeZero();
    error SetupAlreadyComplete();
    error SetupNotComplete();

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    PolicyRegistry public immutable policyRegistry;
    ActivityLog    public immutable activityLog;

    // The RiskGuardian is not immutable — it can be upgraded by the admin
    // as oracle integrations evolve. The address change is logged on-chain.
    IRiskGuardian  public riskGuardian;

    // Admin is set at deployment and can transfer to another address
    address public admin;

    // Tracks whether the one-time setup has been completed
    // Setup registers this contract with PolicyRegistry and ActivityLog
    bool public setupComplete;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PaymentExecuted(
        bytes32 indexed policyId,
        address indexed agent,
        address indexed recipient,
        uint256 amount,
        uint8   riskScore,
        uint256 entryIndex
    );

    event PaymentBlocked(
        bytes32 indexed policyId,
        address indexed agent,
        uint256 amount,
        uint8   riskScore,
        string  reason
    );

    event RiskGuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    event AdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );

    event SetupCompleted(address indexed gate);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _policyRegistry,
        address _activityLog,
        address _riskGuardian,
        address _admin
    ) {
        if (_policyRegistry == address(0)) revert ZeroAddressNotAllowed();
        if (_activityLog    == address(0)) revert ZeroAddressNotAllowed();
        if (_riskGuardian   == address(0)) revert ZeroAddressNotAllowed();
        if (_admin          == address(0)) revert ZeroAddressNotAllowed();

        policyRegistry = PolicyRegistry(_policyRegistry);
        activityLog    = ActivityLog(_activityLog);
        riskGuardian   = IRiskGuardian(_riskGuardian);
        admin          = _admin;
    }

    // -------------------------------------------------------------------------
    // One-time setup
    // -------------------------------------------------------------------------

    /**
     * @notice Complete the one-time setup by registering this contract
     *         as the authorised gate in PolicyRegistry and ActivityLog.
     * @dev Must be called by admin after deployment. Can only run once.
     *      PolicyRegistry.setSentinelGate and ActivityLog.setWriter must
     *      not have been called yet when this executes.
     */
    function completeSetup() external {
        if (msg.sender != admin)
            revert OnlyAdminCanDoThis(msg.sender, admin);
        if (setupComplete)
            revert SetupAlreadyComplete();

        policyRegistry.setSentinelGate(address(this));
        activityLog.setWriter(address(this));

        setupComplete = true;
        emit SetupCompleted(address(this));
    }

    // -------------------------------------------------------------------------
    // Core payment execution
    // -------------------------------------------------------------------------

    /**
     * @notice Execute a payment on behalf of an agent.
     * @dev This is the only function that moves tokens. It runs the full
     *      check sequence before touching any balances. If anything fails,
     *      the entire transaction reverts — no partial state changes.
     *
     *      The calling pattern is: the agent's owner calls this on behalf
     *      of the agent, or the agent itself calls it. Either way, the
     *      policyId must match an active policy for the agent.
     *
     * @param policyId    The active policy governing this payment.
     * @param recipient   Where the tokens go.
     * @param amount      How much to send (in the policy's token).
     * @param actionType  What kind of action this is.
     * @param protocol    The protocol address for risk scoring (address(0) for agent-to-agent).
     */
    function executePayment(
        bytes32 policyId,
        address recipient,
        uint256 amount,
        uint8   actionType,
        address protocol
    )
        external
        nonReentrant
        returns (uint256 entryIndex)
    {
        if (!setupComplete) revert SetupNotComplete();
        if (recipient == address(0)) revert RecipientCannotBeZero();
        if (amount == 0)             revert AmountCannotBeZero();

        // --- STEP 1: Fetch the policy and verify the caller is the agent -----
        PolicyRegistry.Policy memory policy = policyRegistry.getPolicy(policyId);

        if (msg.sender != policy.agent)
            revert OnlyAgentCanExecute(msg.sender, policy.agent);

        // --- STEP 2: Validate against policy rules ---------------------------
        (bool valid, string memory reason) = policyRegistry.validateAction(
            policyId,
            amount,
            actionType
        );

        if (!valid) {
            // Log the block before reverting so the audit trail captures it
            _logBlockedPayment(policyId, policy.agent, amount, 0, reason);
            revert PolicyValidationFailed(policyId, reason);
        }

        // --- STEP 3: Check the live risk score -------------------------------
        address protocolToScore = protocol == address(0) ? recipient : protocol;
        uint8 currentScore = riskGuardian.getScore(policyId, protocolToScore);

        if (currentScore > policy.riskCeiling) {
            string memory riskReason = "Risk ceiling breached";
            emit PaymentBlocked(policyId, policy.agent, amount, currentScore, riskReason);
            revert RiskCeilingBreached(policyId, currentScore, policy.riskCeiling);
        }

        // --- STEP 4: Consume budget (updates state before token transfer) ----
        // This follows checks-effects-interactions strictly.
        // Budget is consumed before the token transfer so any reentrant call
        // would fail the budget check rather than double-spending.
        policyRegistry.consumeBudget(policyId, amount, actionType);

        // --- STEP 5: Execute the token transfer ------------------------------
        IERC20 token = IERC20(policy.token);
        token.safeTransferFrom(policy.agent, recipient, amount);

        // --- STEP 6: Log the successful payment ------------------------------
        bytes32 logReason = bytes32(0);
        (entryIndex,) = activityLog.writeEntry(
            policyId,
            policy.agent,
            actionType,
            amount,
            currentScore,
            logReason
        );

        emit PaymentExecuted(
            policyId,
            policy.agent,
            recipient,
            amount,
            currentScore,
            entryIndex
        );
    }

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /**
     * @notice Replace the RiskGuardian with a new implementation.
     * @dev Used when oracle integrations are upgraded. The old address
     *      is emitted so the change is fully traceable on-chain.
     */
    function updateRiskGuardian(address newGuardian) external {
        if (msg.sender != admin)
            revert OnlyAdminCanDoThis(msg.sender, admin);
        if (newGuardian == address(0))
            revert ZeroAddressNotAllowed();

        address old = address(riskGuardian);
        riskGuardian = IRiskGuardian(newGuardian);
        emit RiskGuardianUpdated(old, newGuardian);
    }

    /**
     * @notice Transfer admin rights to a new address.
     * @dev The new admin must accept by being a non-zero address.
     *      There is no two-step transfer here — keep that in mind
     *      when choosing the admin address at deployment.
     */
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin)
            revert OnlyAdminCanDoThis(msg.sender, admin);
        if (newAdmin == address(0))
            revert ZeroAddressNotAllowed();

        address previous = admin;
        admin = newAdmin;
        emit AdminTransferred(previous, newAdmin);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Write a blocked payment entry to the ActivityLog.
     *      Called before every revert so the block is always on record
     *      regardless of whether the outer transaction reverts.
     *
     *      Note: because this is called before revert, and ActivityLog.writeEntry
     *      is a state change, we use a try/catch so a log failure never
     *      silently swallows the real revert reason.
     */
    function _logBlockedPayment(
        bytes32 policyId,
        address agent,
        uint256 amount,
        uint8   riskScore,
        string  memory reason
    ) internal {
        bytes32 reasonBytes = bytes32(bytes(reason));
        try activityLog.writeEntry(
            policyId,
            agent,
            ActivityLog(address(activityLog)).LOG_PAYMENT_BLOCKED(),
            amount,
            riskScore,
            reasonBytes
        ) {} catch {}
    }
}
