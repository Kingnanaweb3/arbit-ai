// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {ActivityLog} from "../src/ActivityLog.sol";
import {SentinelGate} from "../src/SentinelGate.sol";
import {ReputationStaking} from "../src/ReputationStaking.sol";
import {RiskGuardian} from "../src/RiskGuardian.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockRiskGuardian {
    uint8 public score = 30;
    function setScore(uint8 _score) external { score = _score; }
    function getScore(bytes32, address) external view returns (uint8) { return score; }
}

// A malicious contract that tries to reenter SentinelGate during executePayment
contract ReentrancyAttacker {
    SentinelGate public gate;
    bytes32      public policyId;
    address      public recipient;
    uint8        public actionType;
    bool         public attackArmed;

    constructor(address _gate) {
        gate = SentinelGate(_gate);
    }

    function arm(bytes32 _policyId, address _recipient, uint8 _actionType) external {
        policyId   = _policyId;
        recipient  = _recipient;
        actionType = _actionType;
        attackArmed = true;
    }

    // Called when this contract receives tokens — tries to reenter
    function onERC20Received() external {
        if (attackArmed) {
            attackArmed = false;
            gate.executePayment(policyId, recipient, 1, actionType, address(0));
        }
    }
}

// A malicious agent that tries to modify its own policy
contract MaliciousAgent {
    PolicyRegistry public registry;

    constructor(address _registry) {
        registry = PolicyRegistry(_registry);
    }

    function tryRevokeOwnPolicy(bytes32 policyId) external {
        registry.revokePolicy(policyId);
    }

    function tryIncreaseBudget(bytes32 policyId, uint256 amount) external {
        registry.increaseBudget(policyId, amount);
    }

    function tryExtendExpiry(bytes32 policyId, uint256 newExpiry) external {
        registry.extendExpiry(policyId, newExpiry);
    }

    function tryUpdateRiskCeiling(bytes32 policyId, uint8 newCeiling) external {
        registry.updateRiskCeiling(policyId, newCeiling);
    }
}

// A malicious contract that tries to write to ActivityLog directly
contract MaliciousWriter {
    ActivityLog public actLog;

    constructor(address _actLog) {
        actLog = ActivityLog(_actLog);
    }

    function tryWriteEntry(bytes32 policyId, address agent) external {
        actLog.writeEntry(policyId, agent, 0, 100e6, 30, bytes32(0));
    }

    function trySetWriter(address newWriter) external {
        actLog.setWriter(newWriter);
    }
}

// A malicious staker that tries to slash without authority
contract MaliciousSlasher {
    ReputationStaking public staking;

    constructor(address _staking) {
        staking = ReputationStaking(_staking);
    }

    function trySlash(address agent, address buyer, uint256 amount) external {
        staking.slashStake(agent, buyer, amount, "Unauthorized slash");
    }

    function tryRecordCall(address agent) external {
        staking.recordCall(agent, false);
    }
}

contract ArbitBreachAttemptsTest is Test {

    PolicyRegistry   public registry;
    ActivityLog      public actLog;
    SentinelGate     public gate;
    ReputationStaking public staking;
    MockUSDC         public usdc;
    MockRiskGuardian public guardian;

    address public admin     = address(this);
    address public owner     = makeAddr("owner");
    address public agent     = makeAddr("agent");
    address public recipient = makeAddr("recipient");
    address public attacker  = makeAddr("attacker");
    address public treasury  = makeAddr("treasury");

    bytes32 public policyId;
    uint8[] public actions;
    uint256 public expiry;
    uint256 public budget  = 1000e6;
    uint256 public maxTx   = 200e6;

    function setUp() public {
        vm.warp(365 days);
        expiry = block.timestamp + 30 days;

        registry = new PolicyRegistry();
        actLog   = new ActivityLog();
        usdc     = new MockUSDC();
        guardian = new MockRiskGuardian();

        gate = new SentinelGate(
            address(registry),
            address(actLog),
            address(guardian),
            admin
        );
        gate.completeSetup();

        staking = new ReputationStaking(address(usdc));
        staking.setSlashAuthority(admin);
        staking.setTreasury(treasury);

        actions = new uint8[](2);
        actions[0] = registry.ACTION_DATA_FEED();
        actions[1] = registry.ACTION_DEX_SWAP();

        vm.prank(owner);
        policyId = registry.registerPolicy(
            agent, address(usdc), budget, maxTx, expiry, 70, actions
        );

        usdc.mint(agent, budget * 10);
        vm.prank(agent);
        usdc.approve(address(gate), type(uint256).max);
    }

    // =========================================================================
    // ATTACK 1 — Agent tries to rewrite its own policy
    // =========================================================================

    function test_breach_agentCannotRevokeOwnPolicy() public {
        MaliciousAgent mal = new MaliciousAgent(address(registry));

        // Register a policy where mal is the agent
        vm.prank(owner);
        bytes32 malPolicyId = registry.registerPolicy(
            address(mal), address(usdc), budget, maxTx, expiry, 70, actions
        );

        // The malicious agent tries to revoke its own policy
        vm.expectRevert();
        mal.tryRevokeOwnPolicy(malPolicyId);

        // Policy must still be active
        assertTrue(
            registry.isPolicyActive(malPolicyId),
            "BREACH: agent revoked its own policy"
        );
    }

    function test_breach_agentCannotIncreaseBudget() public {
        MaliciousAgent mal = new MaliciousAgent(address(registry));

        vm.prank(owner);
        bytes32 malPolicyId = registry.registerPolicy(
            address(mal), address(usdc), budget, maxTx, expiry, 70, actions
        );

        uint256 budgetBefore = registry.getPolicy(malPolicyId).maxBudget;

        vm.expectRevert();
        mal.tryIncreaseBudget(malPolicyId, 1_000_000e6);

        assertEq(
            registry.getPolicy(malPolicyId).maxBudget,
            budgetBefore,
            "BREACH: agent increased its own budget"
        );
    }

    function test_breach_agentCannotExtendExpiry() public {
        MaliciousAgent mal = new MaliciousAgent(address(registry));

        vm.prank(owner);
        bytes32 malPolicyId = registry.registerPolicy(
            address(mal), address(usdc), budget, maxTx, expiry, 70, actions
        );

        uint256 expiryBefore = registry.getPolicy(malPolicyId).expiry;

        vm.expectRevert();
        mal.tryExtendExpiry(malPolicyId, expiry + 365 days);

        assertEq(
            registry.getPolicy(malPolicyId).expiry,
            expiryBefore,
            "BREACH: agent extended its own expiry"
        );
    }

    function test_breach_agentCannotLowerRiskCeiling() public {
        MaliciousAgent mal = new MaliciousAgent(address(registry));

        vm.prank(owner);
        bytes32 malPolicyId = registry.registerPolicy(
            address(mal), address(usdc), budget, maxTx, expiry, 70, actions
        );

        vm.expectRevert();
        mal.tryUpdateRiskCeiling(malPolicyId, 100); // try to raise ceiling to bypass risk

        assertEq(
            registry.getPolicy(malPolicyId).riskCeiling,
            70,
            "BREACH: agent changed its own risk ceiling"
        );
    }

    // =========================================================================
    // ATTACK 2 — Third party tries to write to ActivityLog directly
    // =========================================================================

    function test_breach_unauthorisedWriterCannotWriteEntry() public {
        MaliciousWriter mal = new MaliciousWriter(address(actLog));

        vm.expectRevert();
        mal.tryWriteEntry(policyId, agent);

        assertEq(
            actLog.entryCount(),
            0,
            "BREACH: unauthorised writer wrote to ActivityLog"
        );
    }

    function test_breach_cannotOverwriteWriter() public {
        MaliciousWriter mal = new MaliciousWriter(address(actLog));

        // Writer is already set to gate — trying to set again must fail
        vm.expectRevert();
        mal.trySetWriter(address(mal));

        assertEq(
            actLog.writer(),
            address(gate),
            "BREACH: writer address was overwritten"
        );
    }

    function test_breach_attackerCannotWriteDirectly() public {
        vm.prank(attacker);
        vm.expectRevert();
        actLog.writeEntry(policyId, agent, 0, 100e6, 30, bytes32(0));

        assertEq(actLog.entryCount(), 0, "BREACH: attacker wrote to ActivityLog");
    }

    // =========================================================================
    // ATTACK 3 — Budget overflow attempts
    // =========================================================================

    function test_breach_cannotSpendMoreThanBudget() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Spend the entire budget legitimately
        vm.startPrank(agent);
        for (uint256 i = 0; i < 5; i++) {
            gate.executePayment(policyId, recipient, 200e6, dataFeed, address(0));
        }

        // Now try to spend one more wei — must fail
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 1, dataFeed, address(0));
        vm.stopPrank();

        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertLe(p.spentAmount, p.maxBudget, "BREACH: spent exceeded budget");
        assertEq(p.spentAmount, budget, "Budget should be exactly exhausted");
    }

    function test_breach_cannotExceedMaxTransactionSize() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, maxTx + 1, dataFeed, address(0));

        assertEq(
            registry.getRemainingBudget(policyId),
            budget,
            "BREACH: oversized transaction went through"
        );
    }

    function test_breach_cannotPayForbiddenActionType() public {
        uint8 lending = registry.ACTION_LENDING();

        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, lending, address(0));

        assertEq(
            registry.getRemainingBudget(policyId),
            budget,
            "BREACH: forbidden action type executed"
        );
    }

    // =========================================================================
    // ATTACK 4 — Risk ceiling bypass
    // =========================================================================

    function test_breach_cannotPayWhenRiskTooHigh() public {
        guardian.setScore(100); // Maximum risk
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        uint256 balanceBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));

        assertEq(
            usdc.balanceOf(agent),
            balanceBefore,
            "BREACH: payment went through despite maximum risk score"
        );
    }

    function test_breach_riskBlockCannotBeBypassedByNobody() public {
        guardian.setScore(85);
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Nobody can call executePayment on behalf of the agent
        vm.prank(nobody());
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_breach_revokedPolicyCannotExecutePayment() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);

        uint8 dataFeed = registry.ACTION_DATA_FEED();
        uint256 balanceBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));

        assertEq(
            usdc.balanceOf(agent),
            balanceBefore,
            "BREACH: revoked policy executed a payment"
        );
    }

    function test_breach_expiredPolicyCannotExecutePayment() public {
        vm.warp(expiry + 1);
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    // =========================================================================
    // ATTACK 5 — Unauthorised slash attempts
    // =========================================================================

    function test_breach_unauthorisedSlash() public {
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(agent);
        staking.listService(100e6, 10e6, 0, keccak256("service"));

        MaliciousSlasher mal = new MaliciousSlasher(address(staking));

        vm.expectRevert();
        mal.trySlash(agent, attacker, 100e6);

        assertEq(
            staking.getListing(agent).stakedAmount,
            100e6,
            "BREACH: unauthorised slash succeeded"
        );
    }

    function test_breach_unauthorisedCallRecord() public {
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(agent);
        staking.listService(100e6, 10e6, 0, keccak256("service"));

        MaliciousSlasher mal = new MaliciousSlasher(address(staking));

        vm.expectRevert();
        mal.tryRecordCall(agent);

        assertEq(
            staking.getListing(agent).failedCalls,
            0,
            "BREACH: unauthorised call record succeeded"
        );
    }

    // =========================================================================
    // ATTACK 6 — Gate setup manipulation
    // =========================================================================

    function test_breach_cannotCallSetupTwice() public {
        vm.expectRevert(SentinelGate.SetupAlreadyComplete.selector);
        gate.completeSetup();
    }

    function test_breach_cannotSetGateTwice() public {
        // setSentinelGate is already called by completeSetup
        // Trying to call it again must fail
        vm.expectRevert();
        registry.setSentinelGate(attacker);
    }

    function test_breach_nonAdminCannotUpdateRiskGuardian() public {
        vm.prank(attacker);
        vm.expectRevert();
        gate.updateRiskGuardian(attacker);

        // Risk guardian must be unchanged
        assertEq(
            address(gate.riskGuardian()),
            address(guardian),
            "BREACH: attacker changed the risk guardian"
        );
    }

    function test_breach_nonAdminCannotTransferGateAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gate.transferAdmin(attacker);

        assertEq(
            gate.admin(),
            admin,
            "BREACH: attacker transferred gate admin"
        );
    }

    // =========================================================================
    // ATTACK 7 — PolicyRegistry gate manipulation
    // =========================================================================

    function test_breach_randomAddressCannotConsumeBudget() public {
        vm.prank(attacker);
        vm.expectRevert();
        registry.consumeBudget(policyId, 100e6, 0);

        assertEq(
            registry.getRemainingBudget(policyId),
            budget,
            "BREACH: random address consumed budget"
        );
    }

    function test_breach_cannotRegisterAgentAsOwnOwner() public {
        // The owner cannot register themselves as the agent
        // This would let them control their own policy rules
        vm.prank(agent);
        vm.expectRevert();
        registry.registerPolicy(
            agent, address(usdc), budget, maxTx, expiry, 70, actions
        );
    }

    function test_breach_anotherOwnerCannotRevokeYourPolicy() public {
        address otherOwner = makeAddr("otherOwner");
        vm.prank(otherOwner);
        vm.expectRevert();
        registry.revokePolicy(policyId);

        assertTrue(
            registry.isPolicyActive(policyId),
            "BREACH: another owner revoked your policy"
        );
    }

    // =========================================================================
    // ATTACK 8 — Staking manipulation
    // =========================================================================

    function test_breach_cannotListWithoutMinimumStake() public {
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);

        vm.prank(agent);
        vm.expectRevert();
        staking.listService(50e6, 10e6, 0, keccak256("service")); // below 100 USDC minimum
    }

    function test_breach_cannotDelistWhileSuspended() public {
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(agent);
        staking.listService(100e6, 10e6, 0, keccak256("service"));

        // Admin slashes — suspends the agent
        staking.slashStake(agent, attacker, 50e6, "Malicious behaviour");

        // Suspended agent tries to delist and recover remaining stake
        vm.prank(agent);
        vm.expectRevert();
        staking.delistService();

        // Remaining stake must still be in the contract
        assertEq(
            staking.getListing(agent).stakedAmount,
            50e6,
            "BREACH: suspended agent delisted and recovered stake"
        );
    }

    function test_breach_slashCannotDrainMoreThanStaked() public {
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(agent);
        staking.listService(100e6, 10e6, 0, keccak256("service"));

        uint256 contractBalanceBefore = usdc.balanceOf(address(staking));

        // Attempt to slash 10x the staked amount
        staking.slashStake(agent, attacker, 1_000_000e6, "Massive slash attempt");

        uint256 contractBalanceAfter = usdc.balanceOf(address(staking));

        assertEq(
            contractBalanceAfter,
            0,
            "Contract should be empty after full slash"
        );

        assertLe(
            contractBalanceBefore - contractBalanceAfter,
            100e6,
            "BREACH: slash drained more than was staked"
        );
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function nobody() internal pure returns (address) {
        return address(0xdead);
    }
}
