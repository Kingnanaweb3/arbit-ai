// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ActivityLog
 * @author Arbit Protocol
 * @notice Every action an agent takes under Arbit is written here permanently.
 *         Think of it as the agent's black box — an append-only record that
 *         nobody can alter, not even the protocol itself.
 *
 * @dev The tamper-proof guarantee comes from two mechanisms working together:
 *      1. No delete or update functions exist anywhere in this contract.
 *         You cannot remove what has been written. The ABI does not allow it.
 *      2. Every entry hashes the previous entry's hash into itself, creating
 *         a cryptographic chain. Altering any past entry breaks every hash
 *         that follows it — making silent tampering mathematically impossible.
 *
 * @dev Security invariants:
 *      1. entryCount only ever increases — never decreases
 *      2. latestHash always reflects the most recent entry
 *      3. Only the authorised writer address can add entries
 *      4. The writer address can only be set once and never changed
 *
 * @custom:security-contact security@arbitprotocol.xyz
 */
contract ActivityLog {

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddressNotAllowed();
    error WriterAlreadySet();
    error OnlyWriterCanDoThis(address caller, address writer);
    error EntryDoesNotExist(uint256 index, uint256 totalEntries);
    error EmptyReasonNotAllowed();

    // -------------------------------------------------------------------------
    // Action type constants — must stay in sync with PolicyRegistry
    // -------------------------------------------------------------------------

    uint8 public constant ACTION_DATA_FEED   = 0;
    uint8 public constant ACTION_DEX_SWAP    = 1;
    uint8 public constant ACTION_LENDING     = 2;
    uint8 public constant ACTION_MARKETPLACE = 3;
    uint8 public constant ACTION_YIELD       = 4;

    // Log entry types that go beyond normal agent actions
    uint8 public constant LOG_PAYMENT_EXECUTED  = 10;
    uint8 public constant LOG_PAYMENT_BLOCKED   = 11;
    uint8 public constant LOG_RISK_RESUME       = 12;
    uint8 public constant LOG_POLICY_REVOKED    = 13;
    uint8 public constant LOG_AGENT_HIRED       = 14;
    uint8 public constant LOG_STAKE_SLASHED     = 15;

    // -------------------------------------------------------------------------
    // The log entry structure
    // -------------------------------------------------------------------------

    /**
     * @dev Each entry captures the full context of what happened, why it
     *      happened, and where it fits in the chain of all past entries.
     *      Nothing here can be changed after it is written.
     */
    struct LogEntry {
        // Which policy was active when this action occurred
        bytes32 policyId;

        // The agent wallet that took the action
        address agent;

        // What kind of action this was — use the constants above
        uint8 actionType;

        // How much USDC moved (or was blocked from moving)
        uint256 amount;

        // The risk score at the exact moment this entry was written
        uint8 riskScoreAtTime;

        // A short human-readable reason — required for blocked payments
        bytes32 reason;

        // When this happened
        uint256 timestamp;

        // The hash of the entry before this one in the chain
        // Entry 0 uses bytes32(0) as its predecessor
        bytes32 previousEntryHash;

        // The hash of this entry itself — computed at write time
        // and stored so anyone can verify the chain without recomputing
        bytes32 entryHash;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    // The canonical ordered list of all log entries ever written
    LogEntry[] private entries;

    // The hash of the most recently written entry
    // Always updated atomically with the entry write
    bytes32 public latestHash;

    // Total number of entries written — only ever increases
    uint256 public entryCount;

    // The only address permitted to write entries
    // Set once at deployment, never changeable
    address public writer;
    bool    private writerSet;

    // Per-policy index for efficient lookup of an agent's history
    // Maps policyId => array of entry indices in the main entries array
    mapping(bytes32 => uint256[]) private policyEntryIndices;

    // Per-agent index for the same reason
    mapping(address => uint256[]) private agentEntryIndices;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EntryWritten(
        uint256 indexed entryIndex,
        bytes32 indexed policyId,
        address indexed agent,
        uint8 actionType,
        uint256 amount,
        bytes32 entryHash
    );

    event WriterAuthorised(address indexed writer);

    // -------------------------------------------------------------------------
    // One-time writer setup
    // -------------------------------------------------------------------------

    /**
     * @notice Authorise the SentinelGate contract as the sole writer.
     * @dev Called once after SentinelGate is deployed. After this call
     *      the writer is permanently locked. There is no override.
     */
    function setWriter(address _writer) external {
        if (writerSet) revert WriterAlreadySet();
        if (_writer == address(0)) revert ZeroAddressNotAllowed();
        writer = _writer;
        writerSet = true;
        emit WriterAuthorised(_writer);
    }

    modifier onlyWriter() {
        if (msg.sender != writer)
            revert OnlyWriterCanDoThis(msg.sender, writer);
        _;
    }

    // -------------------------------------------------------------------------
    // Writing entries
    // -------------------------------------------------------------------------

    /**
     * @notice Write a new entry to the log.
     * @dev Only SentinelGate may call this. Every field is recorded as-is
     *      with no transformation. The cryptographic chain is maintained
     *      automatically — the caller does not need to manage it.
     *
     * @param policyId       The active policy at time of action.
     * @param agent          The agent that acted.
     * @param actionType     What kind of action occurred.
     * @param amount         How much USDC was involved.
     * @param riskScore      The RiskGuardian score at this moment.
     * @param reason         Why this happened — required for blocked entries.
     */
    function writeEntry(
        bytes32 policyId,
        address agent,
        uint8   actionType,
        uint256 amount,
        uint8   riskScore,
        bytes32 reason
    )
        external
        onlyWriter
        returns (uint256 entryIndex, bytes32 entryHash)
    {
        // --- CHECKS ----------------------------------------------------------

        if (agent == address(0)) revert ZeroAddressNotAllowed();

        // Blocked payment entries must always carry a reason
        // so the audit trail explains why the payment did not go through
        if (actionType == LOG_PAYMENT_BLOCKED && reason == bytes32(0))
            revert EmptyReasonNotAllowed();

        // --- EFFECTS ---------------------------------------------------------

        entryIndex = entryCount;

        // Build the entry hash by hashing all fields together with the
        // previous entry's hash. This is what creates the cryptographic chain.
        entryHash = keccak256(abi.encodePacked(
            policyId,
            agent,
            actionType,
            amount,
            riskScore,
            reason,
            block.timestamp,
            latestHash       // previous entry's hash — links the chain
        ));

        LogEntry memory entry = LogEntry({
            policyId:          policyId,
            agent:             agent,
            actionType:        actionType,
            amount:            amount,
            riskScoreAtTime:   riskScore,
            reason:            reason,
            timestamp:         block.timestamp,
            previousEntryHash: latestHash,
            entryHash:         entryHash
        });

        // Write to storage in a single push — no partial writes possible
        entries.push(entry);

        // Update the chain tip and counter atomically
        latestHash = entryHash;
        entryCount++;

        // Update the lookup indices for efficient querying
        policyEntryIndices[policyId].push(entryIndex);
        agentEntryIndices[agent].push(entryIndex);

        emit EntryWritten(
            entryIndex,
            policyId,
            agent,
            actionType,
            amount,
            entryHash
        );
    }

    // -------------------------------------------------------------------------
    // Reading entries
    // -------------------------------------------------------------------------

    /**
     * @notice Fetch a single entry by its position in the log.
     */
    function getEntry(uint256 index)
        external
        view
        returns (LogEntry memory)
    {
        if (index >= entryCount)
            revert EntryDoesNotExist(index, entryCount);
        return entries[index];
    }

    /**
     * @notice Fetch all entry indices recorded against a specific policy.
     * @dev Returns indices into the main log — call getEntry for each one.
     */
    function getEntriesForPolicy(bytes32 policyId)
        external
        view
        returns (uint256[] memory)
    {
        return policyEntryIndices[policyId];
    }

    /**
     * @notice Fetch all entry indices recorded against a specific agent.
     */
    function getEntriesForAgent(address agent)
        external
        view
        returns (uint256[] memory)
    {
        return agentEntryIndices[agent];
    }

    /**
     * @notice Verify that the chain is intact from a given starting entry.
     * @dev Recomputes every hash from startIndex to the current tip and
     *      checks each one matches what was stored at write time.
     *      Returns true only if every link in the chain is unbroken.
     *
     *      This is the tamper-detection function. If anyone has managed to
     *      alter any entry in storage, this function will return false.
     *
     * @param startIndex  Where to begin verification (0 = from the beginning)
     * @return intact     Whether the chain is unbroken from startIndex to tip
     * @return brokenAt   The index where the first break was found (if any)
     */
    function verifyChain(uint256 startIndex)
        external
        view
        returns (bool intact, uint256 brokenAt)
    {
        if (entryCount == 0) return (true, 0);
        if (startIndex >= entryCount)
            revert EntryDoesNotExist(startIndex, entryCount);

        for (uint256 i = startIndex; i < entryCount; i++) {
            LogEntry storage entry = entries[i];

            bytes32 expected = keccak256(abi.encodePacked(
                entry.policyId,
                entry.agent,
                entry.actionType,
                entry.amount,
                entry.riskScoreAtTime,
                entry.reason,
                entry.timestamp,
                entry.previousEntryHash
            ));

            if (expected != entry.entryHash) {
                return (false, i);
            }
        }

        return (true, 0);
    }

    /**
     * @notice Get the most recent N entries across the entire log.
     * @dev Useful for the demo — shows the last few actions at a glance.
     */
    function getRecentEntries(uint256 count)
        external
        view
        returns (LogEntry[] memory recent)
    {
        if (entryCount == 0) return new LogEntry[](0);

        uint256 actualCount = count > entryCount ? entryCount : count;
        recent = new LogEntry[](actualCount);

        for (uint256 i = 0; i < actualCount; i++) {
            recent[i] = entries[entryCount - actualCount + i];
        }
    }
}