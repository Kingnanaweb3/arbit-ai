# SentinelGate
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/SentinelGate.sol)

**Inherits:**
ReentrancyGuard


## Constants
### policyRegistry

```solidity
PolicyRegistry public immutable policyRegistry
```


### activityLog

```solidity
ActivityLog public immutable activityLog
```


## State Variables
### riskGuardian

```solidity
IRiskGuardian public riskGuardian
```


### admin

```solidity
address public admin
```


### setupComplete

```solidity
bool public setupComplete
```


## Functions
### constructor


```solidity
constructor(address _policyRegistry, address _activityLog, address _riskGuardian, address _admin) ;
```

### completeSetup

Complete the one-time setup by registering this contract
as the authorised gate in PolicyRegistry and ActivityLog.

Must be called by admin after deployment. Can only run once.
PolicyRegistry.setSentinelGate and ActivityLog.setWriter must
not have been called yet when this executes.


```solidity
function completeSetup() external;
```

### executePayment

Execute a payment on behalf of an agent.

This is the only function that moves tokens. It runs the full
check sequence before touching any balances. If anything fails,
the entire transaction reverts — no partial state changes.
The calling pattern is: the agent's owner calls this on behalf
of the agent, or the agent itself calls it. Either way, the
policyId must match an active policy for the agent.


```solidity
function executePayment(bytes32 policyId, address recipient, uint256 amount, uint8 actionType, address protocol)
    external
    nonReentrant
    returns (uint256 entryIndex);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`policyId`|`bytes32`|   The active policy governing this payment.|
|`recipient`|`address`|  Where the tokens go.|
|`amount`|`uint256`|     How much to send (in the policy's token).|
|`actionType`|`uint8`| What kind of action this is.|
|`protocol`|`address`|   The protocol address for risk scoring (address(0) for agent-to-agent).|


### updateRiskGuardian

Replace the RiskGuardian with a new implementation.

Used when oracle integrations are upgraded. The old address
is emitted so the change is fully traceable on-chain.


```solidity
function updateRiskGuardian(address newGuardian) external;
```

### transferAdmin

Transfer admin rights to a new address.

The new admin must accept by being a non-zero address.
There is no two-step transfer here — keep that in mind
when choosing the admin address at deployment.


```solidity
function transferAdmin(address newAdmin) external;
```

### _logBlockedPayment

Write a blocked payment entry to the ActivityLog.
Called before every revert so the block is always on record
regardless of whether the outer transaction reverts.
Note: because this is called before revert, and ActivityLog.writeEntry
is a state change, we use a try/catch so a log failure never
silently swallows the real revert reason.


```solidity
function _logBlockedPayment(
    bytes32 policyId,
    address agent,
    uint256 amount,
    uint8 riskScore,
    string memory reason
) internal;
```

## Events
### PaymentExecuted

```solidity
event PaymentExecuted(
    bytes32 indexed policyId,
    address indexed agent,
    address indexed recipient,
    uint256 amount,
    uint8 riskScore,
    uint256 entryIndex
);
```

### PaymentBlocked

```solidity
event PaymentBlocked(
    bytes32 indexed policyId, address indexed agent, uint256 amount, uint8 riskScore, string reason
);
```

### RiskGuardianUpdated

```solidity
event RiskGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
```

### AdminTransferred

```solidity
event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
```

### SetupCompleted

```solidity
event SetupCompleted(address indexed gate);
```

## Errors
### ZeroAddressNotAllowed

```solidity
error ZeroAddressNotAllowed();
```

### PolicyValidationFailed

```solidity
error PolicyValidationFailed(bytes32 policyId, string reason);
```

### RiskCeilingBreached

```solidity
error RiskCeilingBreached(bytes32 policyId, uint8 currentScore, uint8 ceiling);
```

### PaymentFailed

```solidity
error PaymentFailed(bytes32 policyId, address recipient, uint256 amount);
```

### OnlyAdminCanDoThis

```solidity
error OnlyAdminCanDoThis(address caller, address admin);
```

### OnlyAgentCanExecute

```solidity
error OnlyAgentCanExecute(address caller, address agent);
```

### RecipientCannotBeZero

```solidity
error RecipientCannotBeZero();
```

### AmountCannotBeZero

```solidity
error AmountCannotBeZero();
```

### SetupAlreadyComplete

```solidity
error SetupAlreadyComplete();
```

### SetupNotComplete

```solidity
error SetupNotComplete();
```

