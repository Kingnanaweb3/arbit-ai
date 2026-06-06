# ReputationStaking
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/ReputationStaking.sol)

**Inherits:**
ReentrancyGuard

**Title:**
ReputationStaking

**Author:**
Arbit Protocol

Agents stake USDC to list services on the Arbit marketplace.
That stake is their skin in the game. Deliver good service and
the stake stays intact. Behave maliciously or fail to perform
and the stake gets slashed — funds go to the harmed buyer and
the protocol treasury.

Security invariants:
1. An agent cannot list without meeting the minimum stake
2. Stake can only be withdrawn when the agent is not listed
3. Only the slash authority can slash a stake
4. Slashed amount never exceeds the staked amount
5. Treasury address can only be set once
6. Slash authority can only be set once

**Note:**
security-contact: security@arbitprotocol.xyz


## Constants
### MINIMUM_STAKE

```solidity
uint256 public constant MINIMUM_STAKE = 100e6
```


### BUYER_SLASH_SHARE_BPS

```solidity
uint256 public constant BUYER_SLASH_SHARE_BPS = 7000
```


### BASIS_POINTS

```solidity
uint256 public constant BASIS_POINTS = 10000
```


### CATEGORY_DATA_FEED

```solidity
uint8 public constant CATEGORY_DATA_FEED = 0
```


### CATEGORY_DEX_SWAP

```solidity
uint8 public constant CATEGORY_DEX_SWAP = 1
```


### CATEGORY_LENDING

```solidity
uint8 public constant CATEGORY_LENDING = 2
```


### CATEGORY_EXECUTION

```solidity
uint8 public constant CATEGORY_EXECUTION = 3
```


### CATEGORY_YIELD

```solidity
uint8 public constant CATEGORY_YIELD = 4
```


### MAX_CATEGORY

```solidity
uint8 public constant MAX_CATEGORY = 4
```


### stakingToken

```solidity
IERC20 public immutable stakingToken
```


## State Variables
### treasury

```solidity
address public treasury
```


### treasurySet

```solidity
bool private treasurySet
```


### slashAuthority

```solidity
address public slashAuthority
```


### slashAuthoritySet

```solidity
bool private slashAuthoritySet
```


### listings

```solidity
mapping(address => ServiceListing) private listings
```


### listedAgents

```solidity
address[] private listedAgents
```


### everListed

```solidity
mapping(address => bool) private everListed
```


### totalStaked

```solidity
uint256 public totalStaked
```


## Functions
### constructor


```solidity
constructor(address _stakingToken) ;
```

### setSlashAuthority


```solidity
function setSlashAuthority(address _authority) external;
```

### setTreasury


```solidity
function setTreasury(address _treasury) external;
```

### onlySlashAuthority


```solidity
modifier onlySlashAuthority() ;
```

### setupComplete


```solidity
modifier setupComplete() ;
```

### listService

List a service on the marketplace by staking USDC.

The agent must approve this contract to spend their USDC first.
Stake is locked for as long as the listing is active.


```solidity
function listService(uint256 stakeAmount, uint256 pricePerCall, uint8 category, bytes32 description)
    external
    nonReentrant
    setupComplete;
```

### delistService

Delist a service and withdraw the full stake.

Only the agent themselves can delist. Suspended agents
cannot delist — the slash authority must reinstate first.


```solidity
function delistService() external nonReentrant;
```

### increaseStake

Add more stake to an active listing.

More stake signals higher commitment and improves reputation score.


```solidity
function increaseStake(uint256 additionalAmount) external nonReentrant;
```

### slashStake

Slash an agent's stake for malicious or failed service.

Only the slash authority (SentinelGate) can call this.
70% goes to the harmed buyer, 30% to the protocol treasury.
If the slash amount exceeds the stake, we slash everything.


```solidity
function slashStake(address agent, address buyer, uint256 slashAmount, string calldata reason)
    external
    nonReentrant
    onlySlashAuthority;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`agent`|`address`|      The misbehaving agent.|
|`buyer`|`address`|      Who was harmed — receives 70% of the slash.|
|`slashAmount`|`uint256`|How much to slash.|
|`reason`|`string`|     Why this slash is happening.|


### recordCall

Record the outcome of a service call.

Updates the agent's success/failure counters which feed
into the reputation score calculation.


```solidity
function recordCall(address agent, bool success) external onlySlashAuthority;
```

### reinstateService

Reinstate a suspended agent after they have topped up their stake.

Only the slash authority can reinstate — prevents self-reinstatement.


```solidity
function reinstateService(address agent) external onlySlashAuthority;
```

### getListing


```solidity
function getListing(address agent) external view returns (ServiceListing memory);
```

### isListed


```solidity
function isListed(address agent) external view returns (bool);
```

### getReputationScore


```solidity
function getReputationScore(address agent) external view returns (uint8 score);
```

### getActiveListings


```solidity
function getActiveListings() external view returns (address[] memory active);
```

### getTotalListings


```solidity
function getTotalListings() external view returns (uint256);
```

## Events
### ServiceListed

```solidity
event ServiceListed(address indexed agent, uint8 category, uint256 pricePerCall, uint256 stakedAmount);
```

### ServiceDelisted

```solidity
event ServiceDelisted(address indexed agent, uint256 stakeReturned);
```

### StakeIncreased

```solidity
event StakeIncreased(address indexed agent, uint256 addedAmount, uint256 newTotal);
```

### StakeSlashed

```solidity
event StakeSlashed(
    address indexed agent,
    address indexed buyer,
    uint256 slashedAmount,
    uint256 buyerReceived,
    uint256 treasuryReceived
);
```

### ServiceSuspended

```solidity
event ServiceSuspended(address indexed agent, string reason);
```

### ServiceReinstated

```solidity
event ServiceReinstated(address indexed agent);
```

### CallRecorded

```solidity
event CallRecorded(address indexed agent, bool success);
```

### SlashAuthoritySet

```solidity
event SlashAuthoritySet(address indexed authority);
```

### TreasurySet

```solidity
event TreasurySet(address indexed treasury);
```

## Errors
### ZeroAddressNotAllowed

```solidity
error ZeroAddressNotAllowed();
```

### ZeroAmountNotAllowed

```solidity
error ZeroAmountNotAllowed();
```

### MinimumStakeNotMet

```solidity
error MinimumStakeNotMet(uint256 provided, uint256 minimum);
```

### AgentAlreadyListed

```solidity
error AgentAlreadyListed(address agent);
```

### AgentNotListed

```solidity
error AgentNotListed(address agent);
```

### InsufficientStake

```solidity
error InsufficientStake(uint256 available, uint256 required);
```

### CannotWithdrawWhileListed

```solidity
error CannotWithdrawWhileListed(address agent);
```

### SlashExceedsStake

```solidity
error SlashExceedsStake(uint256 slashAmount, uint256 stakedAmount);
```

### OnlySlashAuthorityCanDoThis

```solidity
error OnlySlashAuthorityCanDoThis(address caller, address authority);
```

### OnlyAgentCanDoThis

```solidity
error OnlyAgentCanDoThis(address caller, address agent);
```

### SlashAuthorityAlreadySet

```solidity
error SlashAuthorityAlreadySet();
```

### TreasuryAlreadySet

```solidity
error TreasuryAlreadySet();
```

### SetupIncomplete

```solidity
error SetupIncomplete();
```

### ServicePriceTooLow

```solidity
error ServicePriceTooLow();
```

### InvalidCategory

```solidity
error InvalidCategory(uint8 category);
```

### StakeAmountMustBePositive

```solidity
error StakeAmountMustBePositive();
```

## Structs
### ServiceListing

```solidity
struct ServiceListing {
    // The agent providing this service
    address agent;

    // Price per call in USDC
    uint256 pricePerCall;

    // Which category this service falls under
    uint8 category;

    // Current listing status
    ListingStatus status;

    // How much USDC this agent has staked
    uint256 stakedAmount;

    // Total calls completed successfully — used for reputation scoring
    uint256 successfulCalls;

    // Total calls that were disputed or failed
    uint256 failedCalls;

    // When this listing was first created
    uint256 listedAt;

    // A short description of what this service does
    bytes32 description;
}
```

## Enums
### ListingStatus

```solidity
enum ListingStatus {
    Unlisted,
    Active,
    Suspended
}
```

