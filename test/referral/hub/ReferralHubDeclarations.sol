// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Storage, constants, events and errors of the referral hub, shared by
 * the hub diamond and every facet. Sources are keyed by bytes32 because the
 * CREATE3 vaults share one address across chains, and claimables are kept
 * per source chain. Week W's ladder inputs live in W's own bucket: the
 * referred averages and the self averages, each summed over the sources.
 * `sourceWeekOf[source][referrer][week]` holds a source's reported referred
 * average for the week in the low half and the commission units already
 * paid for it in the high half; `sourceSelfOf[source][referrer][week]` holds
 * the source's reported self average; both are merged by maximum, so a
 * source's report for a closed week only rises.
 * `weekInputsOf[referrer][week]` holds the referred sum in the low half and
 * the self sum in the high half. An average is at most three 80-bit lanes
 * over one week by construction, so no half can overflow.
 * `sourceChainIdOf` is the chain a source credits, written at its first
 * delivery; `sourceListedFor` guards the per-referrer source list.
 * `sourceSystemOf` tags a source with its vault system for indexers and the
 * umbrella's accounting; pricing no longer reads it, and it freezes once
 * the source delivered. MAX_SYSTEMS is permanent.
 * `leverChangeQueuedAt` holds the proposal time of a queued master lever
 * call, keyed by the hash of its canonical calldata (the setter rebuilds
 * it from its decoded arguments, so trailing bytes never make a second
 * usable key): a proposal is accepted only after `finalizeSetup`, and a
 * grant (allowing a reporter, setting the router, setting a flush or
 * designation source to a chain id) runs only as that exact call at least
 * SELECTOR_CHANGE_DELAY after its proposal, the delay the vault side
 * `payoutHub` pointer and every hub selector change already wait, and each
 * proposal runs once; a revocation never waits.
 * `elevationWindowsOf[referrer]` is the referrer's elevation history: one
 * word per window, the from week in the low half and the until week in
 * the high half (zero while open), at most MAX_ELEVATION_WINDOWS words;
 * `elevatedFromWeek` and `elevatedUntilWeek` mirror the latest window.
 * A week is priced as at the cap when any window holds it, so a grant
 * after an end never changes the verdict of an earlier window.
 * Threat model: only
 * master-registered sources write, every write is a maximum or a cursor
 * advance, and a cell is paid at most its cumulative due, so a replayed,
 * reordered or duplicated delivery can never pay twice. The state the
 * buckets retired (the score aggregates, checkpoints, freshness words,
 * report retention and the remainder park) stays declared and unused, so
 * the layout only ever grows at its tail.
 */
abstract contract ReferralHubDeclarations is OwnableMaster {

    uint256 internal constant WEEK_HALF_SHIFT = 128;

    uint256 internal constant WEEK_HALF_MASK = (1 << 128) - 1;

    uint256 internal constant RATE_MASK = (1 << 16) - 1;

    uint256 internal constant RATE_Y2_SHIFT = 16;

    uint256 internal constant RATE_M_SHIFT = 32;

    uint256 internal constant GAP_WEEK_MASK = (1 << 32) - 1;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant PAYOUT_STAMP_SHIFT = 8;

    uint256 internal constant DESIGNATION_VERSION = 2;

    uint256 internal constant DESIGNATION_PAYLOAD_LENGTH = 160;

    uint256 internal constant MAX_DESIGNATION_FUTURE_DRIFT = 1 hours;

    uint256 internal constant MAX_BOT_SHARE_BPS = 2_000;

    uint256 internal constant MAX_SCHEDULE_HORIZON_WEEKS = 520;

    struct RateTable {
        uint32 effectiveFromWeek;
        uint16 capBps;
        uint16 y2RateBps;
        uint16 mRateBps;
        uint16 botShareBps;
        uint16[8] tierBps;
        uint96[8] thresholds;
    }

    // ---- Retired score state (unused, kept for the layout) ----

    mapping(address => uint256) internal globalReferredScore;

    mapping(address => uint256) internal globalSelfScore;

    mapping(address => uint256[]) internal referrerCheckpoints;

    mapping(bytes32 => mapping(address => uint256)) internal lastSourceReport;

    // ---- The sources a referrer was ever reported from (and a retired report word) ----

    mapping(address => bytes32[]) internal sourcesOf;

    mapping(bytes32 => mapping(address => uint256)) internal previousSourceReport;

    // ---- Week-versioned rate tables ----

    RateTable[] internal rateTables;

    // ---- Intake cursors + claimables ----

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) internal paidCursor;

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) internal paidRemainder;

    mapping(uint256 => mapping(address => uint256)) public claimable;

    uint256 public totalAccrued;

    uint256 public totalClaimed;

    uint256 public totalPayable;

    // ---- Access + policy knobs ----

    mapping(address => bool) public allowedReporter;

    // Retired with the dwell-min schedule.
    uint256[] internal dwellMinLog;

    mapping(uint256 => mapping(address => address)) internal payoutAddress;

    mapping(uint256 => mapping(address => uint256)) public payoutStamp;

    // ---- Cross-chain flush mailbox ----

    address public ccipRouter;

    mapping(uint64 => mapping(address => uint256)) public flushSourceChainId;

    mapping(uint64 => mapping(address => uint256)) public designationSourceChainId;

    mapping(bytes32 => bytes32) public flushCommitment;

    // Retired with the per-envelope score report.
    mapping(bytes32 => mapping(address => uint256)) internal appliedScoreStamp;

    // ---- Diamond proxy ----

    IERC20 public USD_TOKEN;

    mapping(bytes4 => address) public selectorToFacet;

    mapping(bytes4 => address) public proposedSelectorFacet;

    mapping(bytes4 => uint256) public selectorChangeQueuedAt;

    bool public initialized;

    uint256 internal constant SELECTOR_CHANGE_DELAY = 3 days;

    // ---- Courier share cap ----

    uint256 public delivererShareCap;

    // ---- Vault systems ----

    uint256 public constant MAX_SYSTEMS = 8;

    mapping(bytes32 => uint256) public sourceSystemOf;

    // ---- Week buckets ----

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) internal sourceWeekOf;

    mapping(address => mapping(uint256 => uint256)) internal weekInputsOf;

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) internal sourceSelfOf;

    mapping(bytes32 => uint256) public sourceChainIdOf;

    mapping(address => mapping(bytes32 => bool)) internal sourceListedFor;

    // ---- Lever timelock ----

    mapping(bytes32 => uint256) public leverChangeQueuedAt;

    // ---- Elevation (a referrer priced as at the cap for a week window) ----

    mapping(address => uint256) public elevatedFromWeek;

    mapping(address => uint256) public elevatedUntilWeek;

    // ---- Elevation window history (every window keeps its verdict) ----

    uint256 internal constant MAX_ELEVATION_WINDOWS = 8;

    mapping(address => uint256[]) internal elevationWindowsOf;

    // ---- Events ----

    event RateTableScheduled(
        uint256 indexed index,
        uint256 effectiveFromWeek
    );

    event CrumbPriced(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        address deliverer,
        uint256 y1Increment,
        uint256 y2Increment,
        uint256 mIncrement,
        uint256 paid
    );

    event GapPriced(
        bytes32 indexed source,
        address indexed referrer,
        address deliverer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 paid
    );

    event CrumbLaneRegression(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 laneKind,
        uint256 incoming,
        uint256 cursor
    );

    event ReporterAllowedSet(
        address indexed reporter,
        bool allowed
    );

    event PayoutAddressSet(
        uint256 indexed chainId,
        address indexed owner,
        address indexed payout
    );

    event PayoutBacklogReleased(
        uint256 indexed chainId,
        address indexed owner,
        uint256 amount
    );

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    event CcipRouterSet(
        address indexed router
    );

    event FlushSourceSet(
        uint64 indexed chainSelector,
        address indexed vault,
        uint256 chainId
    );

    event DesignationSourceSet(
        uint64 indexed chainSelector,
        address indexed registry,
        uint256 chainId
    );

    event FlushReceived(
        bytes32 indexed messageId,
        uint64 indexed srcChainSelector,
        address indexed vault,
        uint256 chainId,
        bytes payload
    );

    event FlushApplied(
        bytes32 indexed messageId,
        bytes32 indexed source,
        uint256 entryCount
    );

    event DesignationPushReceived(
        uint64 indexed srcChainSelector,
        uint256 indexed chainId,
        address indexed owner
    );

    event DelivererSharePaid(
        uint256 indexed chainId,
        address indexed deliverer,
        address indexed referrer,
        bytes32 messageId,
        uint256 amount
    );

    event FlushDesignationSkipped(
        uint256 indexed chainId,
        address indexed owner,
        uint256 stamp
    );

    event SetupFinalized();

    event ReferrerElevated(
        address indexed referrer,
        uint256 fromWeek
    );

    event ReferrerElevationEnded(
        address indexed referrer,
        uint256 untilWeek
    );

    event SelectorProposed(
        bytes4 indexed selector,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorsProposed(
        bytes4[] selectors,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorUpdated(
        bytes4 indexed selector,
        address indexed facet
    );

    event SelectorProposalCancelled(
        bytes4 indexed selector
    );

    event DelivererShareCapSet(
        uint256 cap
    );

    event SourceListed(
        address indexed referrer,
        bytes32 indexed source,
        uint256 chainId
    );

    event WeekReferredReported(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 referredAverage
    );

    event WeekSelfReported(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 selfAverage
    );

    event WeekRatesRaised(
        address indexed referrer,
        uint256 indexed week
    );

    event WeekToppedUp(
        bytes32 indexed source,
        address indexed referrer,
        uint256 indexed week,
        uint256 amount
    );

    event SourceSystemSet(
        bytes32 indexed source,
        uint256 systemId
    );

    event LeverChangeProposed(
        bytes32 indexed changeHash,
        bytes call,
        uint256 executableAt
    );

    event LeverChangeCancelled(
        bytes32 indexed changeHash
    );

    // ---- Errors ----

    error ZeroAddress();

    error NotReporter();

    error FutureWeek();

    error WeekNotClosed();

    error InvalidSelfRun();

    error LengthMismatch();

    error BatchTooLarge();

    error InvalidCrumbWord();

    error InvalidGapRecord();

    error InvalidWindow();

    error TableNotFuture();

    error TableNotOrdered();

    error InvalidRateTable();

    error NothingClaimable();

    error PotDry();

    error NotPayoutAuthorized();

    error NotCcipRouter();

    error UnknownFlushSource();

    error FlushAlreadyReceived();

    error UnknownFlushCommitment();

    error FlushPayloadInvalid();

    error BotShareTooHigh();

    error PayoutNotDesignated();

    error SourceOnHubChain();

    error WeekOutOfRange();

    error SourceAlreadySet();

    error SystemOutOfRange();

    error LeverChangeNotQueued();

    error LeverTimelockNotElapsed();

    error SetupNotFinalized();

    error ElevationNotFuture();

    error AlreadyElevated();

    error NotElevated();

    error ElevationHistoryFull();

    /**
     * @dev Consumes the queued lever change a grant runs as. Before
     * `finalizeSetup` the grant runs at once (the deploy wiring needs no
     * proposal); afterwards only the exact call master queued at least
     * SELECTOR_CHANGE_DELAY earlier passes, and the entry is cleared so
     * each proposal runs once.
     */
    function _consumeLeverChange(
        bytes32 _changeHash
    )
        internal
    {
        if (initialized == false) {
            return;
        }

        uint256 queuedAt = leverChangeQueuedAt[_changeHash];

        require(
            queuedAt > 0,
            LeverChangeNotQueued()
        );

        require(
            block.timestamp >= queuedAt + SELECTOR_CHANGE_DELAY,
            LeverTimelockNotElapsed()
        );

        leverChangeQueuedAt[_changeHash] = 0;
    }

    /**
     * @dev The launch ladder: thresholds 5k to 1M USD, tiers 1 to 8
     * percent, cap 1_000 bps, year-2 500 bps, mature 100 bps, courier share
     * 500 bps.
     */
    function _seedGenesisRateTable()
        internal
    {
        rateTables.push(
            RateTable({
                effectiveFromWeek: 0,
                capBps: 1_000,
                y2RateBps: 500,
                mRateBps: 100,
                botShareBps: 500,
                tierBps: [
                    uint16(100),
                    200,
                    300,
                    400,
                    500,
                    600,
                    700,
                    800
                ],
                thresholds: [
                    uint96(5_000 * 1e6),
                    10_000 * 1e6,
                    20_000 * 1e6,
                    30_000 * 1e6,
                    50_000 * 1e6,
                    100_000 * 1e6,
                    500_000 * 1e6,
                    1_000_000 * 1e6
                ]
            })
        );

        emit RateTableScheduled(
            0,
            0
        );
    }
}
