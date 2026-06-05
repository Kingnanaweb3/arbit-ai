// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PolicyRegistry is ReentrancyGuard {

    error ZeroAddressNotAllowed();
    error AgentCannotOwnItsPolicy();
    error BudgetCannotBeZero();
    error RiskCeilingOutOfRange(uint8 provided, uint8 maximum);
    error ExpiryMustBeInFuture(uint256 provided, uint256 current);
    error MaxTransactionExceedsBudget(uint256 maxTx, uint256 budget);
    error ScopeCannotBeEmpty();
    error TooManyActionTypes(uint256 provided, uint256 maximum);
    error PolicyDoesNotExist(bytes32 policyId);
    error PolicyAlreadyRevoked(bytes32 policyId);
    error PolicyExpired(bytes32 policyId, uint256 expiry, uint256 current);
    error PolicyNotActive(bytes32 policyId);
    error OnlyOwnerCanDoThis(address caller, address owner);
    error AgentCannotModifyOwnPolicy(address agent);
    error InsufficientBudget(uint256 requested, uint256 remaining);
    error TransactionExceedsMaxSize(uint256 amount, uint256 maxTx);
    error ActionTypeNotPermitted(bytes32 policyId, uint8 actionType);
    error NothingToWithdraw();
    error WithdrawalFailed();

    uint8 public constant ACTION_DATA_FEED   = 0;
    uint8 public constant ACTION_DEX_SWAP    = 1;
    uint8 public constant ACTION_LENDING     = 2;
    uint8 public constant ACTION_MARKETPLACE = 3;
    uint8 public constant ACTION_YIELD       = 4;
    uint8 public constant MAX_ACTION_TYPE    = 4;
    uint8  public constant MAX_RISK_CEILING     = 100;
    uint8  public constant ABSOLUTE_RISK_FLOOR  = 1;
    uint256 public constant MAX_SCOPE_ENTRIES   = 10;

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

    mapping(bytes32 => Policy) private policies;
    mapping(address => bytes32[]) private ownerPolicies;
    mapping(address => bytes32) private agentActivePolicy;
    mapping(address => uint256) private ownerNonce;

    address public sentinelGate;
    bool    private gateSet = false;

    event PolicyRegistered(
        bytes32 indexed policyId,
        address indexed owner,
        address indexed agent,
        uint256 maxBudget,
        uint256 expiry
    );
    event PolicyRevoked(bytes32 indexed policyId, address indexed revokedBy, uint256 timestamp);
    event BudgetConsumed(bytes32 indexed policyId, address indexed agent, uint256 amount, uint256 remainingBudget);
    event PolicyBudgetIncreased(bytes32 indexed policyId, address indexed owner, uint256 addedAmount, uint256 newBudget);
    event PolicyExpiryExtended(bytes32 indexed policyId, address indexed owner, uint256 newExpiry);
    event PolicyRiskCeilingUpdated(bytes32 indexed policyId, address indexed owner, uint8 oldCeiling, uint8 newCeiling);

    function setSentinelGate(address _gate) external {
        if (gateSet) revert OnlyOwnerCanDoThis(msg.sender, sentinelGate);
        if (_gate == address(0)) revert ZeroAddressNotAllowed();
        sentinelGate = _gate;
        gateSet = true;
    }

    modifier onlySentinelGate() {
        if (msg.sender != sentinelGate)
            revert OnlyOwnerCanDoThis(msg.sender, sentinelGate);
        _;
    }

    function registerPolicy(
        address agent,
        address token,
        uint256 maxBudget,
        uint256 maxTransactionSize,
        uint256 expiry,
        uint8 riskCeiling,
        uint8[] calldata permittedActions
    ) external nonReentrant returns (bytes32 policyId) {
        if (agent == address(0)) revert ZeroAddressNotAllowed();
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (agent == msg.sender)  revert AgentCannotOwnItsPolicy();
        if (maxBudget == 0)       revert BudgetCannotBeZero();
        if (riskCeiling < ABSOLUTE_RISK_FLOOR || riskCeiling > MAX_RISK_CEILING)
            revert RiskCeilingOutOfRange(riskCeiling, MAX_RISK_CEILING);
        if (expiry <= block.timestamp)
            revert ExpiryMustBeInFuture(expiry, block.timestamp);
        if (maxTransactionSize > maxBudget)
            revert MaxTransactionExceedsBudget(maxTransactionSize, maxBudget);
        if (permittedActions.length == 0)
            revert ScopeCannotBeEmpty();
        if (permittedActions.length > MAX_SCOPE_ENTRIES)
            revert TooManyActionTypes(permittedActions.length, MAX_SCOPE_ENTRIES);

        for (uint256 i = 0; i < permittedActions.length; i++) {
            if (permittedActions[i] > MAX_ACTION_TYPE)
                revert ActionTypeNotPermitted(bytes32(0), permittedActions[i]);
            for (uint256 j = i + 1; j < permittedActions.length; j++) {
                if (permittedActions[i] == permittedActions[j])
                    revert ActionTypeNotPermitted(bytes32(0), permittedActions[i]);
            }
        }

        policyId = keccak256(abi.encodePacked(msg.sender, agent, ownerNonce[msg.sender]));
        ownerNonce[msg.sender]++;

        policies[policyId] = Policy({
            owner:              msg.sender,
            agent:              agent,
            token:              token,
            maxBudget:          maxBudget,
            spentAmount:        0,
            maxTransactionSize: maxTransactionSize,
            expiry:             expiry,
            riskCeiling:        riskCeiling,
            isActive:           true,
            permittedActions:   permittedActions
        });

        ownerPolicies[msg.sender].push(policyId);
        agentActivePolicy[agent] = policyId;

        emit PolicyRegistered(policyId, msg.sender, agent, maxBudget, expiry);
    }

    function consumeBudget(
        bytes32 policyId,
        uint256 amount,
        uint8 actionType
    ) external nonReentrant onlySentinelGate {
        Policy storage policy = _requireActivePolicy(policyId);

        if (amount > policy.maxTransactionSize)
            revert TransactionExceedsMaxSize(amount, policy.maxTransactionSize);

        uint256 remaining = policy.maxBudget - policy.spentAmount;
        if (amount > remaining)
            revert InsufficientBudget(amount, remaining);

        if (!_isActionPermitted(policy, actionType))
            revert ActionTypeNotPermitted(policyId, actionType);

        policy.spentAmount += amount;
        emit BudgetConsumed(policyId, policy.agent, amount, policy.maxBudget - policy.spentAmount);
    }

    function revokePolicy(bytes32 policyId) external nonReentrant {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0)) revert PolicyDoesNotExist(policyId);
        if (msg.sender != policy.owner) revert OnlyOwnerCanDoThis(msg.sender, policy.owner);
        if (!policy.isActive) revert PolicyAlreadyRevoked(policyId);

        policy.isActive = false;
        agentActivePolicy[policy.agent] = bytes32(0);
        emit PolicyRevoked(policyId, msg.sender, block.timestamp);
    }

    function increaseBudget(bytes32 policyId, uint256 additionalAmount) external nonReentrant {
        if (additionalAmount == 0) revert BudgetCannotBeZero();
        Policy storage policy = _requireOwnerAndActive(policyId);
        policy.maxBudget += additionalAmount;
        emit PolicyBudgetIncreased(policyId, msg.sender, additionalAmount, policy.maxBudget);
    }

    function extendExpiry(bytes32 policyId, uint256 newExpiry) external nonReentrant {
        Policy storage policy = _requireOwnerAndActive(policyId);
        if (newExpiry <= policy.expiry) revert ExpiryMustBeInFuture(newExpiry, policy.expiry);
        policy.expiry = newExpiry;
        emit PolicyExpiryExtended(policyId, msg.sender, newExpiry);
    }

    function updateRiskCeiling(bytes32 policyId, uint8 newCeiling) external nonReentrant {
        if (newCeiling < ABSOLUTE_RISK_FLOOR || newCeiling > MAX_RISK_CEILING)
            revert RiskCeilingOutOfRange(newCeiling, MAX_RISK_CEILING);
        Policy storage policy = _requireOwnerAndActive(policyId);
        uint8 oldCeiling = policy.riskCeiling;
        policy.riskCeiling = newCeiling;
        emit PolicyRiskCeilingUpdated(policyId, msg.sender, oldCeiling, newCeiling);
    }

    function validateAction(
        bytes32 policyId,
        uint256 amount,
        uint8 actionType
    ) external view returns (bool valid, string memory reason) {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0))      return (false, "Policy does not exist");
        if (!policy.isActive)                return (false, "Policy has been revoked");
        if (block.timestamp >= policy.expiry) return (false, "Policy has expired");
        if (amount > policy.maxTransactionSize) return (false, "Amount exceeds max transaction size");
        uint256 remaining = policy.maxBudget - policy.spentAmount;
        if (amount > remaining)              return (false, "Insufficient budget remaining");
        if (!_isActionPermitted(policy, actionType)) return (false, "Action type not permitted by this policy");
        return (true, "");
    }

    function getPolicy(bytes32 policyId) external view returns (Policy memory) {
        if (policies[policyId].owner == address(0)) revert PolicyDoesNotExist(policyId);
        return policies[policyId];
    }

    function getRemainingBudget(bytes32 policyId) external view returns (uint256) {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0)) revert PolicyDoesNotExist(policyId);
        return policy.maxBudget - policy.spentAmount;
    }

    function getActivePolicyForAgent(address agent) external view returns (bytes32) {
        return agentActivePolicy[agent];
    }

    function getPoliciesByOwner(address owner) external view returns (bytes32[] memory) {
        return ownerPolicies[owner];
    }

    function isPolicyActive(bytes32 policyId) external view returns (bool) {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0)) return false;
        return policy.isActive && block.timestamp < policy.expiry;
    }

    function _requireActivePolicy(bytes32 policyId) internal view returns (Policy storage policy) {
        policy = policies[policyId];
        if (policy.owner == address(0)) revert PolicyDoesNotExist(policyId);
        if (!policy.isActive) revert PolicyAlreadyRevoked(policyId);
        if (block.timestamp >= policy.expiry) revert PolicyExpired(policyId, policy.expiry, block.timestamp);
    }

    function _requireOwnerAndActive(bytes32 policyId) internal view returns (Policy storage policy) {
        policy = _requireActivePolicy(policyId);
        if (msg.sender != policy.owner) revert OnlyOwnerCanDoThis(msg.sender, policy.owner);
    }

    function _isActionPermitted(Policy storage policy, uint8 actionType) internal view returns (bool) {
        for (uint256 i = 0; i < policy.permittedActions.length; i++) {
            if (policy.permittedActions[i] == actionType) return true;
        }
        return false;
    }
}