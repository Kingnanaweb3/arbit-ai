# RiskGuardian
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/RiskGuardian.sol)

**Title:**
RiskGuardian

**Author:**
Arbit Protocol

The real-time risk scoring engine for Arbit. Before any payment
executes, SentinelGate queries this contract for the current risk
score. If the score exceeds the policy ceiling, the payment is
blocked automatically — no human intervention required.

Scoring uses five weighted dimensions.
Price Volatility 25pct, Oracle Confidence 20pct, TVL Stability 25pct,
Contract Security 20pct, Agent Behaviour 10pct.
Score range: 0 (safe) to 100 (extremely dangerous).
Block threshold: configurable per policy in PolicyRegistry.

The Pyth oracle is the primary data source. Chainlink is used as a
secondary cross-validation layer. If the two feeds diverge by more
than MAX_DIVERGENCE_BPS, the oracle confidence score spikes — this
is the exact signal that was absent during the February 2026 cascade.

Security invariants:
1. Score always returns a value between 0 and 100
2. Oracle divergence always increases the risk score, never decreases it
3. Only the admin can register protocol risk profiles
4. Stale oracle data always produces a high confidence penalty

**Note:**
security-contact: security@arbitprotocol.xyz


## Constants
### PYTH_ARBITRUM_SEPOLIA

```solidity
address public constant PYTH_ARBITRUM_SEPOLIA = 0x940d67A2492bf5e39Ce7AaD5E28e14E4e67D01D3
```


### MAX_DIVERGENCE_BPS

```solidity
uint256 public constant MAX_DIVERGENCE_BPS = 200
```


### MAX_PRICE_AGE

```solidity
uint256 public constant MAX_PRICE_AGE = 60
```


### WEIGHT_VOLATILITY

```solidity
uint8 public constant WEIGHT_VOLATILITY = 25
```


### WEIGHT_ORACLE_CONF

```solidity
uint8 public constant WEIGHT_ORACLE_CONF = 20
```


### WEIGHT_TVL

```solidity
uint8 public constant WEIGHT_TVL = 25
```


### WEIGHT_CONTRACT_SEC

```solidity
uint8 public constant WEIGHT_CONTRACT_SEC = 20
```


### WEIGHT_AGENT_BEHAV

```solidity
uint8 public constant WEIGHT_AGENT_BEHAV = 10
```


### ORACLE_STALE_PENALTY

```solidity
uint8 public constant ORACLE_STALE_PENALTY = 40
```


### ORACLE_DIVERGE_PENALTY

```solidity
uint8 public constant ORACLE_DIVERGE_PENALTY = 30
```


### pyth

```solidity
IPyth public immutable pyth
```


## State Variables
### admin

```solidity
address public admin
```


### protocolProfiles

```solidity
mapping(address => ProtocolRiskProfile) private protocolProfiles
```


### agentProfiles

```solidity
mapping(address => AgentBehaviourProfile) private agentProfiles
```


### dataReporter

```solidity
address public dataReporter
```


## Functions
### constructor


```solidity
constructor(address _pyth, address _admin) ;
```

### onlyAdmin


```solidity
modifier onlyAdmin() ;
```

### onlyReporter


```solidity
modifier onlyReporter() ;
```

### setDataReporter


```solidity
function setDataReporter(address _reporter) external onlyAdmin;
```

### transferAdmin


```solidity
function transferAdmin(address newAdmin) external onlyAdmin;
```

### registerProtocol


```solidity
function registerProtocol(
    address protocol,
    bytes32 pythPriceFeedId,
    address chainlinkFeed,
    uint8 baseSecurityScore,
    uint256 lastAuditTimestamp,
    bool recentExploit,
    uint256 referenceTVL
) external onlyAdmin;
```

### updateProtocolTVL


```solidity
function updateProtocolTVL(address protocol, uint256 newTVL) external onlyReporter;
```

### updateAgentBehaviour


```solidity
function updateAgentBehaviour(
    address agent,
    bool herdingFlagged,
    bool maliciousFlagged,
    uint256 transactionsInWindow
) external onlyReporter;
```

### recordRiskTrigger


```solidity
function recordRiskTrigger(address agent) external onlyReporter;
```

### getScore

Compute the aggregate risk score for a payment.

This is the function SentinelGate calls. It is view-only —
no state changes, no oracle updates. The score reflects the
current state of all five dimensions at this exact moment.


```solidity
function getScore(
    bytes32,
    /* policyId */
    address protocol
)
    external
    view
    returns (uint8 score);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`||
|`protocol`|`address`| The protocol or agent being paid.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`score`|`uint8`|   Aggregate risk score 0-100. Higher = more dangerous.|


### _computeVolatilityScore

Measures how much the asset price has moved relative to
its confidence interval. A wide confidence interval relative
to the price signals high uncertainty and volatility.
Score = (confidence / price) * 1000, capped at 100
A confidence interval of 0.1% of price = score of 1
A confidence interval of 10% of price  = score of 100


```solidity
function _computeVolatilityScore(address protocol) internal view returns (uint8);
```

### _computeOracleConfidenceScore

Measures how reliable the oracle data is at this moment.
Stale data, failed calls, or divergence between Pyth and
Chainlink all increase this score.
This is the dimension that catches oracle manipulation —
the exact attack vector that caused the February 2026 cascade.


```solidity
function _computeOracleConfidenceScore(address protocol) internal view returns (uint8);
```

### _computeTVLScore

Measures whether the protocol's liquidity is draining rapidly.
A TVL drop of more than 20% from the reference point signals
potential bank-run conditions — exactly what precedes a cascade.
Score = ((referenceTVL - currentTVL) / referenceTVL) * 100
20% TVL drop = score of 20
50% TVL drop = score of 50
80% TVL drop = score of 80


```solidity
function _computeTVLScore(address protocol) internal view returns (uint8);
```

### _computeSecurityScore

Measures the security posture of the target protocol.
Based on audit status, audit recency, and recent exploit history.
A recent exploit immediately returns maximum score.
An unaudited protocol gets a high base score.
An audited protocol's score increases gradually over time.


```solidity
function _computeSecurityScore(address protocol) internal view returns (uint8);
```

### _computeAgentBehaviourScore

Measures whether the agent being paid shows signs of
herding, anomalous frequency, or known malicious activity.
This is the dimension that specifically addresses the
multi-agent cascade risk — when many agents herd into the
same exit, each one's behaviour score spikes, which raises
the aggregate score across all of them simultaneously.


```solidity
function _computeAgentBehaviourScore(address agent) internal view returns (uint8);
```

### getProtocolProfile


```solidity
function getProtocolProfile(address protocol) external view returns (ProtocolRiskProfile memory);
```

### getAgentProfile


```solidity
function getAgentProfile(address agent) external view returns (AgentBehaviourProfile memory);
```

### isProtocolRegistered


```solidity
function isProtocolRegistered(address protocol) external view returns (bool);
```

## Events
### ProtocolRegistered

```solidity
event ProtocolRegistered(address indexed protocol, uint8 baseSecurityScore);
```

### ProtocolTVLUpdated

```solidity
event ProtocolTVLUpdated(address indexed protocol, uint256 newTVL);
```

### AgentFlagged

```solidity
event AgentFlagged(address indexed agent, bool herding, bool malicious);
```

### AgentRiskTriggerRecorded

```solidity
event AgentRiskTriggerRecorded(address indexed agent, uint256 totalTriggers);
```

### AdminTransferred

```solidity
event AdminTransferred(address indexed previous, address indexed next);
```

### DataReporterSet

```solidity
event DataReporterSet(address indexed reporter);
```

### RiskScoreComputed

```solidity
event RiskScoreComputed(
    bytes32 indexed policyId,
    address indexed protocol,
    uint8 finalScore,
    uint8 volatilityScore,
    uint8 oracleScore,
    uint8 tvlScore,
    uint8 securityScore,
    uint8 behaviourScore
);
```

## Errors
### ZeroAddressNotAllowed

```solidity
error ZeroAddressNotAllowed();
```

### OnlyAdminCanDoThis

```solidity
error OnlyAdminCanDoThis(address caller, address admin);
```

### InvalidWeight

```solidity
error InvalidWeight(uint256 totalWeight);
```

### StalenessThresholdTooLow

```solidity
error StalenessThresholdTooLow(uint256 provided, uint256 minimum);
```

### ProtocolNotRegistered

```solidity
error ProtocolNotRegistered(address protocol);
```

## Structs
### ProtocolRiskProfile
Risk profile for a registered protocol.
Admins register protocols with their known risk parameters.
Unknown protocols get a conservative default score.


```solidity
struct ProtocolRiskProfile {
    // Has this protocol been registered by the admin
    bool registered;

    // Pyth price feed ID for this protocol's primary asset
    bytes32 pythPriceFeedId;

    // Chainlink aggregator address for cross-validation
    address chainlinkFeed;

    // Base security score set by admin based on audit status
    // 0 = fully audited, recent, multisig — 100 = unaudited, unknown
    uint8 baseSecurityScore;

    // Unix timestamp of the protocol's last known audit
    uint256 lastAuditTimestamp;

    // Whether this protocol has had a recent exploit or bug report
    bool recentExploit;

    // Admin-set TVL reference point — used to detect rapid outflows
    uint256 referenceTVL;

    // Current TVL — updated by the admin or an authorised reporter
    uint256 currentTVL;
}
```

### AgentBehaviourProfile
Behaviour profile for a registered agent.
Tracks signals that indicate herding or anomalous activity.


```solidity
struct AgentBehaviourProfile {
    // How many times this agent has triggered a risk block
    uint256 riskTriggerCount;

    // Timestamp of the last transaction
    uint256 lastTransactionTime;

    // How many transactions in the last observation window
    uint256 transactionsInWindow;

    // Whether this agent is currently flagged for herding
    bool herdingFlagged;

    // Whether this agent address appears in known malicious address lists
    bool maliciousFlagged;
}
```

