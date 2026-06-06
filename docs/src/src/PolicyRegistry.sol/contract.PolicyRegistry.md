# PolicyRegistry
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/PolicyRegistry.sol)

**Inherits:**
ReentrancyGuard


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


### MAX_ACTION_TYPE

```solidity
uint8 public constant MAX_ACTION_TYPE = 4
```


### MAX_RISK_CEILING

```solidity
uint8 public constant MAX_RISK_CEILING = 100
```


### ABSOLUTE_RISK_FLOOR

```solidity
uint8 public constant ABSOLUTE_RISK_FLOOR = 1
```


### MAX_SCOPE_ENTRIES

```solidity
uint256 public constant MAX_SCOPE_ENTRIES = 10
```


## State Variables
### policies

```solidity
mapping(bytes32 => Policy) private policies
```


### ownerPolicies

```solidity
mapping(address => bytes32[]) private ownerPolicies
```


### agentActivePolicy

```solidity
mapping(address => bytes32) private agentActivePolicy
```


### ownerNonce

```solidity
mapping(address => uint256) private ownerNonce
```


### sentinelGate

```solidity
address public sentinelGate
```


### gateSet

```solidity
bool private gateSet = false
```


## Functions
### setSentinelGate


```solidity
function setSentinelGate(address _gate) external;
```

### onlySentinelGate


```solidity
modifier onlySentinelGate() ;
```

### registerPolicy


```solidity
function registerPolicy(
    address agent,
    address token,
    uint256 maxBudget,
    uint256 maxTransactionSize,
    uint256 expiry,
    uint8 riskCeiling,
    uint8[] calldata permittedActions
) external nonReentrant returns (bytes32 policyId);
```

### consumeBudget


```solidity
function consumeBudget(bytes32 policyId, uint256 amount, uint8 actionType) external nonReentrant onlySentinelGate;
```

### revokePolicy


```solidity
function revokePolicy(bytes32 policyId) external nonReentrant;
```

### increaseBudget


```solidity
function increaseBudget(bytes32 policyId, uint256 additionalAmount) external nonReentrant;
```

### extendExpiry


```solidity
function extendExpiry(bytes32 policyId, uint256 newExpiry) external nonReentrant;
```

### updateRiskCeiling


```solidity
function updateRiskCeiling(bytes32 policyId, uint8 newCeiling) external nonReentrant;
```

### validateAction


```solidity
function validateAction(bytes32 policyId, uint256 amount, uint8 actionType)
    external
    view
    returns (bool valid, string memory reason);
```

### getPolicy


```solidity
function getPolicy(bytes32 policyId) external view returns (Policy memory);
```

### getRemainingBudget


```solidity
function getRemainingBudget(bytes32 policyId) external view returns (uint256);
```

### getActivePolicyForAgent


```solidity
function getActivePolicyForAgent(address agent) external view returns (bytes32);
```

### getPoliciesByOwner


```solidity
function getPoliciesByOwner(address owner) external view returns (bytes32[] memory);
```

### isPolicyActive


```solidity
function isPolicyActive(bytes32 policyId) external view returns (bool);
```

### _requireActivePolicy


```solidity
function _requireActivePolicy(bytes32 policyId) internal view returns (Policy storage policy);
```

### _requireOwnerAndActive


```solidity
function _requireOwnerAndActive(bytes32 policyId) internal view returns (Policy storage policy);
```

### _isActionPermitted


```solidity
function _isActionPermitted(Policy storage policy, uint8 actionType) internal view returns (bool);
```

## Events
### PolicyRegistered

```solidity
event PolicyRegistered(
    bytes32 indexed policyId, address indexed owner, address indexed agent, uint256 maxBudget, uint256 expiry
);
```

### PolicyRevoked

```solidity
event PolicyRevoked(bytes32 indexed policyId, address indexed revokedBy, uint256 timestamp);
```

### BudgetConsumed

```solidity
event BudgetConsumed(bytes32 indexed policyId, address indexed agent, uint256 amount, uint256 remainingBudget);
```

### PolicyBudgetIncreased

```solidity
event PolicyBudgetIncreased(
    bytes32 indexed policyId, address indexed owner, uint256 addedAmount, uint256 newBudget
);
```

### PolicyExpiryExtended

```solidity
event PolicyExpiryExtended(bytes32 indexed policyId, address indexed owner, uint256 newExpiry);
```

### PolicyRiskCeilingUpdated

```solidity
event PolicyRiskCeilingUpdated(bytes32 indexed policyId, address indexed owner, uint8 oldCeiling, uint8 newCeiling);
```

## Errors
### ZeroAddressNotAllowed

```solidity
error ZeroAddressNotAllowed();
```

### AgentCannotOwnItsPolicy

```solidity
error AgentCannotOwnItsPolicy();
```

### BudgetCannotBeZero

```solidity
error BudgetCannotBeZero();
```

### RiskCeilingOutOfRange

```solidity
error RiskCeilingOutOfRange(uint8 provided, uint8 maximum);
```

### ExpiryMustBeInFuture

```solidity
error ExpiryMustBeInFuture(uint256 provided, uint256 current);
```

### MaxTransactionExceedsBudget

```solidity
error MaxTransactionExceedsBudget(uint256 maxTx, uint256 budget);
```

### ScopeCannotBeEmpty

```solidity
error ScopeCannotBeEmpty();
```

### TooManyActionTypes

```solidity
error TooManyActionTypes(uint256 provided, uint256 maximum);
```

### PolicyDoesNotExist

```solidity
error PolicyDoesNotExist(bytes32 policyId);
```

### PolicyAlreadyRevoked

```solidity
error PolicyAlreadyRevoked(bytes32 policyId);
```

### PolicyExpired

```solidity
error PolicyExpired(bytes32 policyId, uint256 expiry, uint256 current);
```

### PolicyNotActive

```solidity
error PolicyNotActive(bytes32 policyId);
```

### OnlyOwnerCanDoThis

```solidity
error OnlyOwnerCanDoThis(address caller, address owner);
```

### AgentCannotModifyOwnPolicy

```solidity
error AgentCannotModifyOwnPolicy(address agent);
```

### InsufficientBudget

```solidity
error InsufficientBudget(uint256 requested, uint256 remaining);
```

### TransactionExceedsMaxSize

```solidity
error TransactionExceedsMaxSize(uint256 amount, uint256 maxTx);
```

### ActionTypeNotPermitted

```solidity
error ActionTypeNotPermitted(bytes32 policyId, uint8 actionType);
```

### NothingToWithdraw

```solidity
error NothingToWithdraw();
```

### WithdrawalFailed

```solidity
error WithdrawalFailed();
```

## Structs
### Policy

```solidity
struct Policy {
    address owner;
    address agent;
    address token;
    uint256 maxBudget;
    uint256 spentAmount;
    uint256 maxTransactionSize;
    uint256 expiry;
    uint8 riskCeiling;
    bool isActive;
    uint8[] permittedActions;
}
```

