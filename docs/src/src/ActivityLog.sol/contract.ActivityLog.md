# ActivityLog
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/ActivityLog.sol)

**Title:**
ActivityLog

**Author:**
Arbit Protocol

Every action an agent takes under Arbit is written here permanently.
Think of it as the agent's black box — an append-only record that
nobody can alter, not even the protocol itself.

The tamper-proof guarantee comes from two mechanisms working together:
1. No delete or update functions exist anywhere in this contract.
You cannot remove what has been written. The ABI does not allow it.
2. Every entry hashes the previous entry's hash into itself, creating
a cryptographic chain. Altering any past entry breaks every hash
that follows it — making silent tampering mathematically impossible.

Security invariants:
1. entryCount only ever increases — never decreases
2. latestHash always reflects the most recent entry
3. Only the authorised writer address can add entries
4. The writer address can only be set once and never changed

**Note:**
security-contact: security@arbitprotocol.xyz


## Constants
### ACTION_DATA_FEED

```solidity
uint8 public constant ACTION_DATA_FEED = 0
```


### ACTION_DEX_SWAP

```solidity
uint8 public constant ACTION_DEX_SWAP = 1
```


### ACTION_LENDING

```solidity
uint8 public constant ACTION_LENDING = 2
```


### ACTION_MARKETPLACE

```solidity
uint8 public constant ACTION_MARKETPLACE = 3
```


### ACTION_YIELD

```solidity
uint8 public constant ACTION_YIELD = 4
```


### LOG_PAYMENT_EXECUTED

```solidity
uint8 public constant LOG_PAYMENT_EXECUTED = 10
```


### LOG_PAYMENT_BLOCKED

```solidity
uint8 public constant LOG_PAYMENT_BLOCKED = 11
```


### LOG_RISK_RESUME

```solidity
uint8 public constant LOG_RISK_RESUME = 12
```


### LOG_POLICY_REVOKED

```solidity
uint8 public constant LOG_POLICY_REVOKED = 13
```


### LOG_AGENT_HIRED

```solidity
uint8 public constant LOG_AGENT_HIRED = 14
```


### LOG_STAKE_SLASHED

```solidity
uint8 public constant LOG_STAKE_SLASHED = 15
```


## State Variables
### entries

```solidity
LogEntry[] private entries
```


### latestHash

```solidity
bytes32 public latestHash
```


### entryCount

```solidity
uint256 public entryCount
```


### writer

```solidity
address public writer
```


### writerSet

```solidity
bool private writerSet
```


### policyEntryIndices

```solidity
mapping(bytes32 => uint256[]) private policyEntryIndices
```


### agentEntryIndices

```solidity
mapping(address => uint256[]) private agentEntryIndices
```


## Functions
### setWriter

Authorise the SentinelGate contract as the sole writer.

Called once after SentinelGate is deployed. After this call
the writer is permanently locked. There is no override.


```solidity
function setWriter(address _writer) external;
```

### onlyWriter


```solidity
modifier onlyWriter() ;
```

### writeEntry

Write a new entry to the log.

Only SentinelGate may call this. Every field is recorded as-is
with no transformation. The cryptographic chain is maintained
automatically — the caller does not need to manage it.


```solidity
function writeEntry(
    bytes32 policyId,
    address agent,
    uint8 actionType,
    uint256 amount,
    uint8 riskScore,
    bytes32 reason
) external onlyWriter returns (uint256 entryIndex, bytes32 entryHash);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`policyId`|`bytes32`|      The active policy at time of action.|
|`agent`|`address`|         The agent that acted.|
|`actionType`|`uint8`|    What kind of action occurred.|
|`amount`|`uint256`|        How much USDC was involved.|
|`riskScore`|`uint8`|     The RiskGuardian score at this moment.|
|`reason`|`bytes32`|        Why this happened — required for blocked entries.|


### getEntry

Fetch a single entry by its position in the log.


```solidity
function getEntry(uint256 index) external view returns (LogEntry memory);
```

### getEntriesForPolicy

Fetch all entry indices recorded against a specific policy.

Returns indices into the main log — call getEntry for each one.


```solidity
function getEntriesForPolicy(bytes32 policyId) external view returns (uint256[] memory);
```

### getEntriesForAgent

Fetch all entry indices recorded against a specific agent.


```solidity
function getEntriesForAgent(address agent) external view returns (uint256[] memory);
```

### verifyChain

Verify that the chain is intact from a given starting entry.

Recomputes every hash from startIndex to the current tip and
checks each one matches what was stored at write time.
Returns true only if every link in the chain is unbroken.
This is the tamper-detection function. If anyone has managed to
alter any entry in storage, this function will return false.


```solidity
function verifyChain(uint256 startIndex) external view returns (bool intact, uint256 brokenAt);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`startIndex`|`uint256`| Where to begin verification (0 = from the beginning)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`intact`|`bool`|    Whether the chain is unbroken from startIndex to tip|
|`brokenAt`|`uint256`|  The index where the first break was found (if any)|


### getRecentEntries

Get the most recent N entries across the entire log.

Useful for the demo — shows the last few actions at a glance.


```solidity
function getRecentEntries(uint256 count) external view returns (LogEntry[] memory recent);
```

## Events
### EntryWritten

```solidity
event EntryWritten(
    uint256 indexed entryIndex,
    bytes32 indexed policyId,
    address indexed agent,
    uint8 actionType,
    uint256 amount,
    bytes32 entryHash
);
```

### WriterAuthorised

```solidity
event WriterAuthorised(address indexed writer);
```

## Errors
### ZeroAddressNotAllowed

```solidity
error ZeroAddressNotAllowed();
```

### WriterAlreadySet

```solidity
error WriterAlreadySet();
```

### OnlyWriterCanDoThis

```solidity
error OnlyWriterCanDoThis(address caller, address writer);
```

### EntryDoesNotExist

```solidity
error EntryDoesNotExist(uint256 index, uint256 totalEntries);
```

### EmptyReasonNotAllowed

```solidity
error EmptyReasonNotAllowed();
```

## Structs
### LogEntry
Each entry captures the full context of what happened, why it
happened, and where it fits in the chain of all past entries.
Nothing here can be changed after it is written.


```solidity
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
```

