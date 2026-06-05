// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActivityLog} from "../src/ActivityLog.sol";

contract ActivityLogTest is Test {

    ActivityLog public actLog;

    address public agent   = makeAddr("agent");
    address public agent2  = makeAddr("agent2");
    address public nobody  = makeAddr("nobody");

    bytes32 public policyId  = keccak256("policy1");
    bytes32 public policyId2 = keccak256("policy2");
    bytes32 public reason    = keccak256("risk ceiling breached");

    // The test contract itself is the writer — same pattern as PolicyRegistry
    function setUp() public {
        actLog = new ActivityLog();
        actLog.setWriter(address(this));
    }

    // =========================================================================
    // setWriter
    // =========================================================================

    function test_setWriter_storesCorrectAddress() public view {
        assertEq(actLog.writer(), address(this));
    }

    function test_setWriter_canOnlyBeSetOnce() public {
        ActivityLog fresh = new ActivityLog();
        fresh.setWriter(address(this));
        vm.expectRevert(ActivityLog.WriterAlreadySet.selector);
        fresh.setWriter(nobody);
    }

    function test_setWriter_revert_zeroAddress() public {
        ActivityLog fresh = new ActivityLog();
        vm.expectRevert(ActivityLog.ZeroAddressNotAllowed.selector);
        fresh.setWriter(address(0));
    }

    function test_setWriter_emitsEvent() public {
        ActivityLog fresh = new ActivityLog();
        vm.expectEmit(true, false, false, false);
        emit ActivityLog.WriterAuthorised(address(this));
        fresh.setWriter(address(this));
    }

    // =========================================================================
    // writeEntry — happy paths
    // =========================================================================

    function test_writeEntry_incrementsEntryCount() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        assertEq(actLog.entryCount(), 1);
    }

    function test_writeEntry_secondEntry_countIsTwo() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        assertEq(actLog.entryCount(), 2);
    }

    function test_writeEntry_storesFieldsCorrectly() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 42, bytes32(0));
        ActivityLog.LogEntry memory e = actLog.getEntry(0);
        assertEq(e.policyId,        policyId);
        assertEq(e.agent,           agent);
        assertEq(e.actionType,      actLog.ACTION_DATA_FEED());
        assertEq(e.amount,          50e6);
        assertEq(e.riskScoreAtTime, 42);
        assertEq(e.timestamp,       block.timestamp);
    }

    function test_writeEntry_firstEntry_previousHashIsZero() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        ActivityLog.LogEntry memory e = actLog.getEntry(0);
        assertEq(e.previousEntryHash, bytes32(0));
    }

    function test_writeEntry_secondEntry_previousHashMatchesFirst() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        bytes32 firstHash = actLog.latestHash();
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        ActivityLog.LogEntry memory second = actLog.getEntry(1);
        assertEq(second.previousEntryHash, firstHash);
    }

    function test_writeEntry_updatesLatestHash() public {
        assertEq(actLog.latestHash(), bytes32(0));
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        assertTrue(actLog.latestHash() != bytes32(0));
    }

    function test_writeEntry_twoEntries_differentHashes() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        bytes32 hash1 = actLog.latestHash();
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        bytes32 hash2 = actLog.latestHash();
        assertTrue(hash1 != hash2);
    }

    function test_writeEntry_indexedUnderPolicy() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        uint256[] memory indices = actLog.getEntriesForPolicy(policyId);
        assertEq(indices.length, 2);
        assertEq(indices[0], 0);
        assertEq(indices[1], 1);
    }

    function test_writeEntry_indexedUnderAgent() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId2, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        uint256[] memory indices = actLog.getEntriesForAgent(agent);
        assertEq(indices.length, 2);
    }

    function test_writeEntry_differentAgents_separateIndices() public {
        actLog.writeEntry(policyId,  agent,  actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId2, agent2, actLog.ACTION_DEX_SWAP(),  30e6, 35, bytes32(0));
        assertEq(actLog.getEntriesForAgent(agent).length,  1);
        assertEq(actLog.getEntriesForAgent(agent2).length, 1);
    }

    function test_writeEntry_blockedPayment_withReason() public {
        actLog.writeEntry(policyId, agent, actLog.LOG_PAYMENT_BLOCKED(), 50e6, 85, reason);
        ActivityLog.LogEntry memory e = actLog.getEntry(0);
        assertEq(e.reason,     reason);
        assertEq(e.actionType, actLog.LOG_PAYMENT_BLOCKED());
    }

    function test_writeEntry_returnsCorrectIndex() public {
        (uint256 idx,) = actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        assertEq(idx, 0);
        (uint256 idx2,) = actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        assertEq(idx2, 1);
    }

    function test_writeEntry_returnsNonZeroHash() public {
        (, bytes32 hash) = actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        assertTrue(hash != bytes32(0));
    }

    function test_writeEntry_emitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit ActivityLog.EntryWritten(0, policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, bytes32(0));
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
    }

    // =========================================================================
    // writeEntry — revert conditions
    // =========================================================================

    function test_writeEntry_revert_callerNotWriter() public {
        uint8 dataFeed = actLog.ACTION_DATA_FEED();
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                ActivityLog.OnlyWriterCanDoThis.selector,
                nobody,
                address(this)
            )
        );
        actLog.writeEntry(policyId, agent, dataFeed, 50e6, 40, bytes32(0));
    }

    function test_writeEntry_revert_agentZeroAddress() public {
        uint8 dataFeed = actLog.ACTION_DATA_FEED();
        vm.expectRevert(ActivityLog.ZeroAddressNotAllowed.selector);
        actLog.writeEntry(policyId, address(0), dataFeed, 50e6, 40, bytes32(0));
    }

    function test_writeEntry_revert_blockedEntryWithNoReason() public {
        uint8 blocked = actLog.LOG_PAYMENT_BLOCKED();
        vm.expectRevert(ActivityLog.EmptyReasonNotAllowed.selector);
        actLog.writeEntry(policyId, agent, blocked, 50e6, 85, bytes32(0));
    }

    // =========================================================================
    // getEntry
    // =========================================================================

    function test_getEntry_revert_indexOutOfBounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ActivityLog.EntryDoesNotExist.selector,
                0,
                0
            )
        );
        actLog.getEntry(0);
    }

    function test_getEntry_revert_indexBeyondCount() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ActivityLog.EntryDoesNotExist.selector,
                1,
                1
            )
        );
        actLog.getEntry(1);
    }

    // =========================================================================
    // verifyChain
    // =========================================================================

    function test_verifyChain_emptyLog_returnsTrue() public view {
        (bool intact,) = actLog.verifyChain(0);
        // Empty log is trivially intact — nothing to verify
        assertTrue(intact);
    }

    function test_verifyChain_singleEntry_intact() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact);
    }

    function test_verifyChain_multipleEntries_intact() public {
        actLog.writeEntry(policyId,  agent,  actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId,  agent,  actLog.ACTION_DEX_SWAP(),  30e6, 35, bytes32(0));
        actLog.writeEntry(policyId2, agent2, actLog.ACTION_LENDING(),   20e6, 50, bytes32(0));
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact);
    }

    function test_verifyChain_revert_startIndexOutOfBounds() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ActivityLog.EntryDoesNotExist.selector,
                5,
                1
            )
        );
        actLog.verifyChain(5);
    }

    // =========================================================================
    // getRecentEntries
    // =========================================================================

    function test_getRecentEntries_emptyLog_returnsEmpty() public view {
        ActivityLog.LogEntry[] memory recent = actLog.getRecentEntries(5);
        assertEq(recent.length, 0);
    }

    function test_getRecentEntries_fewerEntriesThanRequested() public {
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(),  30e6, 35, bytes32(0));
        ActivityLog.LogEntry[] memory recent = actLog.getRecentEntries(10);
        assertEq(recent.length, 2);
    }

    function test_getRecentEntries_returnsLastN() public {
        for (uint256 i = 0; i < 5; i++) {
            actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        }
        ActivityLog.LogEntry[] memory recent = actLog.getRecentEntries(3);
        assertEq(recent.length, 3);
        // The last entry returned should be the most recent one
        assertEq(recent[2].entryHash, actLog.latestHash());
    }

    // =========================================================================
    // Core invariants
    // =========================================================================

    function test_invariant_entryCountOnlyIncreases() public {
        uint256 before = actLog.entryCount();
        actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 50e6, 40, bytes32(0));
        assertGt(actLog.entryCount(), before);
        actLog.writeEntry(policyId, agent, actLog.ACTION_DEX_SWAP(), 30e6, 35, bytes32(0));
        assertEq(actLog.entryCount(), 2);
    }

    function test_invariant_chainIntactAfterManyWrites() public {
        for (uint256 i = 0; i < 20; i++) {
            actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 10e6, 40, bytes32(0));
        }
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact, "INVARIANT BROKEN: chain not intact after 20 writes");
    }

    function test_invariant_writerCannotBeChanged() public {
        // After setWriter is called once, any subsequent call must fail
        vm.expectRevert(ActivityLog.WriterAlreadySet.selector);
        actLog.setWriter(nobody);
        // Writer must remain unchanged
        assertEq(actLog.writer(), address(this));
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_writeEntry_chainAlwaysIntact(uint8 count) public {
        count = uint8(bound(uint256(count), 1, 50));
        for (uint256 i = 0; i < count; i++) {
            actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 10e6, 40, bytes32(0));
        }
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact, "Fuzz: chain broken after writes");
        assertEq(actLog.entryCount(), count);
    }

    function testFuzz_writeEntry_entryCountMatchesWrites(uint8 count) public {
        count = uint8(bound(uint256(count), 1, 30));
        for (uint256 i = 0; i < count; i++) {
            actLog.writeEntry(policyId, agent, actLog.ACTION_DATA_FEED(), 5e6, 30, bytes32(0));
        }
        assertEq(actLog.entryCount(), count);
    }
}
