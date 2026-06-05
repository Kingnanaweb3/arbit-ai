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

contract MockPyth {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }
    mapping(bytes32 => Price) private prices;
    bool public shouldRevert;

    function setPrice(bytes32 id, int64 price, uint64 conf) external {
        prices[id] = Price(price, conf, -6, block.timestamp);
    }
    function setShouldRevert(bool _r) external { shouldRevert = _r; }
    function getPriceNoOlderThan(bytes32 id, uint256) external view returns (Price memory) {
        if (shouldRevert) revert("stale");
        Price memory p = prices[id];
        if (p.publishTime == 0) revert("not found");
        return p;
    }
}

/**
 * @title ArbitIntegrationTest
 * @notice End-to-end integration test for the full Arbit protocol stack.
 *         All five contracts deployed and wired together exactly as they
 *         would be on mainnet. No contract interactions are mocked.
 *
 *         Scenario:
 *         Act 1 — Full system deployment and wiring
 *         Act 2 — Normal agent lifecycle: register, pay, log
 *         Act 3 — Risk block: oracle spikes, payment blocked, no tokens move
 *         Act 4 — Recovery: conditions normalise, payment succeeds again
 *         Act 5 — Marketplace: seller lists, buyer hires, bad actor slashed
 *         Act 6 — Chain integrity: verify ActivityLog chain end to end
 */
contract ArbitIntegrationTest is Test {

    // ── Contracts ────────────────────────────────────────────────────────────
    PolicyRegistry    public registry;
    ActivityLog       public actLog;
    SentinelGate      public gate;
    ReputationStaking public staking;
    RiskGuardian      public guardian;
    MockPyth          public mockPyth;
    MockUSDC          public usdc;

    // ── Actors ───────────────────────────────────────────────────────────────
    address public admin     = address(this);
    address public owner     = makeAddr("owner");
    address public buyer     = makeAddr("buyer");
    address public seller    = makeAddr("seller");
    address public treasury  = makeAddr("treasury");
    address public reporter  = makeAddr("reporter");
    address public badActor  = makeAddr("badActor");

    // ── Policy state ─────────────────────────────────────────────────────────
    bytes32 public buyerPolicyId;
    bytes32 public sellerPolicyId;
    bytes32 public badActorPolicyId;

    bytes32 public pythFeedId = keccak256("ETH/USD");

    uint256 public budget  = 1000e6;
    uint256 public maxTx   = 200e6;
    uint256 public expiry;

    // =========================================================================
    // ACT 1 — Full system deployment
    // =========================================================================

    function setUp() public {
        vm.warp(1000 days);
        expiry = block.timestamp + 30 days;

        // Deploy all five contracts
        registry = new PolicyRegistry();
        actLog   = new ActivityLog();
        usdc     = new MockUSDC();
        mockPyth = new MockPyth();

        guardian = new RiskGuardian(address(mockPyth), admin);
        guardian.setDataReporter(reporter);

        gate = new SentinelGate(
            address(registry),
            address(actLog),
            address(guardian),
            admin
        );

        staking = new ReputationStaking(address(usdc));
        staking.setSlashAuthority(admin);
        staking.setTreasury(treasury);

        // Wire SentinelGate into PolicyRegistry and ActivityLog
        gate.completeSetup();

        // Register the test protocol in RiskGuardian with healthy defaults
        guardian.registerProtocol(
            address(usdc),    // treat USDC contract as the protocol for scoring
            pythFeedId,
            address(0),       // no Chainlink in integration test
            10,
            block.timestamp - 30 days,
            false,
            1_000_000e6
        );

        vm.prank(reporter);
        guardian.updateProtocolTVL(address(usdc), 1_000_000e6);

        // Set healthy oracle price
        mockPyth.setPrice(pythFeedId, 2000_000000, 1000);

        // Fund all actors
        usdc.mint(buyer,    budget * 5);
        usdc.mint(seller,   500e6);
        usdc.mint(badActor, 500e6);

        // Approve gate for all actors
        vm.prank(buyer);
        usdc.approve(address(gate), type(uint256).max);
        vm.prank(seller);
        usdc.approve(address(gate), type(uint256).max);
        vm.prank(badActor);
        usdc.approve(address(gate), type(uint256).max);

        // Approve staking contract
        vm.prank(seller);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(badActor);
        usdc.approve(address(staking), type(uint256).max);

        // Register policies
        uint8[] memory actions = new uint8[](3);
        actions[0] = registry.ACTION_DATA_FEED();
        actions[1] = registry.ACTION_DEX_SWAP();
        actions[2] = registry.ACTION_MARKETPLACE();

        vm.prank(owner);
        buyerPolicyId = registry.registerPolicy(
            buyer, address(usdc), budget, maxTx, expiry, 70, actions
        );

        uint8[] memory sellerActions = new uint8[](2);
        sellerActions[0] = registry.ACTION_DATA_FEED();
        sellerActions[1] = registry.ACTION_MARKETPLACE();

        vm.prank(owner);
        sellerPolicyId = registry.registerPolicy(
            seller, address(usdc), budget, maxTx, expiry, 70, sellerActions
        );

        vm.prank(owner);
        badActorPolicyId = registry.registerPolicy(
            badActor, address(usdc), budget, maxTx, expiry, 70, sellerActions
        );

        // Register seller as a scoreable protocol so risk tests work correctly
        guardian.registerProtocol(
            seller,
            pythFeedId,
            address(0),
            10,
            block.timestamp - 30 days,
            false,
            1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 1_000_000e6);
    }

    // =========================================================================
    // ACT 2 — Normal agent lifecycle
    // =========================================================================

    function test_integration_normalPaymentFlow() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        uint256 buyerBefore  = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        // Buyer agent pays seller
        vm.prank(buyer);
        uint256 entryIdx = gate.executePayment(
            buyerPolicyId, seller, 100e6, dataFeed, address(0)
        );

        // Tokens moved correctly
        assertEq(usdc.balanceOf(buyer),  buyerBefore - 100e6,  "Buyer balance incorrect");
        assertEq(usdc.balanceOf(seller), sellerBefore + 100e6, "Seller balance incorrect");

        // Budget consumed in registry
        assertEq(registry.getRemainingBudget(buyerPolicyId), budget - 100e6);

        // Activity logged
        assertEq(actLog.entryCount(), 1);
        assertEq(entryIdx, 0);

        // Log entry has correct fields
        ActivityLog.LogEntry memory entry = actLog.getEntry(0);
        assertEq(entry.policyId, buyerPolicyId);
        assertEq(entry.agent,    buyer);
        assertEq(entry.amount,   100e6);
    }

    function test_integration_multiplePayments_allLogged() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        vm.startPrank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));
        gate.executePayment(buyerPolicyId, seller, 50e6,  dataFeed, address(0));
        gate.executePayment(buyerPolicyId, seller, 75e6,  dataFeed, address(0));
        vm.stopPrank();

        assertEq(actLog.entryCount(), 3);
        assertEq(registry.getRemainingBudget(buyerPolicyId), budget - 225e6);

        // All entries indexed under buyer's policy
        uint256[] memory indices = actLog.getEntriesForPolicy(buyerPolicyId);
        assertEq(indices.length, 3);
    }

    // =========================================================================
    // ACT 3 — Risk block scenario (the February 2026 cascade)
    // =========================================================================

    function test_integration_riskBlock_noTokensMove() public {
        // Trigger a recent exploit on the seller protocol — this is the
        // clearest way to guarantee the risk score exceeds any ceiling
        guardian.registerProtocol(
            seller,
            pythFeedId,
            address(0),
            80,                         // high base security score
            block.timestamp - 365 days, // audit 2 years old
            true,                       // recent exploit flag
            1_000_000e6
        );

        // Also drain TVL to stack risk factors
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 0);

        // Widen oracle confidence interval
        mockPyth.setPrice(pythFeedId, 2000_000000, 400_000000);

        uint8 dataFeed = registry.ACTION_DATA_FEED();
        uint256 buyerBefore = usdc.balanceOf(buyer);

        // Payment should be blocked — risk score exceeds ceiling of 70
        vm.prank(buyer);
        vm.expectRevert();
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        // No tokens moved
        assertEq(usdc.balanceOf(buyer), buyerBefore, "INTEGRATION: tokens moved during risk block");

        // Budget unchanged
        assertEq(
            registry.getRemainingBudget(buyerPolicyId),
            budget,
            "INTEGRATION: budget consumed during risk block"
        );
    }

    function test_integration_riskBlock_thenRecovery() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Stress conditions — exploit flag + TVL drain + wide oracle
        guardian.registerProtocol(
            seller, pythFeedId, address(0), 80,
            block.timestamp - 365 days, true, 1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 0);
        mockPyth.setPrice(pythFeedId, 2000_000000, 400_000000);

        // Payment blocked
        uint256 balanceBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        try gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0)) {}
        catch {}

        // No tokens moved during block
        assertEq(usdc.balanceOf(buyer), balanceBefore, "Tokens moved during block");

        // Conditions normalise — remove exploit flag, restore TVL, tighten oracle
        guardian.registerProtocol(
            seller, pythFeedId, address(0), 5,
            block.timestamp - 30 days, false, 1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 1_000_000e6);
        mockPyth.setPrice(pythFeedId, 2000_000000, 500);

        // Payment succeeds after recovery
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        assertEq(
            usdc.balanceOf(buyer),
            balanceBefore - 100e6,
            "INTEGRATION: payment did not succeed after recovery"
        );
    }

    // =========================================================================
    // ACT 4 — Policy lifecycle
    // =========================================================================

    function test_integration_policyRevoke_blocksAllFuturePayments() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // One successful payment
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        // Owner revokes
        vm.prank(owner);
        registry.revokePolicy(buyerPolicyId);

        // All future payments blocked
        vm.prank(buyer);
        vm.expectRevert();
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        // Only the first payment was logged
        assertEq(actLog.entryCount(), 1);
    }

    function test_integration_policyExpiry_blocksPayments() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Successful payment before expiry
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        // Fast forward past expiry
        vm.warp(expiry + 1);

        // Payment blocked
        vm.prank(buyer);
        vm.expectRevert();
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));
    }

    function test_integration_budgetIncrease_enablesMorePayments() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Exhaust budget
        vm.startPrank(buyer);
        for (uint256 i = 0; i < 5; i++) {
            gate.executePayment(buyerPolicyId, seller, 200e6, dataFeed, address(0));
        }
        vm.stopPrank();

        assertEq(registry.getRemainingBudget(buyerPolicyId), 0);

        // Next payment fails
        vm.prank(buyer);
        vm.expectRevert();
        gate.executePayment(buyerPolicyId, seller, 1, dataFeed, address(0));

        // Owner tops up budget
        vm.prank(owner);
        registry.increaseBudget(buyerPolicyId, 500e6);
        usdc.mint(buyer, 500e6);

        // Payment succeeds again
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        assertEq(registry.getRemainingBudget(buyerPolicyId), 400e6);
    }

    // =========================================================================
    // ACT 5 — Marketplace: listing, hiring, slash
    // =========================================================================

    function test_integration_marketplace_listAndVerify() public {
        vm.prank(seller);
        staking.listService(100e6, 10e6, 0, keccak256("Data feed service"));

        assertTrue(staking.isListed(seller));
        assertEq(staking.getListing(seller).stakedAmount, 100e6);
        assertEq(staking.getActiveListings().length, 1);
    }

    function test_integration_marketplace_reputationBuildsOverTime() public {
        vm.prank(seller);
        staking.listService(100e6, 10e6, 0, keccak256("Data feed service"));

        // Record several successful calls
        staking.recordCall(seller, true);
        staking.recordCall(seller, true);
        staking.recordCall(seller, true);
        staking.recordCall(seller, false); // one failure

        // 3 successes out of 4 = 75% success rate
        assertEq(staking.getReputationScore(seller), 75);
    }

    function test_integration_badActor_slashedAndSuspended() public {
        vm.prank(badActor);
        staking.listService(100e6, 10e6, 0, keccak256("Malicious service"));

        uint256 buyerBefore    = usdc.balanceOf(buyer);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // Bad actor is slashed
        staking.slashStake(badActor, buyer, 100e6, "Delivered malicious payload");

        // Buyer compensated — 70% of slash
        assertEq(usdc.balanceOf(buyer),    buyerBefore + 70e6);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 30e6);

        // Bad actor suspended
        assertFalse(staking.isListed(badActor));
        assertEq(staking.getListing(badActor).stakedAmount, 0);
    }

    function test_integration_badActor_cannotDelistAfterSlash() public {
        vm.prank(badActor);
        staking.listService(100e6, 10e6, 0, keccak256("Malicious service"));

        staking.slashStake(badActor, buyer, 60e6, "Partial slash");

        // Still has 40 USDC staked but is suspended
        // Cannot delist to recover it
        vm.prank(badActor);
        vm.expectRevert();
        staking.delistService();

        assertEq(
            staking.getListing(badActor).stakedAmount,
            40e6,
            "INTEGRATION: bad actor recovered stake after slash"
        );
    }

    // =========================================================================
    // ACT 6 — Chain integrity across the entire test
    // =========================================================================

    function test_integration_activityLog_chainIntegrity() public {
        uint8 dataFeed = registry.ACTION_DATA_FEED();

        // Generate several log entries
        vm.startPrank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));
        gate.executePayment(buyerPolicyId, seller, 50e6,  dataFeed, address(0));
        gate.executePayment(buyerPolicyId, seller, 75e6,  dataFeed, address(0));
        vm.stopPrank();

        vm.prank(seller);
        gate.executePayment(sellerPolicyId, buyer, 30e6, dataFeed, address(0));

        assertEq(actLog.entryCount(), 4);

        // Verify the entire chain is intact
        (bool intact, uint256 brokenAt) = actLog.verifyChain(0);
        assertTrue(intact, "INTEGRATION: activity log chain broken");
        assertEq(brokenAt, 0);
    }

    function test_integration_fullScenario_endToEnd() public {
        uint8 dataFeed   = registry.ACTION_DATA_FEED();
        uint8 marketplace = registry.ACTION_MARKETPLACE();

        // 1. Seller lists on marketplace
        vm.prank(seller);
        staking.listService(200e6, 15e6, 0, keccak256("Premium data feed"));
        assertTrue(staking.isListed(seller));

        // 2. Buyer makes several payments
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 50e6, marketplace, address(0));

        // 3. Risk spikes — payment blocked
        guardian.registerProtocol(
            seller, pythFeedId, address(0), 80,
            block.timestamp - 365 days, true, 1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 0);
        mockPyth.setPrice(pythFeedId, 2000_000000, 300_000000);

        vm.prank(buyer);
        vm.expectRevert();
        gate.executePayment(buyerPolicyId, seller, 100e6, dataFeed, address(0));

        // 4. Conditions recover
        guardian.registerProtocol(
            seller, pythFeedId, address(0), 5,
            block.timestamp - 30 days, false, 1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(seller, 1_000_000e6);
        mockPyth.setPrice(pythFeedId, 2000_000000, 500);

        // 5. Payment succeeds again
        vm.prank(buyer);
        gate.executePayment(buyerPolicyId, seller, 75e6, dataFeed, address(0));

        // 6. Verify final state
        assertEq(actLog.entryCount(), 3); // 3 successful payments logged
        assertEq(
            registry.getRemainingBudget(buyerPolicyId),
            budget - 225e6
        );

        // 7. Chain must be intact throughout
        (bool intact,) = actLog.verifyChain(0);
        assertTrue(intact, "INTEGRATION: chain broken after full scenario");

        // 8. Seller reputation reflects successful calls
        staking.recordCall(seller, true);
        staking.recordCall(seller, true);
        assertEq(staking.getReputationScore(seller), 100);
    }
}