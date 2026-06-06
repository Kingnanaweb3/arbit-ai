# IRiskGuardian
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/SentinelGate.sol)

**Title:**
SentinelGate

**Author:**
Arbit Protocol

Every payment an agent makes must pass through here.
Two checks run simultaneously before any USDC moves:
1. PolicyRegistry — does this fit the agent's policy?
2. RiskGuardian   — is the current risk score acceptable?
Both must pass. One failure reverts everything.

This contract is the sole authorised caller of PolicyRegistry.consumeBudget
and ActivityLog.writeEntry. No other contract or address may call those
functions after setup is complete.

Security invariants:
1. No payment executes if policy validation fails
2. No payment executes if risk score exceeds policy ceiling
3. Every executed or blocked payment is logged permanently
4. No partial payments — the full amount moves or nothing moves
5. Only the admin can update the risk oracle address
6. Admin can only be changed to a non-zero address

**Note:**
security-contact: security@arbitprotocol.xyz


## Functions
### getScore


```solidity
function getScore(bytes32 policyId, address protocol) external view returns (uint8 score);
```

