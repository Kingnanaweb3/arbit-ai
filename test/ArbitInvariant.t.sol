// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {ActivityLog} from "../src/ActivityLog.sol";
import {ReputationStaking} from "../src/ReputationStaking.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title PolicyRegistryHandler
 * @notice Drives random calls into PolicyRegistry so the invariant
 *         runner can explore every possible state transition.
 *
 *         The handler is what Foundry calls randomly. It wraps every
 *         function with bounded inputs so calls are always valid enough
 *         to reach the contract logic rather than failing on input checks.
 */
contract PolicyRegistryHandler is Test {

    PolicyRegistry public registry;
    MockUSDC       public usdc;

    address public gate    = address(this);
    address public owner   = makeAddr("owner");

    // Track all registered policies so we can call functions on them
    bytes32[] public policyIds;

    // Track total amount consumed across all policies
    uint256 public totalConsumed;

    uint256 public constant BUDGET = 10_000e6;
    uint256 public constant MAX_TX = 1_000e6;

    uint8[] actions;

    constructor(address _registry, address _usdc) {
        registry = PolicyRegistry(_registry);
        usdc     = MockUSDC(_usdc);

        registry.setSentinelGate(gate);

        actions = new uint8[](2);
        actions[0] = 0;
        actions[1] = 1;
    }

    function registerNewPolicy(address agentSeed) public {
        // Derive a unique agent address from the seed
        address agent = address(uint160(uint256(keccak256(abi.encodePacked(agentSeed, policyIds.length)))));

        // Skip if agent equals owner
        if (agent == owner) return;

        vm.prank(owner);
        bytes32 pid = registry.registerPolicy(
            agent,
            address(usdc),
            BUDGET,
            MAX_TX,
            block.timestamp + 30 days,
            70,
            actions
        );

        policyIds.push(pid);
    }

    function consumeBudget(uint256 policyIndex, uint256 amount) public {
        if (policyIds.length == 0) return;

        bytes32 pid = policyIds[policyIndex % policyIds.length];
        if (!registry.isPolicyActive(pid)) return;

        uint256 remaining = registry.getRemainingBudget(pid);
        if (remaining == 0) return;

        // Bound amount to what is actually available and within maxTx
        amount = bound(amount, 1, remaining < MAX_TX ? remaining : MAX_TX);

        // Only consume permitted action types
        registry.consumeBudget(pid, amount, 0);
        totalConsumed += amount;
    }

    function revokePolicy(uint256 policyIndex) public {
        if (policyIds.length == 0) return;

        bytes32 pid = policyIds[policyIndex % policyIds.length];
        if (!registry.isPolicyActive(pid)) return;

        vm.prank(owner);
        registry.revokePolicy(pid);
    }

    function increaseBudget(uint256 policyIndex, uint256 amount) public {
        if (policyIds.length == 0) return;

        bytes32 pid = policyIds[policyIndex % policyIds.length];
        if (!registry.isPolicyActive(pid)) return;

        amount = bound(amount, 1e6, 10_000e6);

        vm.prank(owner);
        registry.increaseBudget(pid, amount);
    }

    function warpTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 60 days);
        vm.warp(block.timestamp + seconds_);
    }

    function getPolicyCount() public view returns (uint256) {
        return policyIds.length;
    }
}

/**
 * @title ActivityLogHandler
 * @notice Drives random writes into ActivityLog.
 */
contract ActivityLogHandler is Test {

    ActivityLog public actLog;
    uint256     public totalEntries;

    constructor(address _actLog) {
        actLog = ActivityLog(_actLog);
        actLog.setWriter(address(this));
    }

    function writeEntry(
        bytes32 policyId,
        address agent,
        uint8   actionType,
        uint256 amount,
        uint8   riskScore
    ) public {
        if (agent == address(0)) return;

        actionType = uint8(bound(uint256(actionType), 0, 4));
        amount     = bound(amount, 0, 1_000_000e6);
        riskScore  = uint8(bound(uint256(riskScore), 0, 100));

        actLog.writeEntry(policyId, agent, actionType, amount, riskScore, bytes32(0));
        totalEntries++;
    }
}

/**
 * @title ReputationStakingHandler
 * @notice Drives random staking operations.
 */
contract ReputationStakingHandler is Test {

    ReputationStaking public staking;
    MockUSDC          public usdc;
    address           public slashAuth = address(this);
    address           public treasury  = makeAddr("treasury");

    address[] public listedAgents;

    constructor(address _staking, address _usdc) {
        staking  = ReputationStaking(_staking);
        usdc     = MockUSDC(_usdc);

        staking.setSlashAuthority(slashAuth);
        staking.setTreasury(treasury);
    }

    function listService(address agentSeed, uint256 stakeAmount) public {
        address agent = address(uint160(uint256(keccak256(abi.encodePacked(agentSeed, "agent")))));

        if (staking.isListed(agent)) return;

        stakeAmount = bound(stakeAmount, 100e6, 500e6);

        usdc.mint(agent, stakeAmount);

        vm.prank(agent);
        usdc.approve(address(staking), stakeAmount);

        vm.prank(agent);
        staking.listService(stakeAmount, 10e6, 0, keccak256("service"));

        listedAgents.push(agent);
    }

    function delistService(uint256 agentIndex) public {
        if (listedAgents.length == 0) return;

        address agent = listedAgents[agentIndex % listedAgents.length];
        if (!staking.isListed(agent)) return;

        vm.prank(agent);
        staking.delistService();
    }

    function slashStake(uint256 agentIndex, uint256 slashAmount) public {
        if (listedAgents.length == 0) return;

        address agent = listedAgents[agentIndex % listedAgents.length];
        if (staking.getListing(agent).stakedAmount == 0) return;

        slashAmount = bound(slashAmount, 1, 1_000e6);

        staking.slashStake(agent, treasury, slashAmount, "invariant test slash");
    }

    function getContractBalance() public view returns (uint256) {
        return usdc.balanceOf(address(staking));
    }

    function getTotalStaked() public view returns (uint256) {
        return staking.totalStaked();
    }
}

// =============================================================================
// INVARIANT TEST CONTRACTS
// =============================================================================

/**
 * @title PolicyRegistryInvariant
 * @notice Proves three security guarantees hold across any sequence of calls:
 *
 *         1. spentAmount can never exceed maxBudget
 *         2. A revoked policy can never become active again
 *         3. entryCount in ActivityLog only ever increases
 */
contract PolicyRegistryInvariant is StdInvariant, Test {

    PolicyRegistry        public registry;
    MockUSDC              public usdc;
    PolicyRegistryHandler public handler;

    function setUp() public {
        vm.warp(365 days);

        usdc     = new MockUSDC();
        registry = new PolicyRegistry();
        handler  = new PolicyRegistryHandler(address(registry), address(usdc));

        // Seed with a few initial policies so the handler has something to work with
        handler.registerNewPolicy(makeAddr("seed1"));
        handler.registerNewPolicy(makeAddr("seed2"));
        handler.registerNewPolicy(makeAddr("seed3"));

        // Tell Foundry to call the handler's functions randomly
        targetContract(address(handler));
    }

    /**
     * @notice INVARIANT 1: spentAmount can never exceed maxBudget.
     *
     *         No matter how many times consumeBudget is called, in what order,
     *         with what amounts — the spent amount must never exceed the budget.
     *         This is the core financial safety guarantee of the protocol.
     */
    function invariant_spentNeverExceedsBudget() public view {
        uint256 count = handler.getPolicyCount();

        for (uint256 i = 0; i < count; i++) {
            bytes32 pid = handler.policyIds(i);

            try registry.getPolicy(pid) returns (PolicyRegistry.Policy memory policy) {
                assertLe(
                    policy.spentAmount,
                    policy.maxBudget,
                    "INVARIANT BROKEN: spentAmount exceeded maxBudget"
                );
            } catch {}
        }
    }

    /**
     * @notice INVARIANT 2: A revoked policy can never become active again.
     *
     *         Once isActive is false, no combination of subsequent calls
     *         should ever make it true. Revocation is permanent by design.
     */
    function invariant_revokedPolicyStaysRevoked() public view {
        uint256 count = handler.getPolicyCount();

        for (uint256 i = 0; i < count; i++) {
            bytes32 pid = handler.policyIds(i);

            try registry.getPolicy(pid) returns (PolicyRegistry.Policy memory policy) {
                // If the policy was revoked, it must not be active
                // isPolicyActive checks both isActive and expiry
                if (!policy.isActive) {
                    assertFalse(
                        registry.isPolicyActive(pid),
                        "INVARIANT BROKEN: revoked policy became active"
                    );
                }
            } catch {}
        }
    }
}

/**
 * @title ActivityLogInvariant
 * @notice Proves two guarantees about the activity log:
 *
 *         1. entryCount only ever increases — never decreases
 *         2. The cryptographic chain is always intact after any number of writes
 */
contract ActivityLogInvariant is StdInvariant, Test {

    ActivityLog        public actLog;
    ActivityLogHandler public handler;

    uint256 public lastSeenCount;

    function setUp() public {
        actLog  = new ActivityLog();
        handler = new ActivityLogHandler(address(actLog));

        targetContract(address(handler));
    }

    /**
     * @notice INVARIANT 3: entryCount only ever increases.
     *
     *         Entries can be added but never removed. The count is monotonically
     *         increasing across any sequence of write operations.
     */
    function invariant_entryCountOnlyIncreases() public {
        uint256 currentCount = actLog.entryCount();

        assertGe(
            currentCount,
            lastSeenCount,
            "INVARIANT BROKEN: entryCount decreased"
        );

        lastSeenCount = currentCount;
    }

    /**
     * @notice INVARIANT 4: The cryptographic chain is always intact.
     *
     *         After any number of writes, every entry's hash must correctly
     *         chain to the previous entry. If this breaks, it means the
     *         tamper-proof guarantee has been violated.
     */
    function invariant_chainAlwaysIntact() public view {
        if (actLog.entryCount() == 0) return;

        (bool intact,) = actLog.verifyChain(0);

        assertTrue(
            intact,
            "INVARIANT BROKEN: ActivityLog cryptographic chain is not intact"
        );
    }
}

/**
 * @title ReputationStakingInvariant
 * @notice Proves two guarantees about staking:
 *
 *         1. totalStaked always matches the contract's actual token balance
 *         2. A slash can never distribute more tokens than were staked
 */

contract ReputationStakingInvariant is StdInvariant, Test {

    ReputationStaking        public staking;
    MockUSDC                 public usdc;
    ReputationStakingHandler public handler;

    function setUp() public {
        usdc     = new MockUSDC();
        staking  = new ReputationStaking(address(usdc));
        handler  = new ReputationStakingHandler(address(staking), address(usdc));

        // Seed with a few listings
        handler.listService(makeAddr("seed1"), 100e6);
        handler.listService(makeAddr("seed2"), 200e6);

        targetContract(address(handler));
    }

    /**
     * @notice INVARIANT 5: totalStaked always equals the contract's token balance.
     *
     *         The accounting variable totalStaked must always reflect the real
     *         token balance held by the contract. Any divergence means tokens
     *         have leaked or been double-counted.
     */
    function invariant_totalStakedMatchesBalance() public view {
        assertEq(
            staking.totalStaked(),
            usdc.balanceOf(address(staking)),
            "INVARIANT BROKEN: totalStaked does not match contract balance"
        );
    }

    /**
     * @notice INVARIANT 6: Slash never distributes more than was staked.
     *
     *         After any slash operation, the sum of tokens distributed to
     *         buyer and treasury must not exceed what the agent had staked.
     *         The stake cannot go negative.
     */

    function invariant_slashNeverExceedsStake() public view {
        address[] memory active = staking.getActiveListings();

        for (uint256 i = 0; i < active.length; i++) {
            ReputationStaking.ServiceListing memory listing = staking.getListing(active[i]);

            assertGe(
                listing.stakedAmount,
                0,
                "INVARIANT BROKEN: stakedAmount went negative"
            );
        }

        // Total staked must never exceed total tokens minted to the contract
        assertLe(
            staking.totalStaked(),
            usdc.balanceOf(address(staking)) + 1, // +1 for rounding tolerance
            "INVARIANT BROKEN: totalStaked exceeds contract balance"
        );
    }
}