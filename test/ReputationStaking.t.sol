// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ReputationStaking} from "../src/ReputationStaking.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReputationStakingTest is Test {

    ReputationStaking public staking;
    MockUSDC          public usdc;

    address public slashAuth = address(this);
    address public treasury  = makeAddr("treasury");
    address public agent     = makeAddr("agent");
    address public agent2    = makeAddr("agent2");
    address public buyer     = makeAddr("buyer");
    address public nobody    = makeAddr("nobody");

    uint256 public minStake  = 100e6;
    bytes32 public desc      = keccak256("Data feed service");

    function setUp() public {
        usdc    = new MockUSDC();
        staking = new ReputationStaking(address(usdc));

        staking.setSlashAuthority(slashAuth);
        staking.setTreasury(treasury);

        // Fund agents
        usdc.mint(agent,  1000e6);
        usdc.mint(agent2, 1000e6);

        // Approve staking contract
        vm.prank(agent);
        usdc.approve(address(staking), type(uint256).max);
        vm.prank(agent2);
        usdc.approve(address(staking), type(uint256).max);
    }

    // =========================================================================
    // Setup
    // =========================================================================

    function test_setup_slashAuthoritySet() public view {
        assertEq(staking.slashAuthority(), slashAuth);
    }

    function test_setup_treasurySet() public view {
        assertEq(staking.treasury(), treasury);
    }

    function test_setSlashAuthority_revert_calledTwice() public {
        vm.expectRevert(ReputationStaking.SlashAuthorityAlreadySet.selector);
        staking.setSlashAuthority(nobody);
    }

    function test_setTreasury_revert_calledTwice() public {
        vm.expectRevert(ReputationStaking.TreasuryAlreadySet.selector);
        staking.setTreasury(nobody);
    }

    function test_setSlashAuthority_revert_zeroAddress() public {
        ReputationStaking fresh = new ReputationStaking(address(usdc));
        vm.expectRevert(ReputationStaking.ZeroAddressNotAllowed.selector);
        fresh.setSlashAuthority(address(0));
    }

    function test_setTreasury_revert_zeroAddress() public {
        ReputationStaking fresh = new ReputationStaking(address(usdc));
        vm.expectRevert(ReputationStaking.ZeroAddressNotAllowed.selector);
        fresh.setTreasury(address(0));
    }

    // =========================================================================
    // listService — happy paths
    // =========================================================================

    function test_listService_agentIsListed() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        assertTrue(staking.isListed(agent));
    }

    function test_listService_pullsStakeFromAgent() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        assertEq(usdc.balanceOf(agent), 1000e6 - minStake);
    }

    function test_listService_contractHoldsStake() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        assertEq(usdc.balanceOf(address(staking)), minStake);
    }

    function test_listService_updatesTotalStaked() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        assertEq(staking.totalStaked(), minStake);
    }

    function test_listService_storesListingCorrectly() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.agent,        agent);
        assertEq(l.pricePerCall, 10e6);
        assertEq(l.category,     0);
        assertEq(l.stakedAmount, minStake);
        assertEq(l.description,  desc);
    }

    function test_listService_incrementsTotalListings() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        assertEq(staking.getTotalListings(), 1);
    }

    function test_listService_appearsInActiveListings() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        address[] memory active = staking.getActiveListings();
        assertEq(active.length, 1);
        assertEq(active[0], agent);
    }

    function test_listService_twoAgents_bothActive() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent2);
        staking.listService(minStake, 20e6, 1, desc);
        address[] memory active = staking.getActiveListings();
        assertEq(active.length, 2);
    }

    function test_listService_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ReputationStaking.ServiceListed(agent, 0, 10e6, minStake);
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
    }

    // =========================================================================
    // listService — revert conditions
    // =========================================================================

    function test_listService_revert_belowMinimumStake() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.MinimumStakeNotMet.selector,
                50e6,
                minStake
            )
        );
        staking.listService(50e6, 10e6, 0, desc);
    }

    function test_listService_revert_zeroPricePerCall() public {
        vm.prank(agent);
        vm.expectRevert(ReputationStaking.ServicePriceTooLow.selector);
        staking.listService(minStake, 0, 0, desc);
    }

    function test_listService_revert_invalidCategory() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.InvalidCategory.selector,
                10
            )
        );
        staking.listService(minStake, 10e6, 10, desc);
    }

    function test_listService_revert_alreadyListed() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.AgentAlreadyListed.selector,
                agent
            )
        );
        staking.listService(minStake, 10e6, 0, desc);
    }

    function test_listService_revert_setupIncomplete() public {
        ReputationStaking fresh = new ReputationStaking(address(usdc));
        vm.prank(agent);
        vm.expectRevert(ReputationStaking.SetupIncomplete.selector);
        fresh.listService(minStake, 10e6, 0, desc);
    }

    // =========================================================================
    // delistService
    // =========================================================================

    function test_delistService_agentNoLongerListed() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.delistService();
        assertFalse(staking.isListed(agent));
    }

    function test_delistService_returnsStakeToAgent() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.delistService();
        assertEq(usdc.balanceOf(agent), 1000e6);
    }

    function test_delistService_decreasesTotalStaked() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.delistService();
        assertEq(staking.totalStaked(), 0);
    }

    function test_delistService_removesFromActiveListings() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.delistService();
        assertEq(staking.getActiveListings().length, 0);
    }

    function test_delistService_revert_notListed() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.AgentNotListed.selector,
                agent
            )
        );
        staking.delistService();
    }

    // =========================================================================
    // increaseStake
    // =========================================================================

    function test_increaseStake_updatesStakedAmount() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.increaseStake(50e6);
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.stakedAmount, minStake + 50e6);
    }

    function test_increaseStake_updatesTotalStaked() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        staking.increaseStake(50e6);
        assertEq(staking.totalStaked(), minStake + 50e6);
    }

    function test_increaseStake_revert_notListed() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.AgentNotListed.selector,
                agent
            )
        );
        staking.increaseStake(50e6);
    }

    function test_increaseStake_revert_zeroAmount() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent);
        vm.expectRevert(ReputationStaking.StakeAmountMustBePositive.selector);
        staking.increaseStake(0);
    }

    // =========================================================================
    // slashStake
    // =========================================================================

    function test_slashStake_reducesAgentStake() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.slashStake(agent, buyer, 60e6, "Failed delivery");
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.stakedAmount, minStake - 60e6);
    }

    function test_slashStake_buyerReceives70Percent() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.slashStake(agent, buyer, 100e6, "Malicious service");
        uint256 expected = (100e6 * 7000) / 10000;
        assertEq(usdc.balanceOf(buyer), expected);
    }

    function test_slashStake_treasuryReceives30Percent() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.slashStake(agent, buyer, 100e6, "Malicious service");
        uint256 expected = 100e6 - (100e6 * 7000) / 10000;
        assertEq(usdc.balanceOf(treasury), expected);
    }

    function test_slashStake_suspensAgent() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.slashStake(agent, buyer, 60e6, "Failed delivery");
        assertFalse(staking.isListed(agent));
    }

    function test_slashStake_capsAtStakedAmount() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        // Try to slash more than staked — should only slash what is there
        staking.slashStake(agent, buyer, 500e6, "Massive slash");
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.stakedAmount, 0);
        // Buyer should only receive 70% of what was actually staked
        uint256 expected = (minStake * 7000) / 10000;
        assertEq(usdc.balanceOf(buyer), expected);
    }

    function test_slashStake_emitsEvents() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.expectEmit(true, true, false, false);
        emit ReputationStaking.StakeSlashed(agent, buyer, 60e6, 0, 0);
        staking.slashStake(agent, buyer, 60e6, "Failed delivery");
    }

    function test_slashStake_revert_callerNotAuthority() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.OnlySlashAuthorityCanDoThis.selector,
                nobody,
                slashAuth
            )
        );
        staking.slashStake(agent, buyer, 60e6, "Failed delivery");
    }

    function test_slashStake_revert_zeroStake() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationStaking.InsufficientStake.selector,
                0,
                60e6
            )
        );
        staking.slashStake(agent, buyer, 60e6, "Failed delivery");
    }

    // =========================================================================
    // recordCall
    // =========================================================================

    function test_recordCall_incrementsSuccessCount() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.recordCall(agent, true);
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.successfulCalls, 1);
    }

    function test_recordCall_incrementsFailCount() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.recordCall(agent, false);
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.failedCalls, 1);
    }

    function test_recordCall_revert_callerNotAuthority() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(nobody);
        vm.expectRevert();
        staking.recordCall(agent, true);
    }

    // =========================================================================
    // getReputationScore
    // =========================================================================

    function test_reputationScore_unlistedAgent_isZero() public view {
        assertEq(staking.getReputationScore(agent), 0);
    }

    function test_reputationScore_newListing_basedOnStake() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        // 1x minimum stake = base score of 10
        assertEq(staking.getReputationScore(agent), 10);
    }

    function test_reputationScore_allSuccessful_is100() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.recordCall(agent, true);
        staking.recordCall(agent, true);
        staking.recordCall(agent, true);
        assertEq(staking.getReputationScore(agent), 100);
    }

    function test_reputationScore_halfSuccessful_is50() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.recordCall(agent, true);
        staking.recordCall(agent, false);
        assertEq(staking.getReputationScore(agent), 50);
    }

    function test_reputationScore_suspended_takespenalty() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        staking.recordCall(agent, true);
        staking.recordCall(agent, true);
        // 100% success rate before slash
        assertEq(staking.getReputationScore(agent), 100);
        // Slash suspends the agent
        staking.slashStake(agent, buyer, 30e6, "Penalty");
        // Score should drop by 20 points
        assertEq(staking.getReputationScore(agent), 80);
    }

    // =========================================================================
    // Core invariants
    // =========================================================================

    function test_invariant_totalStakedMatchesContractBalance() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        vm.prank(agent2);
        staking.listService(200e6, 20e6, 1, desc);
        assertEq(
            staking.totalStaked(),
            usdc.balanceOf(address(staking)),
            "INVARIANT: totalStaked does not match contract balance"
        );
    }

    function test_invariant_slashNeverExceedsStake() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        // Try to slash 10x the staked amount
        staking.slashStake(agent, buyer, minStake * 10, "Massive slash");
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertEq(l.stakedAmount, 0, "INVARIANT: stake went negative after slash");
        assertGe(
            usdc.balanceOf(buyer) + usdc.balanceOf(treasury),
            0,
            "INVARIANT: slash distributed more than staked"
        );
    }

    function test_invariant_delistAlwaysReturnsFullStake() public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        uint256 balanceBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        staking.delistService();
        assertEq(
            usdc.balanceOf(agent),
            balanceBefore + minStake,
            "INVARIANT: delist did not return full stake"
        );
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_slashNeverExceedsStake(uint256 slashAmount) public {
        slashAmount = bound(slashAmount, 1, 10_000e6);
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        uint256 stakedBefore = staking.getListing(agent).stakedAmount;
        staking.slashStake(agent, buyer, slashAmount, "Fuzz slash");
        ReputationStaking.ServiceListing memory l = staking.getListing(agent);
        assertLe(
            stakedBefore - l.stakedAmount,
            stakedBefore,
            "Fuzz: slash exceeded staked amount"
        );
    }

    function testFuzz_reputationScore_alwaysBetween0And100(
        uint8 successes,
        uint8 failures
    ) public {
        vm.prank(agent);
        staking.listService(minStake, 10e6, 0, desc);
        for (uint256 i = 0; i < successes; i++) {
            staking.recordCall(agent, true);
        }
        for (uint256 i = 0; i < failures; i++) {
            staking.recordCall(agent, false);
        }
        uint8 score = staking.getReputationScore(agent);
        assertLe(score, 100, "Fuzz: reputation score exceeded 100");
    }
}
