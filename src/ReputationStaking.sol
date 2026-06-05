// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ReputationStaking
 * @author Arbit Protocol
 * @notice Agents stake USDC to list services on the Arbit marketplace.
 *         That stake is their skin in the game. Deliver good service and
 *         the stake stays intact. Behave maliciously or fail to perform
 *         and the stake gets slashed — funds go to the harmed buyer and
 *         the protocol treasury.
 *
 * @dev Security invariants:
 *      1. An agent cannot list without meeting the minimum stake
 *      2. Stake can only be withdrawn when the agent is not listed
 *      3. Only the slash authority can slash a stake
 *      4. Slashed amount never exceeds the staked amount
 *      5. Treasury address can only be set once
 *      6. Slash authority can only be set once
 *
 * @custom:security-contact security@arbitprotocol.xyz
 */
contract ReputationStaking is ReentrancyGuard {

    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddressNotAllowed();
    error ZeroAmountNotAllowed();
    error MinimumStakeNotMet(uint256 provided, uint256 minimum);
    error AgentAlreadyListed(address agent);
    error AgentNotListed(address agent);
    error InsufficientStake(uint256 available, uint256 required);
    error CannotWithdrawWhileListed(address agent);
    error SlashExceedsStake(uint256 slashAmount, uint256 stakedAmount);
    error OnlySlashAuthorityCanDoThis(address caller, address authority);
    error OnlyAgentCanDoThis(address caller, address agent);
    error SlashAuthorityAlreadySet();
    error TreasuryAlreadySet();
    error SetupIncomplete();
    error ServicePriceTooLow();
    error InvalidCategory(uint8 category);
    error StakeAmountMustBePositive();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    // The minimum USDC a seller must stake to list a service
    // Set at 100 USDC — enough to deter spam but not prohibitive
    uint256 public constant MINIMUM_STAKE = 100e6;

    // What percentage of a slash goes to the harmed buyer
    // The rest goes to the treasury
    // 70% to buyer, 30% to treasury
    uint256 public constant BUYER_SLASH_SHARE_BPS  = 7000;
    uint256 public constant BASIS_POINTS            = 10000;

    // Service categories — must match ACTION types in PolicyRegistry
    uint8 public constant CATEGORY_DATA_FEED   = 0;
    uint8 public constant CATEGORY_DEX_SWAP    = 1;
    uint8 public constant CATEGORY_LENDING     = 2;
    uint8 public constant CATEGORY_EXECUTION   = 3;
    uint8 public constant CATEGORY_YIELD       = 4;
    uint8 public constant MAX_CATEGORY         = 4;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum ListingStatus { Unlisted, Active, Suspended }

    struct ServiceListing {
        // The agent providing this service
        address agent;

        // Price per call in USDC
        uint256 pricePerCall;

        // Which category this service falls under
        uint8 category;

        // Current listing status
        ListingStatus status;

        // How much USDC this agent has staked
        uint256 stakedAmount;

        // Total calls completed successfully — used for reputation scoring
        uint256 successfulCalls;

        // Total calls that were disputed or failed
        uint256 failedCalls;

        // When this listing was first created
        uint256 listedAt;

        // A short description of what this service does
        bytes32 description;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    // The USDC token used for staking
    IERC20 public immutable stakingToken;

    // Where slash proceeds for the protocol go
    address public treasury;
    bool    private treasurySet;

    // The only address that can slash stakes — set to SentinelGate after deploy
    address public slashAuthority;
    bool    private slashAuthoritySet;

    // All service listings indexed by agent address
    mapping(address => ServiceListing) private listings;

    // All agents who have ever listed — for enumeration
    address[] private listedAgents;

    // Tracks whether an address has been added to listedAgents array
    mapping(address => bool) private everListed;

    // Total USDC held in this contract as stakes
    uint256 public totalStaked;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ServiceListed(
        address indexed agent,
        uint8 category,
        uint256 pricePerCall,
        uint256 stakedAmount
    );

    event ServiceDelisted(
        address indexed agent,
        uint256 stakeReturned
    );

    event StakeIncreased(
        address indexed agent,
        uint256 addedAmount,
        uint256 newTotal
    );

    event StakeSlashed(
        address indexed agent,
        address indexed buyer,
        uint256 slashedAmount,
        uint256 buyerReceived,
        uint256 treasuryReceived
    );

    event ServiceSuspended(
        address indexed agent,
        string  reason
    );

    event ServiceReinstated(
        address indexed agent
    );

    event CallRecorded(
        address indexed agent,
        bool    success
    );

    event SlashAuthoritySet(address indexed authority);
    event TreasurySet(address indexed treasury);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _stakingToken) {
        if (_stakingToken == address(0)) revert ZeroAddressNotAllowed();
        stakingToken = IERC20(_stakingToken);
    }

    // -------------------------------------------------------------------------
    // One-time setup
    // -------------------------------------------------------------------------

    function setSlashAuthority(address _authority) external {
        if (slashAuthoritySet) revert SlashAuthorityAlreadySet();
        if (_authority == address(0)) revert ZeroAddressNotAllowed();
        slashAuthority = _authority;
        slashAuthoritySet = true;
        emit SlashAuthoritySet(_authority);
    }

    function setTreasury(address _treasury) external {
        if (treasurySet) revert TreasuryAlreadySet();
        if (_treasury == address(0)) revert ZeroAddressNotAllowed();
        treasury = _treasury;
        treasurySet = true;
        emit TreasurySet(_treasury);
    }

    modifier onlySlashAuthority() {
        if (msg.sender != slashAuthority)
            revert OnlySlashAuthorityCanDoThis(msg.sender, slashAuthority);
        _;
    }

    modifier setupComplete() {
        if (!slashAuthoritySet || !treasurySet)
            revert SetupIncomplete();
        _;
    }

    // -------------------------------------------------------------------------
    // Listing management
    // -------------------------------------------------------------------------

    /**
     * @notice List a service on the marketplace by staking USDC.
     * @dev The agent must approve this contract to spend their USDC first.
     *      Stake is locked for as long as the listing is active.
     */
    function listService(
        uint256 stakeAmount,
        uint256 pricePerCall,
        uint8   category,
        bytes32 description
    )
        external
        nonReentrant
        setupComplete
    {
        if (stakeAmount < MINIMUM_STAKE)
            revert MinimumStakeNotMet(stakeAmount, MINIMUM_STAKE);

        if (pricePerCall == 0)
            revert ServicePriceTooLow();

        if (category > MAX_CATEGORY)
            revert InvalidCategory(category);

        if (listings[msg.sender].status == ListingStatus.Active)
            revert AgentAlreadyListed(msg.sender);

        // Pull the stake from the agent
        stakingToken.safeTransferFrom(msg.sender, address(this), stakeAmount);
        totalStaked += stakeAmount;

        listings[msg.sender] = ServiceListing({
            agent:          msg.sender,
            pricePerCall:   pricePerCall,
            category:       category,
            status:         ListingStatus.Active,
            stakedAmount:   stakeAmount,
            successfulCalls: 0,
            failedCalls:    0,
            listedAt:       block.timestamp,
            description:    description
        });

        if (!everListed[msg.sender]) {
            listedAgents.push(msg.sender);
            everListed[msg.sender] = true;
        }

        emit ServiceListed(msg.sender, category, pricePerCall, stakeAmount);
    }

    /**
     * @notice Delist a service and withdraw the full stake.
     * @dev Only the agent themselves can delist. Suspended agents
     *      cannot delist — the slash authority must reinstate first.
     */
    function delistService() external nonReentrant {
        ServiceListing storage listing = listings[msg.sender];

        if (listing.status != ListingStatus.Active)
            revert AgentNotListed(msg.sender);

        uint256 stakeToReturn = listing.stakedAmount;

        // Clear the listing before transferring to prevent reentrancy
        listing.status      = ListingStatus.Unlisted;
        listing.stakedAmount = 0;
        totalStaked -= stakeToReturn;

        stakingToken.safeTransfer(msg.sender, stakeToReturn);

        emit ServiceDelisted(msg.sender, stakeToReturn);
    }

    /**
     * @notice Add more stake to an active listing.
     * @dev More stake signals higher commitment and improves reputation score.
     */
    function increaseStake(uint256 additionalAmount)
        external
        nonReentrant
    {
        if (additionalAmount == 0) revert StakeAmountMustBePositive();

        ServiceListing storage listing = listings[msg.sender];
        if (listing.status != ListingStatus.Active)
            revert AgentNotListed(msg.sender);

        stakingToken.safeTransferFrom(msg.sender, address(this), additionalAmount);
        listing.stakedAmount += additionalAmount;
        totalStaked += additionalAmount;

        emit StakeIncreased(msg.sender, additionalAmount, listing.stakedAmount);
    }

    // -------------------------------------------------------------------------
    // Slash mechanism
    // -------------------------------------------------------------------------

    /**
     * @notice Slash an agent's stake for malicious or failed service.
     * @dev Only the slash authority (SentinelGate) can call this.
     *      70% goes to the harmed buyer, 30% to the protocol treasury.
     *      If the slash amount exceeds the stake, we slash everything.
     *
     * @param agent       The misbehaving agent.
     * @param buyer       Who was harmed — receives 70% of the slash.
     * @param slashAmount How much to slash.
     * @param reason      Why this slash is happening.
     */
    function slashStake(
        address agent,
        address buyer,
        uint256 slashAmount,
        string calldata reason
    )
        external
        nonReentrant
        onlySlashAuthority
    {
        if (agent == address(0)) revert ZeroAddressNotAllowed();
        if (buyer == address(0)) revert ZeroAddressNotAllowed();
        if (slashAmount == 0)    revert ZeroAmountNotAllowed();

        ServiceListing storage listing = listings[agent];

        // We can slash both active and suspended agents
        // but not agents who have never listed
        if (listing.stakedAmount == 0)
            revert InsufficientStake(0, slashAmount);

        // Cap the slash at whatever is staked — never go negative
        uint256 actualSlash = slashAmount > listing.stakedAmount
            ? listing.stakedAmount
            : slashAmount;

        // Calculate the split
        uint256 buyerAmount    = (actualSlash * BUYER_SLASH_SHARE_BPS) / BASIS_POINTS;
        uint256 treasuryAmount = actualSlash - buyerAmount;

        // Update state before transfers
        listing.stakedAmount -= actualSlash;
        listing.status        = ListingStatus.Suspended;
        totalStaked          -= actualSlash;

        // Transfer to buyer
        if (buyerAmount > 0) {
            stakingToken.safeTransfer(buyer, buyerAmount);
        }

        // Transfer to treasury
        if (treasuryAmount > 0) {
            stakingToken.safeTransfer(treasury, treasuryAmount);
        }

        emit StakeSlashed(agent, buyer, actualSlash, buyerAmount, treasuryAmount);
        emit ServiceSuspended(agent, reason);
    }

    // -------------------------------------------------------------------------
    // Call recording — called by SentinelGate after marketplace transactions
    // -------------------------------------------------------------------------

    /**
     * @notice Record the outcome of a service call.
     * @dev Updates the agent's success/failure counters which feed
     *      into the reputation score calculation.
     */
    function recordCall(address agent, bool success)
        external
        onlySlashAuthority
    {
        ServiceListing storage listing = listings[agent];
        if (listing.status == ListingStatus.Unlisted)
            revert AgentNotListed(agent);

        if (success) {
            listing.successfulCalls++;
        } else {
            listing.failedCalls++;
        }

        emit CallRecorded(agent, success);
    }

    /**
     * @notice Reinstate a suspended agent after they have topped up their stake.
     * @dev Only the slash authority can reinstate — prevents self-reinstatement.
     */
    function reinstateService(address agent)
        external
        onlySlashAuthority
    {
        ServiceListing storage listing = listings[agent];
        if (listing.status != ListingStatus.Suspended)
            revert AgentNotListed(agent);
        if (listing.stakedAmount < MINIMUM_STAKE)
            revert MinimumStakeNotMet(listing.stakedAmount, MINIMUM_STAKE);

        listing.status = ListingStatus.Active;
        emit ServiceReinstated(agent);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function getListing(address agent)
        external
        view
        returns (ServiceListing memory)
    {
        return listings[agent];
    }

    function isListed(address agent) external view returns (bool) {
        return listings[agent].status == ListingStatus.Active; // slither-disable-next-line incorrect-equality
    }

    function getReputationScore(address agent)
        external
        view
        returns (uint8 score)
    {
        ServiceListing storage listing = listings[agent];

        if (listing.status == ListingStatus.Unlisted) return 0;

        uint256 total = listing.successfulCalls + listing.failedCalls;

        if (total == 0) {
            // New listing with no call history
            // Base score determined by stake size relative to minimum
            // More stake = higher base trust, capped at 60
            // Multiply before dividing to avoid precision loss
            uint256 baseScore = (listing.stakedAmount * 10) / MINIMUM_STAKE;
            return uint8(baseScore > 60 ? 60 : baseScore);
        }

        // Score = (successful / total) * 100, adjusted for stake size
        uint256 successRate = (listing.successfulCalls * 100) / total;

        // Suspended agents take a 20 point penalty
        if (listing.status == ListingStatus.Suspended) {
            successRate = successRate > 20 ? successRate - 20 : 0;
        }

        return uint8(successRate > 100 ? 100 : successRate);
    }

    function getActiveListings()
        external
        view
        returns (address[] memory active)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < listedAgents.length; i++) {
            if (listings[listedAgents[i]].status == ListingStatus.Active) { // slither-disable-line incorrect-equality
                count++;
            }
        }

        active = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < listedAgents.length; i++) {
            if (listings[listedAgents[i]].status == ListingStatus.Active) { // slither-disable-line incorrect-equality
                active[idx++] = listedAgents[i];
            }
        }
    }

    function getTotalListings() external view returns (uint256) {
        return listedAgents.length;
    }
}
