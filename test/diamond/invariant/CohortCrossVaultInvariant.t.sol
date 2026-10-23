// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../referral/registry/ReferralRegistry.sol";

import {TwoVaultCohortHarness, TwoVaultMockUSD} from "../utils/TwoVaultCohortHarness.sol";

/**
 * @dev Drives TWO fully wired cohort diamonds sharing one
 * {ReferralRegistry} through bounded random deposits, transfers,
 * same-chain moves in both directions, queue join/switch/leave on
 * vault A, pokes, advances, three warp granularities and referrer
 * flips through the REAL registry: an allowlisted vault relays a
 * strictly lower sync key that names the other referrer, the registry
 * marks both tracked vaults, and the permissionless poke relocates
 * the mover's book credit under the relocation rule (newest-first
 * out of the old book, every taken slot landed at the same slot and
 * ring of the new one). The merge action also sends keys the registry must ignore (a
 * higher key naming the other referrer) and same-referrer lowerings,
 * which must move no referrer and mark no vault. The closed actor
 * set: A1/A2 referees whose registry referrer alternates between REF
 * and REF2 as the flips land, U unreferred, OUTSIDER a pure sink.
 * Moves run WITHOUT try/catch (a move must never revert on recorder
 * grounds, and every law runs with fail-on-revert so a reverting
 * action fails the campaign instead of being dropped) and each move
 * checks the step-level netting property: a referred mover's move
 * changes the GLOBAL book sum (both referrers on both vaults) by
 * exactly the mover's pre-existing lazy deficits on BOTH vaults (the
 * source's pre-burn sync and the destination's pre-mint sync each
 * clamp sale-like); the moved amount itself relocates without loss;
 * an unreferred move never touches any book. A violation increments
 * a sticky counter instead of reverting; the invariants require
 * every counter to stay zero. Ghost accounting: `ghostCreditedTotal`
 * accumulates every referred credit ever granted, bounding the
 * global book from above; per-vault, per-referrer ghost crumb
 * snapshots freeze each finalized week's crumb word the moment its
 * settle cursor passes it; the move step also checks the tracked
 * twin of the netting equality for EVERY actor, the unreferred one
 * included, in the sticky `ghostTrackedViolations`.
 *
 * The flip laws are checked step-level inside the poke, per vault
 * that migrates, against pre-states the handler SETTLES ITSELF: both
 * books are captured raw, and the handler replays the recorder's
 * settle on them, a crumb segment per crossed week boundary at the
 * lanes then standing and the rotation rule at each boundary (the
 * graduating ring-2 slot to the mature lane, the ring-1 slot to ring
 * 2), at most 104 boundaries per settle and then the gap, which
 * writes no crumb and rotates nothing, so the real books stay
 * unsettled when the poke runs and the recorder's own settle inside
 * it is exercised, while the oracle is independent of
 * `_rotateCohort` and `_settleBookCohortTo`. The replay carries no
 * disarm-span term: the handler's only disarm, inside
 * `flipSplitAndPoke`, re-arms in the same second, which stamps an
 * empty span, so the full segment length the oracle replays is
 * exactly what the engine records. The flip entrypoint
 * drains a third party parked on the vault before it migrates, and
 * the oracle nets that drain instead of avoiding it: the parked
 * party's book is settled to the park instant and then walked
 * newest-first, anchored at the book's settle cursor, for the
 * parked party's charge (its lazy deficit capped at its attributed
 * contribution), before the flip's own settle and walk; after the
 * poke the park slot must be clear and the parked party's tracked
 * contribution must equal its balance when it held a deficit and
 * never exceed it otherwise (a sticky drain counter, reported under
 * FL1). A parked mover is resolved the same way against its own old
 * book at its park instant (the old book settled to the park, the
 * charge walked there, the park cleared) before the relocation, so
 * the oracle then skips the migration's own clamp walk for it. FL1,
 * the two books' lane totals are conserved across the
 * poke net of the clamp charge the migration takes on the mover's
 * lazy deficit and of the drained party's charge; FL2, the old book
 * afterwards equals the drain walk (when the drain hit it), then a
 * sale walk of the clamp charge plus the mover's post-clamp
 * attributed amount over the settled pre-state (the handler's own
 * newest-first walk over the captured rings, ring 1 then ring 2
 * then the mature lane), and the new book's deltas against its
 * drained and settled pre-state are exactly the walk's takes; FL3,
 * every slot the walk took lands at the same slot and ring with
 * exactly the walk's per-slot take, and the mature take on the mature
 * lane; FL4, the amount relocated equals the mover's
 * post-clamp attributed contribution and the tracked and attributed
 * counters move only by that clamp; FL6, a poke on armed vaults
 * clears every marker, and a second poke afterwards calls no vault
 * (no migration, deferral, clear or applied-flip log) and leaves
 * every book bit-identical; FL10, every crumb word from each book's
 * settle week to the poke week equals its pre-poke word plus the
 * replayed lanes times the seconds of each replayed segment (the
 * settle week's partial word as the base, later weeks from zero, a
 * week no segment touched unchanged), and each book's settle cursor
 * ends where the replay put it. The crumb replay leaves out the
 * saturating add of the crumb lanes: each crumb accumulates at most
 * one week of seconds per settle, so lanes of at most about 2.4e11
 * units times 604_800 seconds stay far below 2 ** 80. Every exact
 * check is skipped, and counted, when the poke emitted a
 * {CohortLaneSaturated} clip, the documented fail-soft domain. The
 * move laws keep the rotated snapshot: the rotation rule applied for
 * every boundary the settle cursor has not crossed, compared only
 * when the move settled the book. A split-marker action disarms vault B
 * for the poke so its migration defers while vault A's lands whenever
 * the mover holds attributed contribution on vault B (a disarmed vault
 * holding none consumes the marker with its books and the mover's
 * counters unchanged, counted apart), which makes the two vaults name
 * different referrers for the mover until the next poke; a move in
 * either direction then relocates between the two referrers, and FL8
 * checks on every pre-synced move that the destination's ring delta
 * at every slot never exceeds the source's reduction at that slot and
 * ring.
 *
 * FL9, the age-dominance law, reads a ghost ledger of each referee's
 * OWN lots with the ages the rule assigns: a lot per referred credit
 * at its credit week (recorded per deposit after reconciling any
 * clamp inside the same call), reduced newest-first by every
 * observed attributed decrease; on a flip the mover's lots on that
 * vault are replaced by the relocated takes at their own credit weeks
 * (each taken ring-1 slot's week, a ring-2 slot 52 weeks earlier, the
 * mature take 104 weeks back, from the handler's own walk); on a move the carried slice is re-derived by walking the
 * rotated source snapshot newest-first for the parked charge (only
 * when the parked referee shares the source book, since another
 * book's drain never touches this walk), the sale-like part of the
 * clamp and then the carried part, and the carried takes land in
 * the mover's destination lots at their own credit weeks (the move's
 * charge follows the engine's split: the deficit is the tracked stake
 * above what is still held after the burn, so an untracked balance, for
 * example shares an unfilled queue leave returned, absorbs part of the
 * burn), after the
 * destination's own pre-mint clamp was
 * charged newest-first. For every book on every vault, the
 * pooled mass younger than each tier boundary, read at the book's
 * own settle week, never exceeds the same-age mass of its members'
 * lots, membership following `effectiveReferrerOf` (a standing marker
 * keeps the mover's lots with the old book, where the credit still
 * sits). Taking newest-first from both the pool and the member lots
 * keeps the pooled young mass below the ledger's at every tier, and
 * credits and landings add equal mass at equal ages on both sides,
 * so the law is tight up to a lane saturation clip, where the
 * relocated amount is recorded as a fresh lot instead.
 */
contract CohortCrossVaultHandler is Test {

    struct BookSnap {
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint64[52] ring1;
        uint64[52] ring2;
    }

    struct Lot {
        uint256 week;
        uint256 amount;
    }

    struct CrumbTrace {
        uint256 startWeek;
        uint256 cursor;
        uint256 before;
        uint256[] year1Seconds;
        uint256[] year2Seconds;
        uint256[] matureSeconds;
        bool[] touched;
        uint256 outOfRange;
    }

    struct FlipSide {
        address old;
        bool expectMigration;
        bool expectClear;
        BookSnap oldRaw;
        BookSnap newRaw;
        uint256 trackedBefore;
        uint256 heldBefore;
        uint256 attributedBefore;
        address parked;
        uint256 parkedAt;
        address drainBook;
        uint256 drainDeficit;
        uint256 drainCharge;
        CrumbTrace oldTrace;
        CrumbTrace newTrace;
        bool disarmed;
        bool selfParked;
    }

    struct FlipResult {
        uint256 expectedCharge;
        uint256 attributedAfter;
        uint256 landedYear1;
        uint256 landedYear2;
        uint256 landedMature;
        BookSnap landedTakes;
        BookSnap oracleOld;
        BookSnap oracleNew;
        uint256 nettedDrainCharge;
    }

    struct MoveFrame {
        address actor;
        address srcReferrer;
        address dstReferrer;
        bool clean;
        uint256 amount;
        BookSnap srcBook;
        BookSnap dstBook;
        BookSnap srcRaw;
        BookSnap dstRaw;
        uint256 srcAttributedBefore;
        uint256 srcPreDeficit;
        uint256 srcParkedCharge;
        uint256 dstAttributedBefore;
        uint256 dstPreDeficit;
        uint256 preDeficit;
        uint256 parkedCharge;
        uint256 scoreBefore;
        uint256 trackedBefore;
        uint256 srcHeadroom;
    }

    WiseSovrenNodesDiamond internal immutable vaultA;

    WiseSovrenNodesDiamond internal immutable vaultB;

    TwoVaultMockUSD internal immutable usdA;

    TwoVaultMockUSD internal immutable usdB;

    ReferralRegistry internal immutable registry;

    CohortRecorderFacet internal immutable recorderA;

    CohortRecorderFacet internal immutable recorderB;

    address internal immutable master;

    address internal immutable a1;

    address internal immutable a2;

    address internal immutable ref;

    address internal immutable ref2;

    address internal immutable u;

    address internal immutable outsider;

    int256 internal constant QUE_INCENTIVE_LOW = 100;

    int256 internal constant QUE_INCENTIVE_HIGH = 200;

    uint256 public ghostCreditedTotal;

    uint256 public ghostMoveViolations;

    uint256 public ghostTrackedViolations;

    uint256 public ghostStartWeek;

    mapping(address => mapping(address => uint256)) public ghostNextWeek;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public ghostCrumb;

    mapping(address => bool) public queActive;

    mapping(address => uint256) public queOrderId;

    mapping(address => int256) public queIncentive;

    mapping(address => address) public ghostReferrerOf;

    mapping(address => uint256) internal keyFloor;

    uint256 public flipCount;

    uint256 public flipMigrations;

    uint256 public clampedFlips;

    uint256 public deferredFlips;

    uint256 public disarmedFlipConsumes;

    uint256 public selfParkedFlips;

    uint256 public clearedFlips;

    uint256 public drainedFlips;

    uint256 public ignoredMerges;

    uint256 public sameReferrerLowerings;

    uint256 public cleanMoves;

    uint256 public relocationMoves;

    uint256 public ghostFlipConservationViolations;

    uint256 public ghostFlipSaleWalkViolations;

    uint256 public ghostFlipLandingViolations;

    uint256 public ghostFlipAmountViolations;

    uint256 public ghostFlipMarkerViolations;

    uint256 public ghostFlipIdempotenceViolations;

    uint256 public ghostFlipDrainViolations;

    uint256 public ghostFlipCrumbViolations;

    uint256 public ghostFlipSaturatedSkips;

    uint256 public ghostMoveLandingViolations;

    uint256 public ghostMergeVariantViolations;

    mapping(address => mapping(address => Lot[])) internal lots;

    mapping(address => mapping(address => uint256)) public ledgerAttributed;

    constructor(
        WiseSovrenNodesDiamond _vaultA,
        WiseSovrenNodesDiamond _vaultB,
        TwoVaultMockUSD _usdA,
        TwoVaultMockUSD _usdB,
        ReferralRegistry _registry,
        address _master,
        address[6] memory _actors,
        uint256 _initialCredited
    ) {
        ghostCreditedTotal = _initialCredited;

        vaultA = _vaultA;

        vaultB = _vaultB;

        usdA = _usdA;

        usdB = _usdB;

        registry = _registry;

        recorderA = CohortRecorderFacet(
            address(_vaultA)
        );

        recorderB = CohortRecorderFacet(
            address(_vaultB)
        );

        master = _master;

        a1 = _actors[0];

        a2 = _actors[1];

        ref = _actors[2];

        ref2 = _actors[3];

        u = _actors[4];

        outsider = _actors[5];

        ghostStartWeek = block.timestamp / 1 weeks;

        ghostNextWeek[address(_vaultA)][ref] = ghostStartWeek;

        ghostNextWeek[address(_vaultA)][ref2] = ghostStartWeek;

        ghostNextWeek[address(_vaultB)][ref] = ghostStartWeek;

        ghostNextWeek[address(_vaultB)][ref2] = ghostStartWeek;

        ghostReferrerOf[a1] = ref;

        ghostReferrerOf[a2] = ref;

        keyFloor[a1] = block.timestamp;

        keyFloor[a2] = block.timestamp;

        _syncLedger();
    }

    modifier captureGhost() {
        _captureFinalizedCrumbs();
        _;
        _captureFinalizedCrumbs();
        _syncLedger();
    }

    // ---- views for the invariant contract ----

    function lotCount(
        address _vault,
        address _user
    )
        external
        view
        returns (uint256)
    {
        return lots[_vault][_user].length;
    }

    function lotAt(
        address _vault,
        address _user,
        uint256 _index
    )
        external
        view
        returns (
            uint256 week,
            uint256 amount
        )
    {
        Lot storage lot = lots[_vault][_user][_index];

        return (
            lot.week,
            lot.amount
        );
    }

    // ---- ghost crumbs ----

    function _captureFinalizedCrumbs()
        internal
    {
        _captureFinalizedCrumbsOf(
            vaultA,
            ref
        );

        _captureFinalizedCrumbsOf(
            vaultA,
            ref2
        );

        _captureFinalizedCrumbsOf(
            vaultB,
            ref
        );

        _captureFinalizedCrumbsOf(
            vaultB,
            ref2
        );
    }

    function _captureFinalizedCrumbsOf(
        WiseSovrenNodesDiamond _vault,
        address _referrer
    )
        internal
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _referrer
        );

        if (lastSettle == 0) {
            return;
        }

        uint256 finalizedUpTo = lastSettle / 1 weeks;

        while (ghostNextWeek[address(_vault)][_referrer] < finalizedUpTo) {

            uint256 week = ghostNextWeek[address(_vault)][_referrer];

            ghostCrumb[address(_vault)][_referrer][week] = _recorderOf(_vault).getCohortWeekCrumb(
                _referrer,
                week
            );

            ghostNextWeek[address(_vault)][_referrer] = week + 1;
        }
    }

    // ---- actor picks ----

    function _refereeActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return _seed % 2 == 0
            ? a1
            : a2;
    }

    function _closedActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 i = _seed % 3;

        if (i == 0) {
            return a1;
        }

        if (i == 1) {
            return a2;
        }

        return u;
    }

    function _recorderOf(
        WiseSovrenNodesDiamond _vault
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(_vault)
        );
    }

    function _globalScore()
        internal
        view
        returns (uint256)
    {
        return recorderA.getCohortScore(ref)
            + recorderA.getCohortScore(ref2)
            + recorderB.getCohortScore(ref)
            + recorderB.getCohortScore(ref2);
    }

    // ---- deposits and transfers ----

    function _depositReferredOn(
        WiseSovrenNodesDiamond _vault,
        TwoVaultMockUSD _usd,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        _usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        _usd.approve(
            address(_vault),
            amount
        );

        vm.prank(
            actor
        );

        ReferralFacet(address(_vault)).depositWithReferral(
            amount,
            ghostReferrerOf[actor]
        );

        ghostCreditedTotal += amount;

        _ledgerCredit(
            _vault,
            actor,
            amount
        );
    }

    function depositReferredOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositReferredOn(
            vaultA,
            usdA,
            _actorSeed,
            _amountSeed
        );
    }

    function depositReferredOnB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositReferredOn(
            vaultB,
            usdB,
            _actorSeed,
            _amountSeed
        );
    }

    function depositUnreferredOnA(
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usdA.mint(
            u,
            amount
        );

        vm.prank(
            u
        );

        usdA.approve(
            address(vaultA),
            amount
        );

        vm.prank(
            u
        );

        UserFacet(address(vaultA)).deposit(
            amount
        );
    }

    function _depositPlainRefereeOn(
        WiseSovrenNodesDiamond _vault,
        TwoVaultMockUSD _usd,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        _usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        _usd.approve(
            address(_vault),
            amount
        );

        vm.prank(
            actor
        );

        UserFacet(address(_vault)).deposit(
            amount
        );

        if (ReferralFacet(address(_vault)).getReferrerOf(actor) != address(0)) {
            ghostCreditedTotal += amount;

            _ledgerCredit(
                _vault,
                actor,
                amount
            );
        }
    }

    function depositPlainRefereeOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositPlainRefereeOn(
            vaultA,
            usdA,
            _actorSeed,
            _amountSeed
        );
    }

    function depositPlainRefereeOnB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _depositPlainRefereeOn(
            vaultB,
            usdB,
            _actorSeed,
            _amountSeed
        );
    }

    function transferOutA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _transferOut(
            vaultA,
            _actorSeed,
            _amountSeed
        );
    }

    function transferOutB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _transferOut(
            vaultB,
            _actorSeed,
            _amountSeed
        );
    }

    function _transferOut(
        WiseSovrenNodesDiamond _vault,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = _vault.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            actor
        );

        _vault.transfer(
            outsider,
            amount
        );
    }

    // ---- moves ----

    function moveAToB(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _moveBetween(
            vaultA,
            vaultB,
            _actorSeed,
            _amountSeed
        );
    }

    function moveBToA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        _moveBetween(
            vaultB,
            vaultA,
            _actorSeed,
            _amountSeed
        );
    }

    function _moveBetween(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        internal
    {
        MoveFrame memory frame;

        frame.actor = _closedActor(
            _actorSeed
        );

        uint256 bal = _src.balanceOf(
            frame.actor
        );

        if (bal == 0) {
            return;
        }

        frame.amount = bound(
            _amountSeed,
            1,
            bal
        );

        frame.clean = (_amountSeed >> 128) % 2 == 0
            && frame.actor != u;

        if (frame.actor != u) {
            _prepareMove(
                _src,
                _dst,
                frame
            );
        }

        frame.preDeficit = _pendingDeficit(
            _src,
            frame.actor
        ) + _pendingDeficit(
            _dst,
            frame.actor
        );

        frame.parkedCharge = _parkedCharge(
            _src,
            frame.actor
        ) + _parkedCharge(
            _dst,
            frame.actor
        );

        frame.scoreBefore = _globalScore();

        frame.trackedBefore = _combinedTracked(
            _src,
            _dst,
            frame.actor
        );

        vm.prank(
            frame.actor
        );

        MoveFacet(address(_src)).moveBetweenVaults(
            address(_dst),
            frame.amount
        );

        uint256 expected = frame.actor == u
            ? frame.scoreBefore - frame.parkedCharge
            : frame.scoreBefore - frame.preDeficit - frame.parkedCharge;

        if (_globalScore() != expected) {
            ++ghostMoveViolations;
        }

        if (_combinedTracked(_src, _dst, frame.actor) != frame.trackedBefore - frame.preDeficit) {
            ++ghostTrackedViolations;
        }

        if (frame.actor == u) {
            return;
        }

        if (frame.clean) {
            _checkMoveLanding(
                _src,
                _dst,
                frame
            );
        }

        _moveLedger(
            _src,
            _dst,
            frame
        );
    }

    function _prepareMove(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        MoveFrame memory _frame
    )
        internal
    {
        if (_frame.clean) {

            _recorderOf(_src).syncReferee(
                _frame.actor
            );

            _recorderOf(_dst).syncReferee(
                _frame.actor
            );
        }

        _frame.srcReferrer = registry.effectiveReferrerOf(
            _frame.actor,
            address(_src)
        );

        _frame.dstReferrer = registry.effectiveReferrerOf(
            _frame.actor,
            address(_dst)
        );

        _frame.srcRaw = _snapBook(
            _src,
            _frame.srcReferrer
        );

        _frame.dstRaw = _snapBook(
            _dst,
            _frame.dstReferrer
        );

        _frame.srcBook = _rotatedSnap(
            _src,
            _frame.srcReferrer
        );

        _frame.dstBook = _rotatedSnap(
            _dst,
            _frame.dstReferrer
        );

        _frame.srcAttributedBefore = _recorderOf(_src).getAttributedContribution(
            _frame.actor
        );

        _frame.srcPreDeficit = _pendingDeficit(
            _src,
            _frame.actor
        );

        _frame.srcHeadroom = _untrackedHeadroom(
            _src,
            _frame.actor
        );

        _frame.srcParkedCharge = _parkedChargeOnBook(
            _src,
            _frame.actor,
            _frame.srcReferrer
        );

        _frame.dstAttributedBefore = _recorderOf(_dst).getAttributedContribution(
            _frame.actor
        );

        _frame.dstPreDeficit = _pendingDeficit(
            _dst,
            _frame.actor
        );
    }

    function _checkMoveLanding(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        MoveFrame memory _frame
    )
        internal
    {
        ++cleanMoves;

        BookSnap memory srcAfter = _snapBook(
            _src,
            _frame.srcReferrer
        );

        BookSnap memory dstAfter = _snapBook(
            _dst,
            _frame.dstReferrer
        );

        BookSnap memory srcBase = _baseBook(
            _src,
            _frame.srcReferrer,
            _frame.srcRaw,
            _frame.srcBook
        );

        BookSnap memory dstBase = _baseBook(
            _dst,
            _frame.dstReferrer,
            _frame.dstRaw,
            _frame.dstBook
        );

        bool relocation = _frame.srcReferrer != _frame.dstReferrer;

        if (relocation) {
            ++relocationMoves;
        }

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            if (
                dstAfter.ring1[s] < dstBase.ring1[s]
                    || dstAfter.ring2[s] < dstBase.ring2[s]
                    || srcAfter.ring1[s] > srcBase.ring1[s]
                    || srcAfter.ring2[s] > srcBase.ring2[s]
            ) {
                ++ghostMoveLandingViolations;

                continue;
            }

            if (
                dstAfter.ring1[s] - dstBase.ring1[s] > srcBase.ring1[s] - srcAfter.ring1[s]
                    || dstAfter.ring2[s] - dstBase.ring2[s] > srcBase.ring2[s] - srcAfter.ring2[s]
            ) {
                ++ghostMoveLandingViolations;
            }
        }

        if (srcAfter.mature > srcBase.mature) {
            ++ghostMoveLandingViolations;
        } else if (
            relocation == false
                && dstAfter.mature > dstBase.mature
                && dstAfter.mature - dstBase.mature > srcBase.mature - srcAfter.mature
        ) {
            ++ghostMoveLandingViolations;
        }
    }

    function _moveLedger(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        MoveFrame memory _frame
    )
        internal
    {
        uint256 srcAfter = _recorderOf(_src).getAttributedContribution(
            _frame.actor
        );

        uint256 srcKnown = ledgerAttributed[address(_src)][_frame.actor];

        if (srcKnown > srcAfter) {
            _removeNewestCollect(
                address(_src),
                _frame.actor,
                srcKnown - srcAfter
            );
        }

        ledgerAttributed[address(_src)][_frame.actor] = srcAfter;

        uint256 dstClamp = _frame.dstAttributedBefore < _frame.dstPreDeficit
            ? _frame.dstAttributedBefore
            : _frame.dstPreDeficit;

        _landLots(
            _dst,
            _frame.actor,
            _carriedLots(
                _frame
            ),
            _frame.dstAttributedBefore - dstClamp
        );
    }

    function _carriedLots(
        MoveFrame memory _frame
    )
        internal
        view
        returns (Lot[] memory carried)
    {
        uint256 burnedPastHeadroom = _frame.amount > _frame.srcHeadroom
            ? _frame.amount - _frame.srcHeadroom
            : 0;

        uint256 delta = _frame.srcPreDeficit + burnedPastHeadroom;

        uint256 carryDelta = delta < _frame.amount
            ? delta
            : _frame.amount;

        uint256 charge = _frame.srcAttributedBefore < delta
            ? _frame.srcAttributedBefore
            : delta;

        uint256 saleLike = charge < delta - carryDelta
            ? charge
            : delta - carryDelta;

        BookSnap memory oracle = _copySnap(
            _frame.srcBook
        );

        _saleWalk(
            oracle,
            _frame.srcParkedCharge
        );

        _saleWalk(
            oracle,
            saleLike
        );

        Lot[] memory takes = new Lot[](
            2 * CohortWeeks.RING_SLOTS + 1
        );

        uint256 count = _saleWalkCollect(
            oracle,
            charge - saleLike,
            takes
        );

        carried = new Lot[](count);

        for (uint256 i; i < count; ++i) {
            carried[i] = takes[i];
        }
    }

    function _landLots(
        WiseSovrenNodesDiamond _dst,
        address _user,
        Lot[] memory _carried,
        uint256 _base
    )
        internal
    {
        uint256 attributedAfter = _recorderOf(_dst).getAttributedContribution(
            _user
        );

        uint256 base = _base < attributedAfter
            ? _base
            : attributedAfter;

        uint256 known = ledgerAttributed[address(_dst)][_user];

        if (base < known) {
            _removeNewestCollect(
                address(_dst),
                _user,
                known - base
            );
        }

        uint256 left = attributedAfter - base;

        for (uint256 i; i < _carried.length && left > 0; ++i) {

            uint256 take = _carried[i].amount < left
                ? _carried[i].amount
                : left;

            if (take == 0) {
                continue;
            }

            lots[address(_dst)][_user].push(
                Lot({
                    week: _carried[i].week,
                    amount: take
                })
            );

            left -= take;
        }

        _pushLot(
            _dst,
            _user,
            block.timestamp / CohortWeeks.WEEK,
            left
        );

        ledgerAttributed[address(_dst)][_user] = attributedAfter;
    }

    // ---- queue ----

    function joinQueOnA(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor]) {
            return;
        }

        uint256 minDep = vaultA.minDepositAmount();

        uint256 bal = vaultA.balanceOf(
            actor
        );

        if (bal < minDep || bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            minDep,
            bal
        );

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).joinQue(
            amount,
            QUE_INCENTIVE_LOW
        );

        queActive[actor] = true;

        queOrderId[actor] = vaultA.earliestValidQueMemberByIncentive(
            QUE_INCENTIVE_LOW
        ) - 1;

        queIncentive[actor] = QUE_INCENTIVE_LOW;
    }

    function switchQueOnA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor] == false) {
            return;
        }

        int256 oldIncentive = queIncentive[actor];

        int256 newIncentive = oldIncentive == QUE_INCENTIVE_LOW
            ? QUE_INCENTIVE_HIGH
            : QUE_INCENTIVE_LOW;

        uint256 id = queOrderId[actor];

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).switchQueIncentive(
            id,
            oldIncentive,
            newIncentive
        );

        queOrderId[actor] = vaultA.earliestValidQueMemberByIncentive(
            newIncentive
        ) - 1;

        queIncentive[actor] = newIncentive;
    }

    function leaveQueOnA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (queActive[actor] == false) {
            return;
        }

        uint256 id = queOrderId[actor];

        int256 incentive = queIncentive[actor];

        vm.prank(
            actor
        );

        QueueJoinLeaveFacet(address(vaultA)).leaveQue(
            id,
            incentive
        );

        queActive[actor] = false;
    }

    // ---- pokes, advances, warps ----

    function pokeA(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        recorderA.syncReferee(
            _closedActor(
                _actorSeed
            )
        );
    }

    function pokeB(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        recorderB.syncReferee(
            _closedActor(
                _actorSeed
            )
        );
    }

    function advanceA(
        uint256 _referrerSeed,
        uint256 _chunkSeed
    )
        external
        captureGhost
    {
        recorderA.advanceBook(
            _referrerSeed % 2 == 0 ? ref : ref2,
            bound(
                _chunkSeed,
                1,
                104
            )
        );
    }

    function advanceB(
        uint256 _referrerSeed,
        uint256 _chunkSeed
    )
        external
        captureGhost
    {
        recorderB.advanceBook(
            _referrerSeed % 2 == 0 ? ref : ref2,
            bound(
                _chunkSeed,
                1,
                104
            )
        );
    }

    function warpHours(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 hours,
                2 days
            )
        );
    }

    function warpWeeks(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 weeks,
                10 weeks
            )
        );
    }

    function warpDormant(
        uint256 _seed
    )
        external
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                26 weeks,
                110 weeks
            )
        );
    }

    // ---- referrer flips ----

    function flipAndPoke(
        uint256 _actorSeed,
        uint256 _keySeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (_mergeLowerKey(actor, _keySeed) == false) {
            return;
        }

        _pokeWithLaws(
            actor,
            false
        );
    }

    function mergeOnly(
        uint256 _actorSeed,
        uint256 _keySeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 variant = bound(
            _keySeed >> 200,
            0,
            2
        );

        if (variant == 0) {
            _mergeLowerKey(
                actor,
                _keySeed
            );

            return;
        }

        _mergeVariant(
            actor,
            _keySeed,
            variant == 1
        );
    }

    function pokeOnly(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        _pokeWithLaws(
            _refereeActor(
                _actorSeed
            ),
            false
        );
    }

    function flipSplitAndPoke(
        uint256 _actorSeed,
        uint256 _keySeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        if (_mergeLowerKey(actor, _keySeed) == false) {
            return;
        }

        vm.prank(
            master
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        _pokeWithLaws(
            actor,
            true
        );

        vm.prank(
            master
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _mergeLowerKey(
        address _actor,
        uint256 _keySeed
    )
        internal
        returns (bool)
    {
        uint256 step = bound(
            _keySeed,
            1,
            1_000
        );

        if (keyFloor[_actor] <= step) {
            return false;
        }

        uint256 assignedAt = keyFloor[_actor] - step;

        address target = ghostReferrerOf[_actor] == ref
            ? ref2
            : ref;

        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            _actor,
            target,
            assignedAt,
            1
        );

        keyFloor[_actor] = assignedAt;

        ghostReferrerOf[_actor] = target;

        ++flipCount;

        return true;
    }

    function _mergeVariant(
        address _actor,
        uint256 _keySeed,
        bool _higherKey
    )
        internal
    {
        uint256 step = bound(
            _keySeed,
            1,
            1_000
        );

        if (keyFloor[_actor] <= step) {
            return;
        }

        address current = ghostReferrerOf[_actor];

        address other = current == ref
            ? ref2
            : ref;

        address markerA = registry.pendingFlip(
            address(vaultA),
            _actor
        );

        address markerB = registry.pendingFlip(
            address(vaultB),
            _actor
        );

        uint256 assignedAt = _higherKey
            ? keyFloor[_actor] + step
            : keyFloor[_actor] - step;

        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            _actor,
            _higherKey ? other : current,
            assignedAt,
            1
        );

        if (_higherKey) {
            ++ignoredMerges;
        } else {
            keyFloor[_actor] = assignedAt;

            ++sameReferrerLowerings;
        }

        if (
            registry.referrerOf(_actor) != current
                || registry.pendingFlip(address(vaultA), _actor) != markerA
                || registry.pendingFlip(address(vaultB), _actor) != markerB
        ) {
            ++ghostMergeVariantViolations;
        }
    }

    function _pokeWithLaws(
        address _actor,
        bool _splitPoke
    )
        internal
    {
        address current = registry.referrerOf(
            _actor
        );

        FlipSide memory sideA = _prepareFlipSide(
            vaultA,
            _actor,
            current
        );

        FlipSide memory sideB = _prepareFlipSide(
            vaultB,
            _actor,
            current
        );

        vm.recordLogs();

        registry.pokeMigration(
            _actor
        );

        bool saturated = _sawLaneSaturation();

        _checkFlipSide(
            vaultA,
            _actor,
            current,
            sideA,
            saturated
        );

        _checkFlipSide(
            vaultB,
            _actor,
            current,
            sideB,
            saturated
        );

        if (_splitPoke == false) {

            if (
                registry.pendingFlip(address(vaultA), _actor) != address(0)
                    || registry.pendingFlip(address(vaultB), _actor) != address(0)
            ) {
                ++ghostFlipMarkerViolations;
            }
        }

        _checkPokeIdempotent(
            _actor
        );
    }

    function _prepareFlipSide(
        WiseSovrenNodesDiamond _vault,
        address _actor,
        address _current
    )
        internal
        view
        returns (FlipSide memory side)
    {
        side.old = registry.pendingFlip(
            address(_vault),
            _actor
        );

        if (side.old == address(0)) {
            return side;
        }

        if (side.old == _current) {
            side.expectClear = true;

            return side;
        }

        side.expectMigration = true;

        side.disarmed = _recorderOf(_vault).getCohortSyncEnabled() == false;

        side.oldRaw = _snapBook(
            _vault,
            side.old
        );

        side.newRaw = _snapBook(
            _vault,
            _current
        );

        (
            address parked,
            uint256 parkedAt
        ) = _parkedOn(
            _vault
        );

        if (parked != address(0)) {

            side.parked = parked;

            side.parkedAt = parkedAt;

            side.selfParked = parked == _actor;

            side.drainDeficit = _pendingDeficit(
                _vault,
                parked
            );
        }

        if (side.drainDeficit > 0 && side.selfParked) {

            uint256 attributed = _recorderOf(_vault).getAttributedContribution(
                _actor
            );

            side.drainBook = side.old;

            side.drainCharge = side.drainDeficit < attributed
                ? side.drainDeficit
                : attributed;
        }

        if (side.drainDeficit > 0 && side.selfParked == false) {

            side.drainBook = registry.effectiveReferrerOf(
                side.parked,
                address(_vault)
            );

            side.drainCharge = _parkedCharge(
                _vault,
                _actor
            );
        }

        side.oldTrace = _traceStart(
            _vault,
            side.old,
            side.drainBook == side.old ? side.parkedAt : block.timestamp
        );

        side.newTrace = _traceStart(
            _vault,
            _current,
            side.drainBook == _current ? side.parkedAt : block.timestamp
        );

        side.trackedBefore = _recorderOf(_vault).getTrackedContribution(
            _actor
        );

        side.heldBefore = _vault.balanceOf(
            _actor
        );

        side.attributedBefore = _recorderOf(_vault).getAttributedContribution(
            _actor
        );
    }

    function _checkFlipSide(
        WiseSovrenNodesDiamond _vault,
        address _actor,
        address _current,
        FlipSide memory _side,
        bool _saturated
    )
        internal
    {
        if (_side.expectMigration == false) {

            if (_side.expectClear) {
                ++clearedFlips;
            }

            return;
        }

        if (_side.disarmed) {

            if (registry.pendingFlip(address(_vault), _actor) != address(0)) {
                ++deferredFlips;

                return;
            }

            if (
                _side.attributedBefore != 0
                    || _recorderOf(_vault).getTrackedContribution(_actor) != _side.trackedBefore
                    || _snapEq(_snapBook(_vault, _side.old), _side.oldRaw) == false
                    || _snapEq(_snapBook(_vault, _current), _side.newRaw) == false
            ) {
                ++ghostFlipAmountViolations;
            }

            ++disarmedFlipConsumes;

            return;
        }

        if (registry.pendingFlip(address(_vault), _actor) != address(0)) {
            ++deferredFlips;

            return;
        }

        ++flipMigrations;

        FlipResult memory result = _flipExpectations(
            _vault,
            _actor,
            _side
        );

        if (result.expectedCharge > 0 && _side.selfParked == false) {
            ++clampedFlips;
        }

        _checkDrainCleared(
            _vault,
            _current,
            _side
        );

        if (_saturated) {
            ++ghostFlipSaturatedSkips;

            _replaceLots(
                _vault,
                _actor,
                block.timestamp / CohortWeeks.WEEK,
                result.attributedAfter,
                0,
                0
            );

            return;
        }

        _flipDrainOracle(
            _side,
            result,
            _current
        );

        _flipMigrationOracle(
            _side,
            result
        );

        _flipCompare(
            _vault,
            _current,
            _side,
            result
        );

        _replaceLotsExact(
            _vault,
            _actor,
            result
        );
    }

    function _flipExpectations(
        WiseSovrenNodesDiamond _vault,
        address _actor,
        FlipSide memory _side
    )
        internal
        returns (FlipResult memory result)
    {
        uint256 expectedTracked = _side.heldBefore < _side.trackedBefore
            ? _side.heldBefore
            : _side.trackedBefore;

        uint256 deficit = _side.trackedBefore - expectedTracked;

        result.expectedCharge = _side.attributedBefore < deficit
            ? _side.attributedBefore
            : deficit;

        result.attributedAfter = _recorderOf(_vault).getAttributedContribution(
            _actor
        );

        if (
            _recorderOf(_vault).getTrackedContribution(_actor) != expectedTracked
                || result.attributedAfter != _side.attributedBefore - result.expectedCharge
        ) {
            ++ghostFlipAmountViolations;
        }
    }

    function _flipDrainOracle(
        FlipSide memory _side,
        FlipResult memory _result,
        address _current
    )
        internal
        pure
    {
        _result.oracleOld = _copySnap(
            _side.oldRaw
        );

        _result.oracleNew = _copySnap(
            _side.newRaw
        );

        if (_side.drainBook != _side.old && _side.drainBook != _current) {
            return;
        }

        BookSnap memory target = _side.drainBook == _side.old
            ? _result.oracleOld
            : _result.oracleNew;

        CrumbTrace memory trace = _side.drainBook == _side.old
            ? _side.oldTrace
            : _side.newTrace;

        _traceSettle(
            target,
            trace,
            _side.parkedAt
        );

        if (_side.drainCharge > 0) {
            _saleWalkAt(
                target,
                _side.drainCharge,
                trace.cursor / CohortWeeks.WEEK
            );
        }

        _result.nettedDrainCharge = _side.drainCharge;
    }

    function _flipMigrationOracle(
        FlipSide memory _side,
        FlipResult memory _result
    )
        internal
        view
    {
        _traceSettle(
            _result.oracleOld,
            _side.oldTrace,
            block.timestamp
        );

        if (_side.selfParked == false) {
            _saleWalkAt(
                _result.oracleOld,
                _result.expectedCharge,
                block.timestamp / CohortWeeks.WEEK
            );
        }

        BookSnap memory preLanding = _copySnap(
            _result.oracleOld
        );

        (
            _result.landedYear1,
            _result.landedYear2,
            _result.landedMature
        ) = _saleWalkAt(
            _result.oracleOld,
            _result.attributedAfter,
            block.timestamp / CohortWeeks.WEEK
        );

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            _result.landedTakes.ring1[s] = preLanding.ring1[s] - _result.oracleOld.ring1[s];

            _result.landedTakes.ring2[s] = preLanding.ring2[s] - _result.oracleOld.ring2[s];
        }

        uint256 landed = _result.landedYear1
            + _result.landedYear2
            + _result.landedMature;

        if (landed > 0) {
            _traceSettle(
                _result.oracleNew,
                _side.newTrace,
                block.timestamp
            );
        }
    }

    function _checkDrainCleared(
        WiseSovrenNodesDiamond _vault,
        address _current,
        FlipSide memory _side
    )
        internal
    {
        if (_side.parked == address(0)) {
            return;
        }

        (
            address parkedAfter,
            uint256 parkedAtAfter
        ) = _parkedOn(
            _vault
        );

        uint256 tracked = _recorderOf(_vault).getTrackedContribution(
            _side.parked
        );

        uint256 held = _vault.balanceOf(
            _side.parked
        );

        bool trackedWrong = _side.drainDeficit > 0
            ? tracked != held
            : tracked > held;

        if (parkedAfter != address(0) || parkedAtAfter != 0 || trackedWrong) {
            ++ghostFlipDrainViolations;

            return;
        }

        if (_side.selfParked) {
            ++selfParkedFlips;
        }

        if (
            (_side.drainBook == _side.old || _side.drainBook == _current)
                && _side.drainCharge > 0
                && _side.selfParked == false
        ) {
            ++drainedFlips;
        }
    }

    function _flipCompare(
        WiseSovrenNodesDiamond _vault,
        address _current,
        FlipSide memory _side,
        FlipResult memory _result
    )
        internal
    {
        BookSnap memory oldAfter = _snapBook(
            _vault,
            _side.old
        );

        BookSnap memory newAfter = _snapBook(
            _vault,
            _current
        );

        uint256 inMigrationCharge = _side.selfParked
            ? 0
            : _result.expectedCharge;

        if (
            _laneSum(
                oldAfter
            )
                + _laneSum(newAfter)
                + inMigrationCharge
                + _result.nettedDrainCharge
                != _laneSum(_side.oldRaw) + _laneSum(_side.newRaw)
        ) {
            ++ghostFlipConservationViolations;
        }

        if (_snapEq(oldAfter, _result.oracleOld) == false) {
            ++ghostFlipSaleWalkViolations;
        }

        if (
            _result.landedYear1 + _result.landedYear2 + _result.landedMature
                != _result.attributedAfter
        ) {
            ++ghostFlipAmountViolations;
        }

        _checkLanding(
            _result.oracleNew,
            newAfter,
            _result
        );

        _traceCompare(
            _vault,
            _side.old,
            _side.oldTrace
        );

        _traceCompare(
            _vault,
            _current,
            _side.newTrace
        );
    }

    function _baseBook(
        WiseSovrenNodesDiamond _vault,
        address _referrer,
        BookSnap memory _raw,
        BookSnap memory _rotated
    )
        internal
        view
        returns (BookSnap memory)
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _referrer
        );

        return lastSettle == block.timestamp
            ? _rotated
            : _raw;
    }

    function _checkLanding(
        BookSnap memory _before,
        BookSnap memory _after,
        FlipResult memory _result
    )
        internal
    {
        if (
            _after.year1 != _before.year1 + _result.landedYear1
                || _after.year2 != _before.year2 + _result.landedYear2
                || _after.mature != _before.mature + _result.landedMature
        ) {
            ++ghostFlipLandingViolations;
        }

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            if (
                uint256(_after.ring1[s]) != uint256(_before.ring1[s]) + uint256(_result.landedTakes.ring1[s])
                    || uint256(_after.ring2[s]) != uint256(_before.ring2[s]) + uint256(_result.landedTakes.ring2[s])
            ) {
                ++ghostFlipLandingViolations;
            }
        }
    }

    function _checkPokeIdempotent(
        address _actor
    )
        internal
    {
        if (
            registry.pendingFlip(address(vaultA), _actor) != address(0)
                || registry.pendingFlip(address(vaultB), _actor) != address(0)
        ) {
            return;
        }

        BookSnap memory refA = _snapBook(
            vaultA,
            ref
        );

        BookSnap memory ref2A = _snapBook(
            vaultA,
            ref2
        );

        BookSnap memory refB = _snapBook(
            vaultB,
            ref
        );

        BookSnap memory ref2B = _snapBook(
            vaultB,
            ref2
        );

        vm.recordLogs();

        registry.pokeMigration(
            _actor
        );

        if (
            _sawFlipLogs()
                || _snapEq(refA, _snapBook(vaultA, ref)) == false
                || _snapEq(ref2A, _snapBook(vaultA, ref2)) == false
                || _snapEq(refB, _snapBook(vaultB, ref)) == false
                || _snapEq(ref2B, _snapBook(vaultB, ref2)) == false
        ) {
            ++ghostFlipIdempotenceViolations;
        }
    }

    // ---- the rotation and sale-walk oracles ----

    function _rotatedSnap(
        WiseSovrenNodesDiamond _vault,
        address _referrer
    )
        internal
        view
        returns (BookSnap memory snap)
    {
        snap = _snapBook(
            _vault,
            _referrer
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _referrer
        );

        _simulateRotations(
            snap,
            lastSettle
        );
    }

    function _simulateRotations(
        BookSnap memory _book,
        uint256 _lastSettle
    )
        internal
        view
    {
        if (_lastSettle == 0) {
            return;
        }

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        for (uint256 week = _lastSettle / CohortWeeks.WEEK + 1; week <= currentWeek; ++week) {
            _rotateOnce(
                _book,
                week
            );
        }
    }

    function _rotateOnce(
        BookSnap memory _book,
        uint256 _week
    )
        internal
        pure
    {
        uint256 slot = _week % CohortWeeks.RING_SLOTS;

        uint256 graduatingYear2 = uint256(_book.ring2[slot]);

        uint256 graduatingYear1 = uint256(_book.ring1[slot]);

        if (graduatingYear1 == 0 && graduatingYear2 == 0) {
            return;
        }

        _book.mature += graduatingYear2;

        _book.year2 = _book.year2
            + graduatingYear1
            - graduatingYear2;

        _book.year1 -= graduatingYear1;

        _book.ring2[slot] = uint64(graduatingYear1);

        _book.ring1[slot] = 0;
    }

    function _traceStart(
        WiseSovrenNodesDiamond _vault,
        address _book,
        uint256 _firstStampAt
    )
        internal
        view
        returns (CrumbTrace memory t)
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _book
        );

        t.cursor = lastSettle;

        t.startWeek = lastSettle == 0
            ? _firstStampAt / CohortWeeks.WEEK
            : lastSettle / CohortWeeks.WEEK;

        uint256 span = block.timestamp / CohortWeeks.WEEK
            - t.startWeek
            + 1;

        t.before = _recorderOf(_vault).getCohortWeekCrumb(
            _book,
            t.startWeek
        );

        t.year1Seconds = new uint256[](
            span
        );

        t.year2Seconds = new uint256[](
            span
        );

        t.matureSeconds = new uint256[](
            span
        );

        t.touched = new bool[](
            span
        );
    }

    function _traceSettle(
        BookSnap memory _book,
        CrumbTrace memory _t,
        uint256 _to
    )
        internal
        pure
    {
        if (_t.cursor >= _to) {
            return;
        }

        if (_t.cursor == 0) {
            _t.cursor = _to;

            return;
        }

        uint256 cursor = _t.cursor;

        uint256 steps;

        while (steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

            if (next > _to) {
                break;
            }

            _traceSegment(
                _book,
                _t,
                cursor,
                next
            );

            _rotateOnce(
                _book,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }

        uint256 latestBoundary = (_to / CohortWeeks.WEEK) * CohortWeeks.WEEK;

        if (latestBoundary > cursor) {
            cursor = latestBoundary;
        }

        if (_to > cursor) {
            _traceSegment(
                _book,
                _t,
                cursor,
                _to
            );
        }

        _t.cursor = _to;
    }

    function _traceSegment(
        BookSnap memory _book,
        CrumbTrace memory _t,
        uint256 _from,
        uint256 _to
    )
        internal
        pure
    {
        if (_laneSum(_book) == 0) {
            return;
        }

        uint256 week = _from / CohortWeeks.WEEK;

        if (week < _t.startWeek || week - _t.startWeek >= _t.year1Seconds.length) {
            ++_t.outOfRange;

            return;
        }

        uint256 idx = week - _t.startWeek;

        uint256 dt = _to - _from;

        _t.year1Seconds[idx] += _book.year1 * dt;

        _t.year2Seconds[idx] += _book.year2 * dt;

        _t.matureSeconds[idx] += _book.mature * dt;

        _t.touched[idx] = true;
    }

    function _traceCompare(
        WiseSovrenNodesDiamond _vault,
        address _book,
        CrumbTrace memory _t
    )
        internal
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _book
        );

        if (lastSettle != _t.cursor) {
            ++ghostFlipCrumbViolations;
        }

        ghostFlipCrumbViolations += _t.outOfRange;

        uint256[] memory actual = _recorderOf(_vault).getCohortWeekCrumbs(
            _book,
            _t.startWeek,
            _t.year1Seconds.length
        );

        for (uint256 idx; idx < actual.length; ++idx) {

            uint256 base = idx == 0
                ? _t.before
                : 0;

            uint256 expected = base;

            if (_t.touched[idx]) {
                expected = CohortWeeks.CRUMB_WRITTEN_BIT
                    | CohortWeeks._packLanes(
                        CohortWeeks._laneY1(base) + _t.year1Seconds[idx],
                        CohortWeeks._laneY2(base) + _t.year2Seconds[idx],
                        CohortWeeks._laneM(base) + _t.matureSeconds[idx]
                    );
            }

            if (actual[idx] != expected) {
                ++ghostFlipCrumbViolations;
            }
        }
    }

    function _saleWalk(
        BookSnap memory _book,
        uint256 _delta
    )
        internal
        view
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        (
            fromYear1,
            fromYear2,
            fromMature
        ) = _saleWalkAt(
            _book,
            _delta,
            block.timestamp / CohortWeeks.WEEK
        );
    }

    function _saleWalkAt(
        BookSnap memory _book,
        uint256 _delta,
        uint256 _anchorWeek
    )
        internal
        pure
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        (
            fromYear1,
            fromYear2,
            fromMature
        ) = _saleWalkCore(
            _book,
            _delta,
            _anchorWeek
        );
    }

    function _saleWalkCollect(
        BookSnap memory _book,
        uint256 _delta,
        Lot[] memory _takes
    )
        internal
        view
        returns (uint256)
    {
        BookSnap memory pre = _copySnap(
            _book
        );

        (
            ,
            ,
            uint256 fromMature
        ) = _saleWalk(
            _book,
            _delta
        );

        return _exactTakes(
            pre,
            _book,
            fromMature,
            block.timestamp / CohortWeeks.WEEK,
            _takes
        );
    }

    function _exactTakes(
        BookSnap memory _pre,
        BookSnap memory _post,
        uint256 _fromMature,
        uint256 _week,
        Lot[] memory _takes
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            uint256 creditWeek = _week
                - (_week + CohortWeeks.RING_SLOTS - s) % CohortWeeks.RING_SLOTS;

            uint256 take1 = uint256(_pre.ring1[s]) - uint256(_post.ring1[s]);

            if (take1 > 0) {
                _takes[count] = Lot({
                    week: creditWeek,
                    amount: take1
                });

                ++count;
            }

            uint256 take2 = uint256(_pre.ring2[s]) - uint256(_post.ring2[s]);

            if (take2 > 0) {
                _takes[count] = Lot({
                    week: creditWeek - CohortWeeks.RING_SLOTS,
                    amount: take2
                });

                ++count;
            }
        }

        if (_fromMature > 0) {
            _takes[count] = Lot({
                week: _week - 2 * CohortWeeks.RING_SLOTS,
                amount: _fromMature
            });

            ++count;
        }
    }

    function _saleWalkCore(
        BookSnap memory _book,
        uint256 _delta,
        uint256 _anchorWeek
    )
        internal
        pure
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        uint256 remaining = _delta;

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0) {
                break;
            }

            uint256 slot = (_anchorWeek
                + CohortWeeks.RING_SLOTS
                - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(_book.ring1[slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            _book.ring1[slot] = uint64(held - take);

            remaining -= take;

            fromYear1 += take;
        }

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0) {
                break;
            }

            uint256 slot = (_anchorWeek
                + CohortWeeks.RING_SLOTS
                - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(_book.ring2[slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            _book.ring2[slot] = uint64(held - take);

            remaining -= take;

            fromYear2 += take;
        }

        _book.year1 = _book.year1 > fromYear1
            ? _book.year1 - fromYear1
            : 0;

        _book.year2 = _book.year2 > fromYear2
            ? _book.year2 - fromYear2
            : 0;

        if (remaining > 0) {

            fromMature = remaining < _book.mature
                ? remaining
                : _book.mature;

            _book.mature = _book.mature - fromMature;
        }
    }

    function _snapBook(
        WiseSovrenNodesDiamond _vault,
        address _referrer
    )
        internal
        view
        returns (BookSnap memory snap)
    {
        (
            snap.year1,
            snap.year2,
            snap.mature,
        ) = _recorderOf(_vault).getCohortBook(
            _referrer
        );

        (
            snap.ring1,
            snap.ring2
        ) = _recorderOf(_vault).getCohortRings(
            _referrer
        );
    }

    function _copySnap(
        BookSnap memory _book
    )
        internal
        pure
        returns (BookSnap memory copy)
    {
        copy.year1 = _book.year1;

        copy.year2 = _book.year2;

        copy.mature = _book.mature;

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {
            copy.ring1[s] = _book.ring1[s];

            copy.ring2[s] = _book.ring2[s];
        }
    }

    function _snapEq(
        BookSnap memory _left,
        BookSnap memory _right
    )
        internal
        pure
        returns (bool)
    {
        if (
            _left.year1 != _right.year1
                || _left.year2 != _right.year2
                || _left.mature != _right.mature
        ) {
            return false;
        }

        for (uint256 s; s < CohortWeeks.RING_SLOTS; ++s) {

            if (_left.ring1[s] != _right.ring1[s] || _left.ring2[s] != _right.ring2[s]) {
                return false;
            }
        }

        return true;
    }

    function _laneSum(
        BookSnap memory _book
    )
        internal
        pure
        returns (uint256)
    {
        return _book.year1
            + _book.year2
            + _book.mature;
    }

    function _sawLaneSaturation()
        internal
        view
        returns (bool)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CohortLaneSaturated(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == topic) {
                return true;
            }
        }

        return false;
    }

    function _sawFlipLogs()
        internal
        view
        returns (bool)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 migrated = keccak256(
            "FlipMigrated(address,address,address,address)"
        );

        bytes32 deferred = keccak256(
            "FlipMigrationDeferred(address,address,address,address)"
        );

        bytes32 cleared = keccak256(
            "FlipCleared(address,address,address)"
        );

        bytes32 applied = keccak256(
            "CohortReferrerFlipApplied(address,address,address,uint256,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            bytes32 topic = logs[i].topics[0];

            if (topic == migrated || topic == deferred || topic == cleared || topic == applied) {
                return true;
            }
        }

        return false;
    }

    // ---- the age ledger ----

    function _syncLedger()
        internal
    {
        _syncLedgerOf(
            vaultA,
            a1
        );

        _syncLedgerOf(
            vaultA,
            a2
        );

        _syncLedgerOf(
            vaultB,
            a1
        );

        _syncLedgerOf(
            vaultB,
            a2
        );
    }

    function _syncLedgerOf(
        WiseSovrenNodesDiamond _vault,
        address _user
    )
        internal
    {
        uint256 attributed = _recorderOf(_vault).getAttributedContribution(
            _user
        );

        uint256 known = ledgerAttributed[address(_vault)][_user];

        if (attributed > known) {
            lots[address(_vault)][_user].push(
                Lot({
                    week: block.timestamp / CohortWeeks.WEEK,
                    amount: attributed - known
                })
            );
        } else if (attributed < known) {
            _removeNewestCollect(
                address(_vault),
                _user,
                known - attributed
            );
        }

        ledgerAttributed[address(_vault)][_user] = attributed;
    }

    function _ledgerCredit(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _amount
    )
        internal
    {
        uint256 attributed = _recorderOf(_vault).getAttributedContribution(
            _user
        );

        if (attributed < _amount) {
            return;
        }

        uint256 base = attributed - _amount;

        uint256 known = ledgerAttributed[address(_vault)][_user];

        if (base < known) {
            _removeNewestCollect(
                address(_vault),
                _user,
                known - base
            );
        }

        lots[address(_vault)][_user].push(
            Lot({
                week: block.timestamp / CohortWeeks.WEEK,
                amount: _amount
            })
        );

        ledgerAttributed[address(_vault)][_user] = attributed;
    }

    function _replaceLotsExact(
        WiseSovrenNodesDiamond _vault,
        address _user,
        FlipResult memory _result
    )
        internal
    {
        delete lots[address(_vault)][_user];

        Lot[] memory takes = new Lot[](
            2 * CohortWeeks.RING_SLOTS + 1
        );

        BookSnap memory empty;

        uint256 count = _exactTakes(
            _result.landedTakes,
            empty,
            _result.landedMature,
            block.timestamp / CohortWeeks.WEEK,
            takes
        );

        for (uint256 i; i < count; ++i) {
            _pushLot(
                _vault,
                _user,
                takes[i].week,
                takes[i].amount
            );
        }

        ledgerAttributed[address(_vault)][_user] = _result.landedYear1
            + _result.landedYear2
            + _result.landedMature;
    }

    function _replaceLots(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _year1Week,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
    {
        delete lots[address(_vault)][_user];

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        _pushLot(
            _vault,
            _user,
            _year1Week,
            _year1
        );

        _pushLot(
            _vault,
            _user,
            week - 103,
            _year2
        );

        _pushLot(
            _vault,
            _user,
            week - 104,
            _mature
        );

        ledgerAttributed[address(_vault)][_user] = _year1 + _year2 + _mature;
    }

    function _pushLot(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _week,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            return;
        }

        lots[address(_vault)][_user].push(
            Lot({
                week: _week,
                amount: _amount
            })
        );
    }

    function _removeNewestCollect(
        address _vault,
        address _user,
        uint256 _amount
    )
        internal
        returns (Lot[] memory removed)
    {
        Lot[] storage own = lots[_vault][_user];

        removed = new Lot[](
            own.length
        );

        uint256 count;

        uint256 left = _amount;

        while (left > 0 && own.length > 0) {

            uint256 newest;

            for (uint256 i = 1; i < own.length; ++i) {

                if (own[i].week > own[newest].week) {
                    newest = i;
                }
            }

            uint256 take = own[newest].amount < left
                ? own[newest].amount
                : left;

            removed[count] = Lot({
                week: own[newest].week,
                amount: take
            });

            ++count;

            left -= take;

            if (take == own[newest].amount) {
                own[newest] = own[own.length - 1];

                own.pop();
            } else {
                own[newest].amount -= take;
            }
        }

        assembly {
            mstore(removed, count)
        }
    }

    // ---- deficits and parked charges ----

    function _untrackedHeadroom(
        WiseSovrenNodesDiamond _vault,
        address _actor
    )
        internal
        view
        returns (uint256)
    {
        uint256 tracked = _recorderOf(_vault).getTrackedContribution(
            _actor
        );

        uint256 bal = _vault.balanceOf(
            _actor
        );

        return bal > tracked
            ? bal - tracked
            : 0;
    }

    function _pendingDeficit(
        WiseSovrenNodesDiamond _vault,
        address _actor
    )
        internal
        view
        returns (uint256)
    {
        uint256 tracked = _recorderOf(_vault).getTrackedContribution(
            _actor
        );

        uint256 bal = _vault.balanceOf(
            _actor
        );

        return tracked > bal
            ? tracked - bal
            : 0;
    }

    function _parkedOn(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (
            address parked,
            uint256 parkedAt
        )
    {
        uint256 word = uint256(
            vm.load(
                address(_vault),
                bytes32(uint256(91))
            )
        );

        parked = address(
            uint160(
                word
            )
        );

        parkedAt = (word >> 160) & type(uint64).max;
    }

    function _parkedCharge(
        WiseSovrenNodesDiamond _vault,
        address _mover
    )
        internal
        view
        returns (uint256)
    {
        (
            address parked,
        ) = _parkedOn(
            _vault
        );

        if (parked == address(0) || parked == _mover) {
            return 0;
        }

        uint256 deficit = _pendingDeficit(
            _vault,
            parked
        );

        uint256 attributed = _recorderOf(_vault).getAttributedContribution(
            parked
        );

        return deficit < attributed
            ? deficit
            : attributed;
    }

    function _parkedChargeOnBook(
        WiseSovrenNodesDiamond _vault,
        address _mover,
        address _book
    )
        internal
        view
        returns (uint256)
    {
        (
            address parked,
        ) = _parkedOn(
            _vault
        );

        if (parked == address(0) || registry.effectiveReferrerOf(parked, address(_vault)) != _book) {
            return 0;
        }

        return _parkedCharge(
            _vault,
            _mover
        );
    }

    function _combinedTracked(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        address _actor
    )
        internal
        view
        returns (uint256)
    {
        return _recorderOf(_src).getTrackedContribution(
            _actor
        ) + _recorderOf(_dst).getTrackedContribution(
            _actor
        );
    }
}

/**
 * @dev Cross-vault stateful-fuzz invariants for the same-chain move
 * carry and the referrer flip: XC1 in its flip-aware form FL7 is the
 * attributed-equals-book identity held PER VAULT and PER REFERRER,
 * keyed on `effectiveReferrerOf` (a standing marker keeps a referee
 * with the old book, the poke moves it), while the carry moves
 * tracked and book together between vaults and the flip relocates
 * credit between books; XC2 is the chain-global conservation
 * statement (the four books together always equal the referees'
 * combined attributed contribution and never exceed the total credit
 * ever granted: moves and flips relocate, clamps only destroy,
 * nothing inflates); XC3 (FL5) pins the ring-to-lane identity for
 * both referrers on both vaults after every action, pokes included
 * (a replant or a landing that touched a ring without its book, or
 * vice versa, breaks it); XC4 re-verifies every finalized crumb word
 * of both books on BOTH vaults against the handler's ghost snapshots
 * (a replant or a relocation may only ever touch open weeks; closed
 * token-second history is immutable); XC5 in its flip-aware form
 * pins the registry referrer and both vaults' routed getters to the
 * handler's ghost of the last lowered key, and requires that a
 * higher key or a same-referrer lowering moved no referrer and
 * marked no vault. The per-move netting equality itself is asserted
 * step-level inside the handler's move actions, where the
 * pre-existing deficit is observable; XC6 and XC7 require the
 * handler's two netting counters to stay zero. The flip laws FL1 to
 * FL4, FL6 and FL10 and the drain check (a third party parked on a
 * migrating vault leaves the poke drained) are asserted step-level
 * inside the poke and surface here as sticky counters: the flip
 * oracle nets that drain (the parked party's book settled to the
 * park instant and walked newest-first from that cursor, before the
 * flip's own walk) and FL10 pins every crumb the poke's settle
 * writes to the pre-state lanes times the seconds settled; FL8
 * likewise for pre-synced moves; FL9 is
 * evaluated here from the handler's age ledger and the current
 * rings. Every law runs with fail-on-revert, so a handler action
 * that reverts fails the campaign instead of being dropped.
 */
contract CohortCrossVaultInvariantTest is TwoVaultCohortHarness {

    uint256 internal constant PIN_DEPOSIT = 1_000 * 1e6;

    address internal constant A1 = address(0xA1);

    address internal constant A2 = address(0xA2);

    address internal constant REF = address(0xB1);

    address internal constant REF2 = address(0xB2);

    address internal constant U = address(0xA3);

    address internal constant OUTSIDER = address(0xC1);

    CohortCrossVaultHandler internal handler;

    struct AgeSums {
        uint256 pooledYear1;
        uint256 pooledUnderMature;
        uint256 ledgerYear1;
        uint256 ledgerUnderMature;
    }

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();

        _depositWithReferralOn(
            vaultA,
            A1,
            PIN_DEPOSIT,
            REF
        );

        _depositWithReferralOn(
            vaultB,
            A2,
            PIN_DEPOSIT,
            REF
        );

        address[6] memory actors = [
            A1,
            A2,
            REF,
            REF2,
            U,
            OUTSIDER
        ];

        handler = new CohortCrossVaultHandler(
            vaultA,
            vaultB,
            usdA,
            usdB,
            registry,
            address(this),
            actors,
            2 * PIN_DEPOSIT
        );

        targetContract(
            address(handler)
        );
    }

    // ---- scripted reach ----

    function test_handlerReach_scriptedFlipsMovesAndSplitMarkers()
        public
    {
        handler.depositReferredOnA(
            0,
            2_000 * 1e6
        );

        handler.depositReferredOnB(
            1,
            2_000 * 1e6
        );

        handler.warpWeeks(
            0
        );

        handler.flipAndPoke(
            0,
            0
        );

        handler.moveAToB(
            0,
            500 * 1e6
        );

        handler.mergeOnly(
            1,
            0
        );

        handler.mergeOnly(
            1,
            0
        );

        handler.pokeOnly(
            1
        );

        handler.mergeOnly(
            1,
            uint256(1) << 200
        );

        handler.mergeOnly(
            1,
            uint256(2) << 200
        );

        handler.flipSplitAndPoke(
            0,
            0
        );

        handler.moveBToA(
            0,
            300 * 1e6
        );

        handler.warpHours(
            0
        );

        handler.pokeOnly(
            0
        );

        handler.transferOutA(
            0,
            type(uint256).max
        );

        handler.transferOutB(
            1,
            type(uint256).max
        );

        AdminFacet(address(vaultB)).burnSupply(
            A1,
            50 * 1e6
        );

        handler.warpWeeks(
            3
        );

        handler.flipAndPoke(
            0,
            0
        );

        handler.moveAToB(
            0,
            uint256(1) << 128
        );

        assertGe(
            handler.flipMigrations(),
            4,
            "reach: fewer migrations than the script drives"
        );

        assertGe(
            handler.clampedFlips(),
            1,
            "reach: no flip met a lazy deficit"
        );

        assertGe(
            handler.drainedFlips(),
            1,
            "reach: no poke drained a parked third party"
        );

        assertGe(
            handler.selfParkedFlips(),
            1,
            "reach: no flip met its own parked mover"
        );

        assertGe(
            handler.deferredFlips(),
            1,
            "reach: the split poke did not defer vault B"
        );

        assertGe(
            handler.clearedFlips(),
            1,
            "reach: the key chain back did not clear a marker"
        );

        assertGe(
            handler.ignoredMerges(),
            1,
            "reach: no higher key was sent"
        );

        assertGe(
            handler.sameReferrerLowerings(),
            1,
            "reach: no same-referrer lowering was sent"
        );

        assertGe(
            handler.cleanMoves(),
            2,
            "reach: fewer pre-synced moves than the script drives"
        );

        assertGe(
            handler.relocationMoves(),
            1,
            "reach: no pre-synced move relocated between referrers"
        );

        assertEq(
            handler.ghostFlipSaturatedSkips(),
            0,
            "reach: a scripted poke saturated a lane"
        );

        invariant_XC1_FL7_perVaultPerReferrerAttributedEqualsBookEqualsScore();

        invariant_XC2_globalBookConservation();

        invariant_XC3_FL5_ringLaneIdentityBothVaultsBothReferrers();

        invariant_XC4_finalizedCrumbsImmutableBothVaults();

        invariant_XC5_registryReferrerMatchesGhostAndRoutedGetters();

        invariant_XC6_moveNettingNeverViolated();

        invariant_XC7_moveTrackedNettingNeverViolated();

        invariant_XC8_attributedNeverExceedsTrackedBothVaults();

        invariant_FL1_FL4_flipConservesLanesAndRelocatesExactlyTheAttributedAmount();

        invariant_FL2_FL3_oldBookIsSaleWalkAndLandingKeepsEverySlot();

        invariant_FL6_pokeClearsMarkersAndASecondPokeCallsNoVault();

        invariant_FL8_moveLandingBoundedSlotBySlotBySourceTakes();

        invariant_FL9_pooledYoungMassNeverExceedsTheMembersLots();

        invariant_FL10_pokeSettleWritesTheCrumbsThePreStateImplies();
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC1_FL7_perVaultPerReferrerAttributedEqualsBookEqualsScore()
        public
        view
    {
        _assertVaultIdentity(
            vaultA,
            "XC1-A"
        );

        _assertVaultIdentity(
            vaultB,
            "XC1-B"
        );
    }

    function _assertVaultIdentity(
        WiseSovrenNodesDiamond _vault,
        string memory _tag
    )
        internal
        view
    {
        _assertBookIdentity(
            _vault,
            REF,
            string.concat(
                _tag,
                "-REF"
            )
        );

        _assertBookIdentity(
            _vault,
            REF2,
            string.concat(
                _tag,
                "-REF2"
            )
        );
    }

    function _assertBookIdentity(
        WiseSovrenNodesDiamond _vault,
        address _book,
        string memory _tag
    )
        internal
        view
    {
        uint256 attributedSum;

        if (registry.effectiveReferrerOf(A1, address(_vault)) == _book) {
            attributedSum += _recorderOf(_vault).getAttributedContribution(
                A1
            );
        }

        if (registry.effectiveReferrerOf(A2, address(_vault)) == _book) {
            attributedSum += _recorderOf(_vault).getAttributedContribution(
                A2
            );
        }

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = _recorderOf(_vault).getCohortBook(
            _book
        );

        assertEq(
            attributedSum,
            year1 + year2 + mature,
            string.concat(
                _tag,
                ": attributed sum of the book's members != book total"
            )
        );

        assertEq(
            _recorderOf(
                _vault
            ).getCohortScore(
                _book
            ),
            year1 + year2 + mature,
            string.concat(
                _tag,
                ": score != book total"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC8_attributedNeverExceedsTrackedBothVaults()
        public
        view
    {
        _assertAttributedBounded(
            vaultA,
            "XC8-A"
        );

        _assertAttributedBounded(
            vaultB,
            "XC8-B"
        );
    }

    function _assertAttributedBounded(
        WiseSovrenNodesDiamond _vault,
        string memory _tag
    )
        internal
        view
    {
        assertLe(
            _recorderOf(
                _vault
            ).getAttributedContribution(
                A1
            ),
            _recorderOf(
                _vault
            ).getTrackedContribution(
                A1
            ),
            string.concat(
                _tag,
                "-A1: attributed above tracked"
            )
        );

        assertLe(
            _recorderOf(
                _vault
            ).getAttributedContribution(
                A2
            ),
            _recorderOf(
                _vault
            ).getTrackedContribution(
                A2
            ),
            string.concat(
                _tag,
                "-A2: attributed above tracked"
            )
        );

        assertEq(
            _recorderOf(
                _vault
            ).getAttributedContribution(
                U
            ),
            0,
            string.concat(
                _tag,
                "-U: unreferred actor attributed"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC2_globalBookConservation()
        public
        view
    {
        uint256 globalScore = _recorderOf(vaultA).getCohortScore(REF)
            + _recorderOf(vaultA).getCohortScore(REF2)
            + _recorderOf(vaultB).getCohortScore(REF)
            + _recorderOf(vaultB).getCohortScore(REF2);

        uint256 globalAttributed = _recorderOf(vaultA).getAttributedContribution(A1)
            + _recorderOf(vaultA).getAttributedContribution(A2)
            + _recorderOf(vaultB).getAttributedContribution(A1)
            + _recorderOf(vaultB).getAttributedContribution(A2);

        assertEq(
            globalScore,
            globalAttributed,
            "XC2: global book != global referee attributed"
        );

        assertLe(
            globalScore,
            handler.ghostCreditedTotal(),
            "XC2: global book exceeds total credit ever granted"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC3_FL5_ringLaneIdentityBothVaultsBothReferrers()
        public
        view
    {
        _assertVaultRings(
            vaultA,
            REF,
            "XC3-A-REF"
        );

        _assertVaultRings(
            vaultA,
            REF2,
            "XC3-A-REF2"
        );

        _assertVaultRings(
            vaultB,
            REF,
            "XC3-B-REF"
        );

        _assertVaultRings(
            vaultB,
            REF2,
            "XC3-B-REF2"
        );
    }

    function _assertVaultRings(
        WiseSovrenNodesDiamond _vault,
        address _book,
        string memory _tag
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(_vault).getCohortRings(
            _book
        );

        uint256 ring1Sum;

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {
            ring1Sum += uint256(ring1[i]);

            ring2Sum += uint256(ring2[i]);
        }

        (
            uint256 year1,
            uint256 year2,
            ,

        ) = _recorderOf(_vault).getCohortBook(
            _book
        );

        assertEq(
            ring1Sum,
            year1,
            string.concat(
                _tag,
                ": ring1 sum != bookY1"
            )
        );

        assertEq(
            ring2Sum,
            year2,
            string.concat(
                _tag,
                ": ring2 sum != bookY2"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC4_finalizedCrumbsImmutableBothVaults()
        public
        view
    {
        _assertCrumbsFrozen(
            vaultA,
            REF,
            "XC4-A-REF"
        );

        _assertCrumbsFrozen(
            vaultA,
            REF2,
            "XC4-A-REF2"
        );

        _assertCrumbsFrozen(
            vaultB,
            REF,
            "XC4-B-REF"
        );

        _assertCrumbsFrozen(
            vaultB,
            REF2,
            "XC4-B-REF2"
        );
    }

    function _assertCrumbsFrozen(
        WiseSovrenNodesDiamond _vault,
        address _book,
        string memory _tag
    )
        internal
        view
    {
        uint256 start = handler.ghostStartWeek();

        uint256 next = handler.ghostNextWeek(
            address(_vault),
            _book
        );

        for (uint256 w = start; w < next; ++w) {
            assertEq(
                _recorderOf(_vault).getCohortWeekCrumb(
                    _book,
                    w
                ),
                handler.ghostCrumb(
                    address(_vault),
                    _book,
                    w
                ),
                string.concat(
                    _tag,
                    ": finalized crumb mutated"
                )
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC6_moveNettingNeverViolated()
        public
        view
    {
        assertEq(
            handler.ghostMoveViolations(),
            0,
            "XC6: a move failed the netting equality"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC7_moveTrackedNettingNeverViolated()
        public
        view
    {
        assertEq(
            handler.ghostTrackedViolations(),
            0,
            "XC7: a move failed the tracked netting equality"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_XC5_registryReferrerMatchesGhostAndRoutedGetters()
        public
        view
    {
        assertEq(
            registry.referrerOf(
                A1
            ),
            handler.ghostReferrerOf(
                A1
            ),
            "XC5: A1 referrer drifted from the last lowered key"
        );

        assertEq(
            registry.referrerOf(
                A2
            ),
            handler.ghostReferrerOf(
                A2
            ),
            "XC5: A2 referrer drifted from the last lowered key"
        );

        assertEq(
            ReferralFacet(address(vaultA)).getReferrerOf(
                A1
            ),
            handler.ghostReferrerOf(
                A1
            ),
            "XC5: vaultA routed getter drifted from the ghost"
        );

        assertEq(
            ReferralFacet(address(vaultB)).getReferrerOf(
                A2
            ),
            handler.ghostReferrerOf(
                A2
            ),
            "XC5: vaultB routed getter drifted from the ghost"
        );

        assertEq(
            handler.ghostMergeVariantViolations(),
            0,
            "XC5: a higher key or a same-referrer lowering moved a referrer or marked a vault"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL1_FL4_flipConservesLanesAndRelocatesExactlyTheAttributedAmount()
        public
        view
    {
        assertEq(
            handler.ghostFlipConservationViolations(),
            0,
            "FL1: the two books' lane totals were not conserved across a poke net of the clamp and the drained third party's charge"
        );

        assertEq(
            handler.ghostFlipDrainViolations(),
            0,
            "FL1: a parked third party survived the poke undrained"
        );

        assertEq(
            handler.ghostFlipAmountViolations(),
            0,
            "FL4: the relocated amount or the mover's counters departed from the post-clamp attributed contribution"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL2_FL3_oldBookIsSaleWalkAndLandingKeepsEverySlot()
        public
        view
    {
        assertEq(
            handler.ghostFlipSaleWalkViolations(),
            0,
            "FL2: the old book after the poke is not the drain walk then the sale walk over the traced pre-state"
        );

        assertEq(
            handler.ghostFlipLandingViolations(),
            0,
            "FL3: the landing departed from the walk takes slot for slot or carried the wrong totals"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL6_pokeClearsMarkersAndASecondPokeCallsNoVault()
        public
        view
    {
        assertEq(
            handler.ghostFlipMarkerViolations(),
            0,
            "FL6: a poke on armed vaults left a marker standing"
        );

        assertEq(
            handler.ghostFlipIdempotenceViolations(),
            0,
            "FL6: a markerless second poke called a vault or changed a book"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL8_moveLandingBoundedSlotBySlotBySourceTakes()
        public
        view
    {
        assertEq(
            handler.ghostMoveLandingViolations(),
            0,
            "FL8: a move landed more at a slot than the source took there, or above the source's mature reduction under one referrer"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL9_pooledYoungMassNeverExceedsTheMembersLots()
        public
        view
    {
        _assertAgeDominance(
            vaultA,
            REF,
            "FL9-A-REF"
        );

        _assertAgeDominance(
            vaultA,
            REF2,
            "FL9-A-REF2"
        );

        _assertAgeDominance(
            vaultB,
            REF,
            "FL9-B-REF"
        );

        _assertAgeDominance(
            vaultB,
            REF2,
            "FL9-B-REF2"
        );

        _assertLedgerMatchesAttributed(
            vaultA
        );

        _assertLedgerMatchesAttributed(
            vaultB
        );
    }

    function _assertAgeDominance(
        WiseSovrenNodesDiamond _vault,
        address _book,
        string memory _tag
    )
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorderOf(_vault).getCohortBook(
            _book
        );

        if (lastSettle == 0) {

            assertEq(
                year1 + year2 + mature,
                0,
                string.concat(
                    _tag,
                    ": a never-settled book holds mass"
                )
            );

            return;
        }

        uint256 settleWeek = lastSettle / CohortWeeks.WEEK;

        AgeSums memory sums;

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(_vault).getCohortRings(
            _book
        );

        for (uint256 i; i < 52; ++i) {
            sums.pooledYear1 += uint256(ring1[i]);

            sums.pooledUnderMature += uint256(ring1[i]) + uint256(ring2[i]);
        }

        _addMemberLots(
            _vault,
            _book,
            A1,
            settleWeek,
            sums
        );

        _addMemberLots(
            _vault,
            _book,
            A2,
            settleWeek,
            sums
        );

        assertLe(
            sums.pooledYear1,
            sums.ledgerYear1,
            string.concat(
                _tag,
                ": pooled year-1 mass exceeds the members' young lots"
            )
        );

        assertLe(
            sums.pooledUnderMature,
            sums.ledgerUnderMature,
            string.concat(
                _tag,
                ": pooled ring mass exceeds the members' lots under the mature boundary"
            )
        );
    }

    function _addMemberLots(
        WiseSovrenNodesDiamond _vault,
        address _book,
        address _user,
        uint256 _settleWeek,
        AgeSums memory _sums
    )
        internal
        view
    {
        if (registry.effectiveReferrerOf(_user, address(_vault)) != _book) {
            return;
        }

        uint256 count = handler.lotCount(
            address(_vault),
            _user
        );

        for (uint256 i; i < count; ++i) {

            (
                uint256 week,
                uint256 amount
            ) = handler.lotAt(
                address(_vault),
                _user,
                i
            );

            if (week + 52 > _settleWeek) {
                _sums.ledgerYear1 += amount;
            }

            if (week + 104 > _settleWeek) {
                _sums.ledgerUnderMature += amount;
            }
        }
    }

    function _assertLedgerMatchesAttributed(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
    {
        assertEq(
            _sumLots(
                _vault,
                A1
            ),
            _recorderOf(
                _vault
            ).getAttributedContribution(
                A1
            ),
            "FL9: the A1 lot ledger drifted from the attributed contribution"
        );

        assertEq(
            _sumLots(
                _vault,
                A2
            ),
            _recorderOf(
                _vault
            ).getAttributedContribution(
                A2
            ),
            "FL9: the A2 lot ledger drifted from the attributed contribution"
        );
    }

    function _sumLots(
        WiseSovrenNodesDiamond _vault,
        address _user
    )
        internal
        view
        returns (uint256 total)
    {
        uint256 count = handler.lotCount(
            address(_vault),
            _user
        );

        for (uint256 i; i < count; ++i) {

            (
                ,
                uint256 amount
            ) = handler.lotAt(
                address(_vault),
                _user,
                i
            );

            total += amount;
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FL10_pokeSettleWritesTheCrumbsThePreStateImplies()
        public
        view
    {
        assertEq(
            handler.ghostFlipCrumbViolations(),
            0,
            "FL10: a crumb the poke's settle wrote departs from the pre-state lanes times the seconds settled"
        );
    }

    function test_handlerReplay_moveAfterUntrackedQueueReturn_landsYoungLotAtItsWeek()
        public
    {
        handler.warpWeeks(
            3_721
        );

        handler.warpWeeks(
            13_215_388_165
        );

        handler.depositReferredOnB(
            12_548,
            3_107
        );

        handler.joinQueOnA(
            3_254,
            12_946_861_826
        );

        handler.warpDormant(
            7_726_553_175_340_794_092_051_521_151_360
        );

        handler.moveBToA(
            24_879,
            1_149_474_006_170_936_562_551_417_930_124_617
        );

        handler.leaveQueOnA(
            0
        );

        handler.depositReferredOnA(
            5_044,
            10_269_074_635
        );

        handler.moveAToB(
            27_814_572_197_708_323_092_324,
            374_834_403_922_993_844_235_665_393
        );

        (
            uint256 year1,
            ,
            ,
        ) = _recorderOf(vaultB).getCohortBook(
            REF
        );

        assertEq(
            year1,
            369_074_633,
            "the young lot lands as year one at its own week"
        );

        invariant_FL9_pooledYoungMassNeverExceedsTheMembersLots();
    }
}
