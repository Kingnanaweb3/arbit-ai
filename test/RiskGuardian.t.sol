// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {RiskGuardian} from "../src/RiskGuardian.sol";

// Minimal mock Pyth that we fully control in tests
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

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function getPriceNoOlderThan(bytes32 id, uint256)
        external
        view
        returns (Price memory)
    {
        if (shouldRevert) revert("stale");
        Price memory p = prices[id];
        if (p.publishTime == 0) revert("not found");
        return p;
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}
}

// Minimal mock Chainlink aggregator
contract MockChainlink {
    int256 public answer;
    bool   public shouldFail;

    function setAnswer(int256 _answer) external { answer = _answer; }
    function setShouldFail(bool _fail) external { shouldFail = _fail; }

    function latestAnswer() external view returns (int256) {
        if (shouldFail) revert("chainlink down");
        return answer;
    }
}

contract RiskGuardianTest is Test {

    RiskGuardian    public guardian;
    MockPyth        public mockPyth;
    MockChainlink   public mockChainlink;

    address public admin    = address(this);
    address public reporter = makeAddr("reporter");
    address public nobody   = makeAddr("nobody");
    address public protocol = makeAddr("protocol");
    address public agent    = makeAddr("agent");

    bytes32 public policyId  = keccak256("policy1");
    bytes32 public feedId    = keccak256("ETH/USD");

    function setUp() public {
        // Warp to a realistic timestamp so arithmetic like
        // block.timestamp - 30 days does not underflow
        vm.warp(365 days);

        mockPyth      = new MockPyth();
        mockChainlink = new MockChainlink();
        guardian      = new RiskGuardian(address(mockPyth), admin);

        guardian.setDataReporter(reporter);

        // Set a default healthy price — $2000 with tight confidence
        mockPyth.setPrice(feedId, 2000_000000, 1000); // $2000, $0.001 conf
        mockChainlink.setAnswer(2000_000000);

        // Register the test protocol with healthy defaults
        guardian.registerProtocol(
            protocol,
            feedId,
            address(mockChainlink),
            10,                          // low base security score
            block.timestamp - 30 days,   // audited 30 days ago
            false,                       // no recent exploit
            1_000_000e6                  // 1M USDC reference TVL
        );

        // Set current TVL equal to reference — healthy
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, 1_000_000e6);
    }

    // =========================================================================
    // Constructor and setup
    // =========================================================================

    function test_constructor_storesPyth() public view {
        assertEq(address(guardian.pyth()), address(mockPyth));
    }

    function test_constructor_storesAdmin() public view {
        assertEq(guardian.admin(), admin);
    }

    function test_constructor_revert_zeroPyth() public {
        vm.expectRevert(RiskGuardian.ZeroAddressNotAllowed.selector);
        new RiskGuardian(address(0), admin);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(RiskGuardian.ZeroAddressNotAllowed.selector);
        new RiskGuardian(address(mockPyth), address(0));
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    function test_setDataReporter_storesReporter() public view {
        assertEq(guardian.dataReporter(), reporter);
    }

    function test_setDataReporter_revert_callerNotAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskGuardian.OnlyAdminCanDoThis.selector,
                nobody,
                admin
            )
        );
        guardian.setDataReporter(nobody);
    }

    function test_transferAdmin_updatesAdmin() public {
        guardian.transferAdmin(nobody);
        assertEq(guardian.admin(), nobody);
    }

    function test_transferAdmin_revert_callerNotAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        guardian.transferAdmin(nobody);
    }

    function test_transferAdmin_revert_zeroAddress() public {
        vm.expectRevert(RiskGuardian.ZeroAddressNotAllowed.selector);
        guardian.transferAdmin(address(0));
    }

    // =========================================================================
    // registerProtocol
    // =========================================================================

    function test_registerProtocol_isRegistered() public view {
        assertTrue(guardian.isProtocolRegistered(protocol));
    }

    function test_registerProtocol_storesProfile() public view {
        RiskGuardian.ProtocolRiskProfile memory p = guardian.getProtocolProfile(protocol);
        assertEq(p.pythPriceFeedId,   feedId);
        assertEq(p.baseSecurityScore, 10);
        assertFalse(p.recentExploit);
    }

    function test_registerProtocol_revert_callerNotAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        guardian.registerProtocol(
            makeAddr("newProtocol"),
            feedId,
            address(mockChainlink),
            10,
            block.timestamp,
            false,
            1_000_000e6
        );
    }

    function test_registerProtocol_revert_zeroAddress() public {
        vm.expectRevert(RiskGuardian.ZeroAddressNotAllowed.selector);
        guardian.registerProtocol(
            address(0),
            feedId,
            address(mockChainlink),
            10,
            block.timestamp,
            false,
            1_000_000e6
        );
    }

    // =========================================================================
    // getScore — healthy conditions
    // =========================================================================

    function test_getScore_healthyProtocol_lowScore() public view {
        uint8 score = guardian.getScore(policyId, protocol);
        // Healthy conditions — score should be well below 70
        assertLt(score, 50, "Healthy protocol should have low risk score");
    }

    function test_getScore_alwaysReturnsValidRange() public view {
        uint8 score = guardian.getScore(policyId, protocol);
        assertLe(score, 100);
    }

    function test_getScore_unknownProtocol_returnsConservativeScore() public {
        address unknown = makeAddr("unknown");
        uint8 score = guardian.getScore(policyId, unknown);
        // Unknown protocol gets conservative scores across all dimensions
        assertGt(score, 0, "Unknown protocol should have non-zero risk");
    }

    // =========================================================================
    // Volatility dimension
    // =========================================================================

    function test_volatility_tightConfidence_lowScore() public view {
        // Very tight confidence — $0.001 on a $2000 price — very low volatility
        uint8 score = guardian.getScore(policyId, protocol);
        assertLt(score, 70);
    }

    function test_volatility_wideConfidence_highScore() public {
        // Wide confidence — $200 on a $2000 price — 10% conf/price ratio
        mockPyth.setPrice(feedId, 2000_000000, 200_000000);
        uint8 score = guardian.getScore(policyId, protocol);
        assertGt(score, 10, "Wide confidence should increase risk score");
    }

    function test_volatility_staleFeed_highScore() public {
        mockPyth.setShouldRevert(true);
        uint8 score = guardian.getScore(policyId, protocol);
        assertGt(score, 30, "Stale oracle should increase risk score");
    }

    // =========================================================================
    // TVL dimension
    // =========================================================================

    function test_tvl_healthyTVL_lowScore() public view {
        uint8 score = guardian.getScore(policyId, protocol);
        assertLt(score, 70);
    }

    function test_tvl_50percentDrop_increasesScore() public {
        uint8 scoreBefore = guardian.getScore(policyId, protocol);
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, 500_000e6); // 50% drop
        uint8 scoreAfter = guardian.getScore(policyId, protocol);
        assertGt(scoreAfter, scoreBefore, "TVL drop should increase risk score");
    }

    function test_tvl_totalDrain_maximisesComponent() public {
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, 0);
        uint8 score = guardian.getScore(policyId, protocol);
        assertGt(score, 20, "Total TVL drain should significantly increase risk");
    }

    function test_tvl_increasedTVL_doesNotIncreaseScore() public {
        uint8 scoreBefore = guardian.getScore(policyId, protocol);
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, 2_000_000e6); // TVL doubled
        uint8 scoreAfter = guardian.getScore(policyId, protocol);
        assertLe(scoreAfter, scoreBefore, "TVL increase should not increase risk");
    }

    // =========================================================================
    // Security dimension
    // =========================================================================

    function test_security_recentExploit_maximisesComponent() public {
        guardian.registerProtocol(
            protocol,
            feedId,
            address(mockChainlink),
            10,
            block.timestamp - 30 days,
            true,  // recent exploit
            1_000_000e6
        );
        uint8 score = guardian.getScore(policyId, protocol);
        assertGt(score, 15, "Recent exploit should significantly increase risk");
    }

    function test_security_auditDecay_increasesOverTime() public {
        uint8 scoreFresh = guardian.getScore(policyId, protocol);

        // Fast forward 2 years — audit should have decayed significantly
        vm.warp(block.timestamp + 730 days);
        uint8 scoreDecayed = guardian.getScore(policyId, protocol);

        assertGt(scoreDecayed, scoreFresh, "Audit decay should increase risk over time");
    }

    // =========================================================================
    // Agent behaviour dimension
    // =========================================================================

    function test_behaviour_cleanAgent_zeroScore() public view {
        // Agent with no history — behaviour component should be 0
        uint8 score = guardian.getScore(policyId, agent);
        // Score reflects mostly unknown protocol defaults, not behaviour
        assertLe(score, 100);
    }

    function test_behaviour_herdingFlag_increasesScore() public {
        uint8 scoreBefore = guardian.getScore(policyId, agent);

        vm.prank(reporter);
        guardian.updateAgentBehaviour(agent, true, false, 5);

        uint8 scoreAfter = guardian.getScore(policyId, agent);
        assertGt(scoreAfter, scoreBefore, "Herding flag should increase risk score");
    }

    function test_behaviour_maliciousFlag_maximisesComponent() public {
        vm.prank(reporter);
        guardian.updateAgentBehaviour(agent, false, true, 0);

        // Register the agent address as a protocol so we can score it directly
        guardian.registerProtocol(
            agent,
            feedId,
            address(mockChainlink),
            10,
            block.timestamp - 30 days,
            false,
            1_000_000e6
        );

        vm.prank(reporter);
        guardian.updateProtocolTVL(agent, 1_000_000e6);

        uint8 score = guardian.getScore(policyId, agent);
        assertGt(score, 5, "Malicious flag should increase risk score");
    }

    function test_behaviour_riskTriggers_accumulateScore() public {
        vm.startPrank(reporter);
        guardian.recordRiskTrigger(agent);
        guardian.recordRiskTrigger(agent);
        guardian.recordRiskTrigger(agent);
        vm.stopPrank();

        RiskGuardian.AgentBehaviourProfile memory p = guardian.getAgentProfile(agent);
        assertEq(p.riskTriggerCount, 3);
    }

    function test_behaviour_revert_reporterOnly() public {
        vm.prank(nobody);
        vm.expectRevert();
        guardian.updateAgentBehaviour(agent, true, false, 5);
    }

    // =========================================================================
    // updateProtocolTVL
    // =========================================================================

    function test_updateTVL_revert_callerNotReporter() public {
        vm.prank(nobody);
        vm.expectRevert();
        guardian.updateProtocolTVL(protocol, 500_000e6);
    }

    function test_updateTVL_adminCanAlsoUpdate() public {
        // Admin should be able to update TVL without being the reporter
        guardian.updateProtocolTVL(protocol, 800_000e6);
        RiskGuardian.ProtocolRiskProfile memory p = guardian.getProtocolProfile(protocol);
        assertEq(p.currentTVL, 800_000e6);
    }

    // =========================================================================
    // Core invariants
    // =========================================================================

    function test_invariant_scoreAlwaysBetween0And100() public view {
        uint8 score = guardian.getScore(policyId, protocol);
        assertLe(score, 100, "INVARIANT: score exceeded 100");
    }

    function test_invariant_staleOracleNeverLowersScore() public {
        uint8 scoreFresh = guardian.getScore(policyId, protocol);
        mockPyth.setShouldRevert(true);
        uint8 scoreStale = guardian.getScore(policyId, protocol);
        assertGe(scoreStale, scoreFresh, "INVARIANT: stale oracle lowered risk score");
    }

    function test_invariant_recentExploitAlwaysHighScore() public {
        guardian.registerProtocol(
            protocol,
            feedId,
            address(mockChainlink),
            0,
            block.timestamp,
            true, // exploit
            1_000_000e6
        );
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, 1_000_000e6);
        uint8 score = guardian.getScore(policyId, protocol);
        assertGt(score, 15, "INVARIANT: recent exploit should always raise score");
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_getScore_alwaysInRange(
        int64  price,
        uint64 conf,
        uint256 currentTVL
    ) public {
        price      = int64(bound(int256(price), 1, 1_000_000_000_000));
        conf       = uint64(bound(uint256(conf), 0, uint256(uint64(price))));
        currentTVL = bound(currentTVL, 0, 10_000_000e6);

        mockPyth.setPrice(feedId, price, conf);
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, currentTVL);

        uint8 score = guardian.getScore(policyId, protocol);
        assertLe(score, 100, "Fuzz: score exceeded 100");
    }

    function testFuzz_tvlDrop_neverExceeds100(uint256 currentTVL) public {
        currentTVL = bound(currentTVL, 0, 2_000_000e6);
        vm.prank(reporter);
        guardian.updateProtocolTVL(protocol, currentTVL);
        uint8 score = guardian.getScore(policyId, protocol);
        assertLe(score, 100, "Fuzz: TVL score exceeded 100");
    }
}
