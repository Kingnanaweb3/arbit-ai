// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SentinelGate} from "../src/SentinelGate.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {ActivityLog} from "../src/ActivityLog.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// A minimal ERC20 we mint freely in tests
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// A mock RiskGuardian we can control in tests
contract MockRiskGuardian {
    uint8 public score = 30;

    function setScore(uint8 _score) external {
        score = _score;
    }

    function getScore(bytes32, address) external view returns (uint8) {
        return score;
    }
}

contract SentinelGateTest is Test {

    SentinelGate      public gate;
    PolicyRegistry    public registry;
    ActivityLog       public actLog;
    MockUSDC          public usdc;
    MockRiskGuardian  public guardian;

    address public admin   = address(this);
    address public owner   = makeAddr("owner");
    address public agent   = makeAddr("agent");
    address public agent2  = makeAddr("agent2");
    address public recipient = makeAddr("recipient");
    address public nobody  = makeAddr("nobody");

    uint256 public budget  = 1000e6;
    uint256 public maxTx   = 200e6;
    uint256 public expiry;
    uint8   public riskCeil = 70;
    bytes32 public policyId;
    uint8[] public actions;

    function setUp() public {
        expiry = block.timestamp + 30 days;

        // Deploy all contracts
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

        // Complete setup — registers gate with registry and actLog
        gate.completeSetup();

        // Register a policy
        actions = new uint8[](2);
        actions[0] = registry.ACTION_DATA_FEED();
        actions[1] = registry.ACTION_DEX_SWAP();

        vm.prank(owner);
        policyId = registry.registerPolicy(
            agent,
            address(usdc),
            budget,
            maxTx,
            expiry,
            riskCeil,
            actions
        );

        // Fund the agent and approve the gate to spend
        usdc.mint(agent, budget);
        vm.prank(agent);
        usdc.approve(address(gate), type(uint256).max);
    }

    // =========================================================================
    // completeSetup
    // =========================================================================

    function test_completeSetup_setsSetupComplete() public view {
        assertTrue(gate.setupComplete());
    }

    function test_completeSetup_registersGateWithRegistry() public view {
        assertEq(registry.sentinelGate(), address(gate));
    }

    function test_completeSetup_registersGateWithActivityLog() public view {
        assertEq(actLog.writer(), address(gate));
    }

    function test_completeSetup_revert_callerNotAdmin() public {
        SentinelGate fresh = new SentinelGate(
            address(registry),
            address(actLog),
            address(guardian),
            admin
        );
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                SentinelGate.OnlyAdminCanDoThis.selector,
                nobody,
                admin
            )
        );
        fresh.completeSetup();
    }

    function test_completeSetup_revert_calledTwice() public {
        vm.expectRevert(SentinelGate.SetupAlreadyComplete.selector);
        gate.completeSetup();
    }

    // =========================================================================
    // executePayment — happy paths
    // =========================================================================

    function test_executePayment_transfersTokens() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_executePayment_deductsFromAgentBalance() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(usdc.balanceOf(agent), budget - 100e6);
    }

    function test_executePayment_consumesBudgetInRegistry() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(registry.getRemainingBudget(policyId), budget - 100e6);
    }

    function test_executePayment_writesActivityLogEntry() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(actLog.entryCount(), 1);
    }

    function test_executePayment_returnsEntryIndex() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        uint256 idx = gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(idx, 0);
    }

    function test_executePayment_multiplePayments_allLogged() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.startPrank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        gate.executePayment(policyId, recipient, 50e6,  dataFeed, address(0));
        vm.stopPrank();
        assertEq(actLog.entryCount(), 2);
    }

    function test_executePayment_emitsPaymentExecutedEvent() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.expectEmit(true, true, true, false);
        emit SentinelGate.PaymentExecuted(policyId, agent, recipient, 100e6, 30, 0);
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_executePayment_belowRiskCeiling_succeeds() public {
        // Risk score 30 is well below ceiling of 70
        guardian.setScore(30);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_executePayment_exactlyAtRiskCeiling_succeeds() public {
        // Score equal to ceiling should pass — we block only when strictly greater
        guardian.setScore(70);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    // =========================================================================
    // executePayment — revert conditions
    // =========================================================================

    function test_executePayment_revert_setupNotComplete() public {
        SentinelGate ungated = new SentinelGate(
            address(new PolicyRegistry()),
            address(new ActivityLog()),
            address(guardian),
            admin
        );
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert(SentinelGate.SetupNotComplete.selector);
        ungated.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_executePayment_revert_recipientZeroAddress() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert(SentinelGate.RecipientCannotBeZero.selector);
        gate.executePayment(policyId, address(0), 100e6, dataFeed, address(0));
    }

    function test_executePayment_revert_amountZero() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert(SentinelGate.AmountCannotBeZero.selector);
        gate.executePayment(policyId, recipient, 0, dataFeed, address(0));
    }

    function test_executePayment_revert_callerNotAgent() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                SentinelGate.OnlyAgentCanExecute.selector,
                nobody,
                agent
            )
        );
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_executePayment_revert_riskCeilingBreached() public {
        guardian.setScore(85);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                SentinelGate.RiskCeilingBreached.selector,
                policyId,
                uint8(85),
                riskCeil
            )
        );
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_executePayment_revert_riskBlock_emitsBlockedEvent() public {
        guardian.setScore(85);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        // Blocked payments emit a PaymentBlocked event before reverting
        // The log entry itself is rolled back with the transaction —
        // the event is the permanent off-chain record of the block
        vm.expectEmit(true, true, false, false);
        emit SentinelGate.PaymentBlocked(policyId, agent, 100e6, 85, "Risk ceiling breached");
        vm.prank(agent);
        try gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0)) {}
        catch {}
    }

    function test_executePayment_revert_riskBlock_noTokensMoved() public {
        guardian.setScore(85);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        uint256 balanceBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        try gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0)) {}
        catch {}
        assertEq(usdc.balanceOf(agent), balanceBefore);
    }

    function test_executePayment_revert_policyExpired() public {
        vm.warp(expiry + 1);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    function test_executePayment_revert_budgetExhausted() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.startPrank(agent);
        for (uint256 i = 0; i < 5; i++) {
            gate.executePayment(policyId, recipient, 200e6, dataFeed, address(0));
        }
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 1, dataFeed, address(0));
        vm.stopPrank();
    }

    function test_executePayment_revert_actionNotPermitted() public {
        uint8 lending = registry.ACTION_LENDING();
        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, lending, address(0));
    }

    function test_executePayment_revert_policyRevoked() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        vm.expectRevert();
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
    }

    // =========================================================================
    // updateRiskGuardian
    // =========================================================================

    function test_updateRiskGuardian_updatesAddress() public {
        address newGuardian = makeAddr("newGuardian");
        gate.updateRiskGuardian(newGuardian);
        assertEq(address(gate.riskGuardian()), newGuardian);
    }

    function test_updateRiskGuardian_emitsEvent() public {
        address newGuardian = makeAddr("newGuardian");
        vm.expectEmit(true, true, false, false);
        emit SentinelGate.RiskGuardianUpdated(address(guardian), newGuardian);
        gate.updateRiskGuardian(newGuardian);
    }

    function test_updateRiskGuardian_revert_callerNotAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                SentinelGate.OnlyAdminCanDoThis.selector,
                nobody,
                admin
            )
        );
        gate.updateRiskGuardian(makeAddr("newGuardian"));
    }

    function test_updateRiskGuardian_revert_zeroAddress() public {
        vm.expectRevert(SentinelGate.ZeroAddressNotAllowed.selector);
        gate.updateRiskGuardian(address(0));
    }

    // =========================================================================
    // transferAdmin
    // =========================================================================

    function test_transferAdmin_updatesAdmin() public {
        gate.transferAdmin(nobody);
        assertEq(gate.admin(), nobody);
    }

    function test_transferAdmin_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SentinelGate.AdminTransferred(admin, nobody);
        gate.transferAdmin(nobody);
    }

    function test_transferAdmin_revert_callerNotAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                SentinelGate.OnlyAdminCanDoThis.selector,
                nobody,
                admin
            )
        );
        gate.transferAdmin(makeAddr("newAdmin"));
    }

    function test_transferAdmin_revert_zeroAddress() public {
        vm.expectRevert(SentinelGate.ZeroAddressNotAllowed.selector);
        gate.transferAdmin(address(0));
    }

    // =========================================================================
    // Core invariants
    // =========================================================================

    function test_invariant_noTokensMovedOnRiskBlock() public {
        guardian.setScore(99);
        uint256 agentBefore     = usdc.balanceOf(agent);
        uint256 recipientBefore = usdc.balanceOf(recipient);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        try gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0)) {}
        catch {}
        assertEq(usdc.balanceOf(agent),     agentBefore,     "INVARIANT: agent balance changed on risk block");
        assertEq(usdc.balanceOf(recipient), recipientBefore, "INVARIANT: recipient received tokens on risk block");
    }

    function test_invariant_budgetNeverExceededViaGate() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.startPrank(agent);
        for (uint256 i = 0; i < 5; i++) {
            gate.executePayment(policyId, recipient, 200e6, dataFeed, address(0));
        }
        vm.stopPrank();
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertLe(p.spentAmount, p.maxBudget, "INVARIANT: spent exceeded budget");
    }

    function test_invariant_everyPaymentLogged() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.startPrank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        gate.executePayment(policyId, recipient, 50e6,  dataFeed, address(0));
        gate.executePayment(policyId, recipient, 75e6,  dataFeed, address(0));
        vm.stopPrank();
        assertEq(actLog.entryCount(), 3, "INVARIANT: not every payment was logged");
    }

    function test_invariant_chainIntactAfterPayments() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.startPrank(agent);
        gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0));
        gate.executePayment(policyId, recipient, 50e6,  dataFeed, address(0));
        vm.stopPrank();
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact, "INVARIANT: activity log chain broken after payments");
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_executePayment_neverExceedsBudget(uint256 amount) public {
        amount = bound(amount, 1e6, maxTx);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        gate.executePayment(policyId, recipient, amount, dataFeed, address(0));
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertLe(p.spentAmount, p.maxBudget);
    }

    function testFuzz_executePayment_riskBlock_neverMovesTokens(uint8 riskScore) public {
        riskScore = uint8(bound(uint256(riskScore), 71, 100));
        guardian.setScore(riskScore);
        uint256 balanceBefore = usdc.balanceOf(agent);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(agent);
        try gate.executePayment(policyId, recipient, 100e6, dataFeed, address(0)) {}
        catch {}
        assertEq(usdc.balanceOf(agent), balanceBefore, "Fuzz: tokens moved despite risk block");
    }
}
