// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";

contract PolicyRegistryTest is Test {

    PolicyRegistry public registry;

    address public owner   = makeAddr("owner");
    address public agent   = makeAddr("agent");
    address public owner2  = makeAddr("owner2");
    address public agent2  = makeAddr("agent2");
    address public token   = makeAddr("usdc");
    address public gate;
    address public nobody  = makeAddr("nobody");

    uint256 public budget   = 1000e6;
    uint256 public maxTx    = 100e6;
    uint256 public expiry;
    uint8   public riskCeil = 70;
    uint8[] public actions;
    bytes32 public policyId;

    function setUp() public {
        registry = new PolicyRegistry();
        expiry = block.timestamp + 30 days;
        actions = new uint8[](2);
        actions[0] = registry.ACTION_DATA_FEED();
        actions[1] = registry.ACTION_DEX_SWAP();
        // gate is set to address(this) — the test contract itself
        // setSentinelGate is called without a prank so msg.sender
        // is the test contract. We store that same address as gate
        // so vm.prank(gate) and direct calls both work correctly.
        gate = address(this);
        registry.setSentinelGate(gate);
        vm.prank(owner);
        policyId = registry.registerPolicy(agent, token, budget, maxTx, expiry, riskCeil, actions);
    }

    // =========================================================================
    // setSentinelGate
    // =========================================================================

    function test_setSentinelGate_canOnlyBeSetOnce() public {
        PolicyRegistry fresh = new PolicyRegistry();
        fresh.setSentinelGate(gate);
        vm.expectRevert();
        fresh.setSentinelGate(makeAddr("anotherGate"));
    }

    function test_setSentinelGate_revert_zeroAddress() public {
        PolicyRegistry fresh = new PolicyRegistry();
        vm.expectRevert(PolicyRegistry.ZeroAddressNotAllowed.selector);
        fresh.setSentinelGate(address(0));
    }

    function test_setSentinelGate_storesCorrectAddress() public {
        PolicyRegistry fresh = new PolicyRegistry();
        address g = makeAddr("g");
        fresh.setSentinelGate(g);
        assertEq(fresh.sentinelGate(), g);
    }

    // =========================================================================
    // registerPolicy — happy paths
    // =========================================================================

    function test_registerPolicy_returnsNonZeroPolicyId() public view {
        assertTrue(policyId != bytes32(0));
    }

    function test_registerPolicy_storesOwnerCorrectly() public view {
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.owner, owner);
    }

    function test_registerPolicy_storesAgentCorrectly() public view {
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.agent, agent);
    }

    function test_registerPolicy_spentAmountStartsAtZero() public view {
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.spentAmount, 0);
    }

    function test_registerPolicy_storesPolicyAsActive() public view {
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertTrue(p.isActive);
    }

    function test_registerPolicy_bindsAgentToPolicy() public view {
        bytes32 bound = registry.getActivePolicyForAgent(agent);
        assertEq(bound, policyId);
    }

    function test_registerPolicy_recordsUnderOwner() public view {
        bytes32[] memory owned = registry.getPoliciesByOwner(owner);
        assertEq(owned.length, 1);
        assertEq(owned[0], policyId);
    }

    function test_registerPolicy_twoRegistrations_differentIds() public {
        address agent3 = makeAddr("agent3");
        vm.prank(owner);
        bytes32 secondId = registry.registerPolicy(agent3, token, budget, maxTx, expiry, riskCeil, actions);
        assertTrue(policyId != secondId);
    }

    function test_registerPolicy_emitsEvent() public {
        address a = makeAddr("agentForEvent");
        // The policyId is a deterministic hash we cannot predict in the test
        // so we skip checking the first parameter with false as the first arg
        vm.expectEmit(false, true, true, false);
        emit PolicyRegistry.PolicyRegistered(bytes32(0), owner2, a, budget, expiry);
        vm.prank(owner2);
        registry.registerPolicy(a, token, budget, maxTx, expiry, riskCeil, actions);
    }

    // =========================================================================
    // registerPolicy — revert conditions
    // =========================================================================

    function test_registerPolicy_revert_agentZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.ZeroAddressNotAllowed.selector);
        registry.registerPolicy(address(0), token, budget, maxTx, expiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_tokenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.ZeroAddressNotAllowed.selector);
        registry.registerPolicy(agent2, address(0), budget, maxTx, expiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_ownerEqualsAgent() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.AgentCannotOwnItsPolicy.selector);
        registry.registerPolicy(owner, token, budget, maxTx, expiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_zeroBudget() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.BudgetCannotBeZero.selector);
        registry.registerPolicy(agent2, token, 0, maxTx, expiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_riskCeilingTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.RiskCeilingOutOfRange.selector, 101, 100));
        registry.registerPolicy(agent2, token, budget, maxTx, expiry, 101, actions);
    }

    function test_registerPolicy_revert_riskCeilingZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.RiskCeilingOutOfRange.selector, 0, 100));
        registry.registerPolicy(agent2, token, budget, maxTx, expiry, 0, actions);
    }

    function test_registerPolicy_revert_expiryInPast() public {
        uint256 pastExpiry = block.timestamp - 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.ExpiryMustBeInFuture.selector, pastExpiry, block.timestamp));
        registry.registerPolicy(agent2, token, budget, maxTx, pastExpiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_maxTxExceedsBudget() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.MaxTransactionExceedsBudget.selector, budget + 1, budget));
        registry.registerPolicy(agent2, token, budget, budget + 1, expiry, riskCeil, actions);
    }

    function test_registerPolicy_revert_emptyScope() public {
        uint8[] memory empty = new uint8[](0);
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.ScopeCannotBeEmpty.selector);
        registry.registerPolicy(agent2, token, budget, maxTx, expiry, riskCeil, empty);
    }

    function test_registerPolicy_revert_duplicateActionTypes() public {
        uint8[] memory dupes = new uint8[](2);
        dupes[0] = 0;
        dupes[1] = 0;
        vm.prank(owner);
        vm.expectRevert();
        registry.registerPolicy(agent2, token, budget, maxTx, expiry, riskCeil, dupes);
    }

    // =========================================================================
    // consumeBudget — happy paths
    // =========================================================================

    function test_consumeBudget_updatesSpentAmount() public {
        vm.prank(gate);
        registry.consumeBudget(policyId, 50e6, registry.ACTION_DATA_FEED());
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.spentAmount, 50e6);
    }

    function test_consumeBudget_remainingBudgetDecreases() public {
        vm.prank(gate);
        registry.consumeBudget(policyId, 50e6, registry.ACTION_DATA_FEED());
        assertEq(registry.getRemainingBudget(policyId), budget - 50e6);
    }

    function test_consumeBudget_multipleCalls_accumulates() public {
        vm.startPrank(gate);
        registry.consumeBudget(policyId, 30e6, registry.ACTION_DATA_FEED());
        registry.consumeBudget(policyId, 40e6, registry.ACTION_DEX_SWAP());
        vm.stopPrank();
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.spentAmount, 70e6);
    }

    // =========================================================================
    // consumeBudget — revert conditions
    // =========================================================================

    function test_consumeBudget_revert_callerNotGate() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.OnlyOwnerCanDoThis.selector,
                nobody,
                gate
            )
        );
        registry.consumeBudget(policyId, 50e6, dataFeed);
    }

    function test_consumeBudget_revert_exceedsMaxTx() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.TransactionExceedsMaxSize.selector,
                maxTx + 1,
                maxTx
            )
        );
        registry.consumeBudget(policyId, maxTx + 1, dataFeed);
    }

    function test_consumeBudget_revert_exceedsBudget() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        for (uint256 i = 0; i < 10; i++) {
            registry.consumeBudget(policyId, 100e6, dataFeed);
        }
        // Budget fully exhausted — any further spend must fail
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.InsufficientBudget.selector,
                1,
                0
            )
        );
        registry.consumeBudget(policyId, 1, dataFeed);
    }

    function test_consumeBudget_revert_actionNotPermitted() public {
        uint8 lending = registry.ACTION_LENDING();
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.ActionTypeNotPermitted.selector,
                policyId,
                lending
            )
        );
        registry.consumeBudget(policyId, 50e6, lending);
    }

    function test_consumeBudget_revert_policyRevoked() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.prank(owner);
        registry.revokePolicy(policyId);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.PolicyAlreadyRevoked.selector,
                policyId
            )
        );
        registry.consumeBudget(policyId, 50e6, dataFeed);
    }

    function test_consumeBudget_revert_policyExpired() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        vm.warp(expiry + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.PolicyExpired.selector,
                policyId,
                expiry,
                expiry + 1
            )
        );
        registry.consumeBudget(policyId, 50e6, dataFeed);
    }

    // =========================================================================
    // revokePolicy
    // =========================================================================

    function test_revokePolicy_setsIsActiveFalse() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertFalse(p.isActive);
    }

    function test_revokePolicy_clearsAgentBinding() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        assertEq(registry.getActivePolicyForAgent(agent), bytes32(0));
    }

    function test_revokePolicy_revert_callerNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.OnlyOwnerCanDoThis.selector, nobody, owner));
        registry.revokePolicy(policyId);
    }

    function test_revokePolicy_revert_alreadyRevoked() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.PolicyAlreadyRevoked.selector, policyId));
        registry.revokePolicy(policyId);
    }

    // =========================================================================
    // increaseBudget
    // =========================================================================

    function test_increaseBudget_addsToMaxBudget() public {
        vm.prank(owner);
        registry.increaseBudget(policyId, 500e6);
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.maxBudget, budget + 500e6);
    }

    function test_increaseBudget_revert_callerNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.increaseBudget(policyId, 100e6);
    }

    function test_increaseBudget_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.BudgetCannotBeZero.selector);
        registry.increaseBudget(policyId, 0);
    }

    // =========================================================================
    // extendExpiry
    // =========================================================================

    function test_extendExpiry_updatesExpiry() public {
        uint256 newExpiry = expiry + 30 days;
        vm.prank(owner);
        registry.extendExpiry(policyId, newExpiry);
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.expiry, newExpiry);
    }

    function test_extendExpiry_revert_newExpiryEarlier() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.extendExpiry(policyId, expiry - 1 days);
    }

    // =========================================================================
    // updateRiskCeiling
    // =========================================================================

    function test_updateRiskCeiling_updatesValue() public {
        vm.prank(owner);
        registry.updateRiskCeiling(policyId, 50);
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.riskCeiling, 50);
    }

    function test_updateRiskCeiling_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.updateRiskCeiling(policyId, 101);
    }

    // =========================================================================
    // validateAction
    // =========================================================================

    function test_validateAction_trueForValidAction() public view {
        (bool valid, string memory reason) = registry.validateAction(policyId, 50e6, registry.ACTION_DATA_FEED());
        assertTrue(valid);
        assertEq(reason, "");
    }

    function test_validateAction_falseForRevokedPolicy() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        (bool valid,) = registry.validateAction(policyId, 50e6, registry.ACTION_DATA_FEED());
        assertFalse(valid);
    }

    function test_validateAction_falseForExpiredPolicy() public {
        vm.warp(expiry + 1);
        (bool valid,) = registry.validateAction(policyId, 50e6, registry.ACTION_DATA_FEED());
        assertFalse(valid);
    }

    function test_validateAction_falseForUnpermittedAction() public view {
        (bool valid,) = registry.validateAction(policyId, 50e6, registry.ACTION_LENDING());
        assertFalse(valid);
    }

    // =========================================================================
    // Core invariants
    // =========================================================================

    function test_invariant_spentNeverExceedsBudget() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        for (uint256 i = 0; i < 10; i++) {
            registry.consumeBudget(policyId, 100e6, dataFeed);
        }
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertLe(p.spentAmount, p.maxBudget, "INVARIANT BROKEN: spent exceeded budget");
        vm.expectRevert();
        registry.consumeBudget(policyId, 1, dataFeed);
    }

    function test_invariant_agentCannotModifyOwnPolicy() public {
        vm.startPrank(agent);
        vm.expectRevert(); registry.revokePolicy(policyId);
        vm.expectRevert(); registry.increaseBudget(policyId, 1000e6);
        vm.expectRevert(); registry.extendExpiry(policyId, expiry + 1 days);
        vm.expectRevert(); registry.updateRiskCeiling(policyId, 90);
        vm.stopPrank();
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertEq(p.maxBudget, budget);
        assertTrue(p.isActive);
    }

    function test_invariant_revokedPolicyCannotBeReactivated() public {
        vm.prank(owner);
        registry.revokePolicy(policyId);
        vm.prank(gate);
        vm.expectRevert();
        registry.consumeBudget(policyId, 1, 0);
        vm.prank(owner);
        vm.expectRevert();
        registry.increaseBudget(policyId, 100e6);
        assertFalse(registry.isPolicyActive(policyId), "INVARIANT BROKEN: revoked policy became active");
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_consumeBudget_neverExceedsBudget(uint256 spend1, uint256 spend2) public {
        spend1 = bound(spend1, 1, maxTx);
        spend2 = bound(spend2, 1, maxTx);
        uint8 dataFeed = registry.ACTION_DATA_FEED();
        uint8 dexSwap  = registry.ACTION_DEX_SWAP();
        registry.consumeBudget(policyId, spend1, dataFeed);
        PolicyRegistry.Policy memory p = registry.getPolicy(policyId);
        assertLe(p.spentAmount, p.maxBudget);
        uint256 remaining = p.maxBudget - p.spentAmount;
        if (spend2 <= remaining && spend2 <= maxTx) {
            registry.consumeBudget(policyId, spend2, dexSwap);
            PolicyRegistry.Policy memory p2 = registry.getPolicy(policyId);
            assertLe(p2.spentAmount, p2.maxBudget);
        }
    }

    function testFuzz_registerPolicy_validInputs(
        uint256 fuzzBudget,
        uint8 fuzzCeiling,
        uint256 fuzzExpiry
    ) public {
        fuzzBudget  = bound(fuzzBudget, 1e6, 1_000_000e6);
        fuzzCeiling = uint8(bound(uint256(fuzzCeiling), 1, 100));
        fuzzExpiry  = bound(fuzzExpiry, block.timestamp + 1, block.timestamp + 365 days);
        uint8[] memory a = new uint8[](1);
        a[0] = 0;
        address freshAgent = makeAddr(string(abi.encodePacked("fuzzAgent", fuzzBudget)));
        vm.prank(owner2);
        bytes32 fuzzPid = registry.registerPolicy(freshAgent, token, fuzzBudget, fuzzBudget, fuzzExpiry, fuzzCeiling, a);
        assertTrue(fuzzPid != bytes32(0));
        assertTrue(registry.isPolicyActive(fuzzPid));
    }
}