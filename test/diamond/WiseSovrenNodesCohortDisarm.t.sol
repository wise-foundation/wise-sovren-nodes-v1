// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortRecorderBase} from "../../src/diamond/vault/facets/pending/CohortRecorderBase.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";
import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract DisarmMockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Narrow-writer harness over {CohortRecorderBase} for the disarm
 * span rule, in the register of {CohortLaneHarness}: deployed
 * STANDALONE, no diamond and no DELEGATECALL, storage layout identical
 * to the diamond's through {CohortPinnedBase}, every `exposed*`
 * forwarding verbatim into the engine internal under test and every
 * `harnessSet*` writer touching exactly one declared field (the two
 * stamps of the slot-93 shard each have their own writer). It exposes
 * only the settle, the bounded advance and the self settle, so the
 * compiler keeps the carry and flip closures out of it.
 */
contract CohortDisarmHarness is CohortRecorderBase {

    function exposedSettleBookTo(
        address _referrer,
        uint256 _to
    )
        external
    {
        _settleBookCohortTo(
            _referrer,
            _to
        );
    }

    function exposedAdvanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
    {
        _advanceBookCohort(
            _referrer,
            _maxBoundaries
        );
    }

    function exposedSettleSelf(
        address _user,
        uint256 _to
    )
        external
    {
        _settleSelfCohort(
            _user,
            _to
        );
    }

    function harnessSetDisarmedAt(
        uint64 _timestamp
    )
        external
    {
        cohortDisarmedAt = _timestamp;
    }

    function harnessSetRearmedAt(
        uint64 _timestamp
    )
        external
    {
        cohortRearmedAt = _timestamp;
    }

    function harnessSetBookLanes(
        address _referrer,
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
    {
        cohortBook[_referrer] = CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        );
    }

    function harnessSetRingYear1(
        address _referrer,
        uint256 _slot,
        uint64 _value
    )
        external
    {
        cohortRingYear1[_referrer][_slot] = _value;
    }

    function harnessSetLastSettle(
        address _referrer,
        uint256 _timestamp
    )
        external
    {
        cohortLastSettle[_referrer] = _timestamp;
    }

    function harnessSetTracked(
        address _user,
        uint256 _amount
    )
        external
    {
        trackedContribution[_user] = _amount;
    }

    function harnessSetSelfCrumb(
        address _user,
        uint256 _word
    )
        external
    {
        cohortSelfCrumb[_user] = _word;
    }

    function harnessMintBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            + _amount;
    }

    function viewCrumb(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return cohortWeekLog[_referrer][_week];
    }

    function viewGapLogLength(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer].length;
    }

    function viewGapLogEntry(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer][_index];
    }

    function viewBookWord(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortBook[_referrer];
    }

    function viewRingYear2(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear2[_referrer][_slot];
    }

    function viewLastSettle(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortLastSettle[_referrer];
    }

    function viewSelfCrumb(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return cohortSelfCrumb[_user];
    }
}

/**
 * @dev Engine pins of the disarm span rule on {CohortDisarmHarness}.
 * The clock is week 3,000 (ring slot 36, which graduates again at the
 * boundary of week 3,052). They pin: a span inside the walk settles
 * exactly to the disarm instant, writes no crumb for the weeks it
 * covers, still graduates the ring-1 cohort whose boundary it crosses
 * and resumes at the re-arm instant; a settle target inside the span
 * writes nothing past the disarm; a span past the 104-boundary walk
 * splits the dormant gap record into a record before the disarm week,
 * the live parts of the disarm and re-arm weeks as crumbs and a record
 * after the re-arm week, including the same-week span, a span that
 * began inside the walk, and a re-arm inside the final partial week;
 * spans clear of the dormant tail and a same-second (empty) span
 * inside it leave one plain record; the bounded advance applies the
 * same live seconds and parks at the span start only until one week
 * after the re-arm (the last second of that week still parks, the
 * week's end crosses the span); and the self crumb, last settled before
 * the re-arm, accrues no presence from the disarm to the settle whatever
 * the held balance (a transfer in does not settle the
 * recipient, so the balance after the re-arm is unknown; a later settle
 * that does not cross the span keeps the ledger value), a target inside
 * the span stopping at the target and a target before the disarm
 * ignoring the span.
 */
contract WiseSovrenNodesCohortDisarmEngineTest is Test {

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortGapRecorded(
        address indexed referrer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 maturePrincipal
    );

    uint256 internal constant WEEK_ZERO = 3_000 weeks;

    uint256 internal constant STAKE = 1_000;

    uint256 internal constant MATURE = 500;

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);

    CohortDisarmHarness internal harness;

    function setUp()
        public
    {
        vm.warp(
            WEEK_ZERO + 1 hours
        );

        harness = new CohortDisarmHarness();
    }

    // ---- helpers ----

    function _setSpan(
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
    {
        harness.harnessSetDisarmedAt(
            uint64(_disarmedAt)
        );

        harness.harnessSetRearmedAt(
            uint64(_rearmedAt)
        );
    }

    function _seedYearOneBook(
        uint256 _lastSettle
    )
        internal
    {
        harness.harnessSetRingYear1(
            refA,
            36,
            uint64(STAKE)
        );

        harness.harnessSetBookLanes(
            refA,
            STAKE,
            0,
            0
        );

        harness.harnessSetLastSettle(
            refA,
            _lastSettle
        );
    }

    function _seedMatureBook()
        internal
    {
        harness.harnessSetBookLanes(
            refA,
            0,
            0,
            MATURE
        );

        harness.harnessSetLastSettle(
            refA,
            WEEK_ZERO + 1 hours
        );
    }

    function _laneY1At(
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return CohortWeeks._laneY1(
            harness.viewCrumb(
                refA,
                _week
            )
        );
    }

    function _laneY2At(
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return CohortWeeks._laneY2(
            harness.viewCrumb(
                refA,
                _week
            )
        );
    }

    function _laneMAt(
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return CohortWeeks._laneM(
            harness.viewCrumb(
                refA,
                _week
            )
        );
    }

    // ---- book settle ----

    function test_settleBookTo_spanInsideWalk_settlesToDisarmAndAgesThroughSpan()
        public
    {
        uint256 last = WEEK_ZERO + 51 weeks + 1 hours;

        uint256 target = WEEK_ZERO + 54 weeks + 1 days;

        _seedYearOneBook(
            last
        );

        _setSpan(
            WEEK_ZERO + 51 weeks + 2 days,
            WEEK_ZERO + 53 weeks + 3 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookSettled(
            refA,
            last,
            target,
            3
        );

        harness.exposedSettleBookTo(
            refA,
            target
        );

        assertEq(
            _laneY1At(3_051),
            STAKE * (2 days - 1 hours)
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_052
            ),
            0
        );

        assertEq(
            _laneY1At(3_053),
            0
        );

        assertEq(
            _laneY2At(3_053),
            STAKE * (1 weeks - 3 days)
        );

        assertEq(
            _laneY2At(3_054),
            STAKE * 1 days
        );

        assertEq(
            uint256(
                harness.viewRingYear2(
                    refA,
                    36
                )
            ),
            STAKE
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                0,
                STAKE,
                0
            )
        );

        assertEq(
            harness.viewLastSettle(
                refA
            ),
            target
        );
    }

    function test_settleBookTo_targetInsideSpan_writesNothingPastDisarm()
        public
    {
        uint256 target = WEEK_ZERO + 1 weeks + 1 days;

        _seedYearOneBook(
            WEEK_ZERO + 1 hours
        );

        _setSpan(
            WEEK_ZERO + 2 days,
            WEEK_ZERO + 3 weeks
        );

        harness.exposedSettleBookTo(
            refA,
            target
        );

        assertEq(
            _laneY1At(3_000),
            STAKE * (2 days - 1 hours)
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_001
            ),
            0
        );

        assertEq(
            harness.viewLastSettle(
                refA
            ),
            target
        );
    }

    function test_settleBookTo_spanInDormantTail_splitsGapAroundSpan()
        public
    {
        uint256 target = WEEK_ZERO + 108 weeks + 1 hours;

        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 105 weeks + 2 days,
            WEEK_ZERO + 106 weeks + 2 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortGapRecorded(
            refA,
            3_104,
            3_105,
            MATURE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortGapRecorded(
            refA,
            3_107,
            3_108,
            MATURE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookSettled(
            refA,
            WEEK_ZERO + 1 hours,
            target,
            104
        );

        harness.exposedSettleBookTo(
            refA,
            target
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            2
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_105,
                MATURE
            )
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                1
            ),
            CohortWeeks._packGapRecord(
                3_107,
                3_108,
                MATURE
            )
        );

        assertEq(
            _laneMAt(3_103),
            MATURE * 1 weeks
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_104
            ),
            0
        );

        assertEq(
            _laneMAt(3_105),
            MATURE * 2 days
        );

        assertEq(
            _laneMAt(3_106),
            MATURE * (1 weeks - 2 days)
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_107
            ),
            0
        );

        assertEq(
            _laneMAt(3_108),
            MATURE * 1 hours
        );
    }

    function test_settleBookTo_sameWeekSpanInDormantTail_oneCrumbBetweenRecords()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 105 weeks + 1 days,
            WEEK_ZERO + 105 weeks + 3 days
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 1 hours
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            2
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_105,
                MATURE
            )
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                1
            ),
            CohortWeeks._packGapRecord(
                3_106,
                3_107,
                MATURE
            )
        );

        assertEq(
            _laneMAt(3_105),
            MATURE * (1 weeks - 2 days)
        );

        assertEq(
            _laneMAt(3_107),
            MATURE * 1 hours
        );
    }

    function test_settleBookTo_spanFromWalkIntoDormantTail_noHeadRecord()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 100 weeks + 1 days,
            WEEK_ZERO + 105 weeks + 2 days
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 1 hours
        );

        assertEq(
            _laneMAt(3_099),
            MATURE * 1 weeks
        );

        assertEq(
            _laneMAt(3_100),
            MATURE * 1 days
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_101
            ),
            0
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_103
            ),
            0
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_104
            ),
            0
        );

        assertEq(
            _laneMAt(3_105),
            MATURE * (1 weeks - 2 days)
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_106,
                3_107,
                MATURE
            )
        );

        assertEq(
            _laneMAt(3_107),
            MATURE * 1 hours
        );
    }

    function test_settleBookTo_rearmInsideFinalPartialWeek_noCrumbPastTarget()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 105 weeks + 2 days,
            WEEK_ZERO + 107 weeks + 30 minutes
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 1 hours
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_105,
                MATURE
            )
        );

        assertEq(
            _laneMAt(3_105),
            MATURE * 2 days
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_106
            ),
            0
        );

        assertEq(
            _laneMAt(3_107),
            MATURE * 30 minutes
        );
    }

    function test_settleBookTo_spanAfterTailBoundary_plainRecordAndLivePartial()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 107 weeks + 2 hours,
            WEEK_ZERO + 107 weeks + 3 hours
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 5 hours
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_107,
                MATURE
            )
        );

        assertEq(
            _laneMAt(3_107),
            MATURE * 4 hours
        );
    }

    function test_settleBookTo_spanBeforeTail_plainRecord()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 10 weeks + 1 days,
            WEEK_ZERO + 11 weeks + 1 days
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 1 hours
        );

        assertEq(
            _laneMAt(3_010),
            MATURE * 1 days
        );

        assertEq(
            _laneMAt(3_011),
            MATURE * (1 weeks - 1 days)
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_107,
                MATURE
            )
        );
    }

    function test_settleBookTo_emptySpanInDormantTail_onePlainRecord()
        public
    {
        _seedMatureBook();

        _setSpan(
            WEEK_ZERO + 105 weeks + 2 days,
            WEEK_ZERO + 105 weeks + 2 days
        );

        harness.exposedSettleBookTo(
            refA,
            WEEK_ZERO + 107 weeks + 1 hours
        );

        assertEq(
            harness.viewGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            harness.viewGapLogEntry(
                refA,
                0
            ),
            CohortWeeks._packGapRecord(
                3_104,
                3_107,
                MATURE
            )
        );

        assertEq(
            harness.viewCrumb(
                refA,
                3_105
            ),
            0
        );
    }

    // ---- bounded advance ----

    function test_advanceBook_acrossSpan_parksAtSpanStart()
        public
    {
        uint256 last = WEEK_ZERO + 1 hours;

        _seedYearOneBook(
            last
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        vm.warp(
            WEEK_ZERO + 3 weeks + 1 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookSettled(
            refA,
            last,
            WEEK_ZERO + 1 weeks + 2 days,
            1
        );

        harness.exposedAdvanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _laneY1At(3_000),
            STAKE * (1 weeks - 1 hours)
        );

        assertEq(
            _laneY1At(3_001),
            STAKE * 2 days
        );

        assertEq(
            _laneY1At(3_002),
            0
        );

        assertEq(
            harness.viewLastSettle(
                refA
            ),
            WEEK_ZERO + 1 weeks + 2 days
        );
    }

    function test_advanceBook_weekAfterRearm_crossesSpan()
        public
    {
        uint256 last = WEEK_ZERO + 1 hours;

        _seedYearOneBook(
            last
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        vm.warp(
            WEEK_ZERO + 3 weeks + 3 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookSettled(
            refA,
            last,
            WEEK_ZERO + 3 weeks,
            3
        );

        harness.exposedAdvanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _laneY1At(3_001),
            STAKE * 2 days
        );

        assertEq(
            _laneY1At(3_002),
            STAKE * 4 days
        );

        assertEq(
            harness.viewLastSettle(
                refA
            ),
            WEEK_ZERO + 3 weeks
        );
    }

    function test_advanceBook_lastSecondOfParkWeek_parksAtSpanStart()
        public
    {
        _seedYearOneBook(
            WEEK_ZERO + 1 hours
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        vm.warp(
            WEEK_ZERO + 3 weeks + 3 days - 1
        );

        harness.exposedAdvanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _laneY1At(3_002),
            0
        );

        assertEq(
            harness.viewLastSettle(
                refA
            ),
            WEEK_ZERO + 1 weeks + 2 days
        );
    }

    // ---- self crumb ----

    function test_settleSelf_acrossSpan_countsNoPresenceFromDisarmToSettle()
        public
    {
        uint256 target = WEEK_ZERO + 3 weeks + 1 days;

        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessMintBalance(
            user1,
            STAKE
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 1 hours
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            target
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                0,
                0,
                target
            )
        );
    }

    function test_settleSelf_acrossSpan_heldBelowTracked_countsNoPresenceAfterRearm()
        public
    {
        uint256 target = WEEK_ZERO + 3 weeks + 1 days;

        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessMintBalance(
            user1,
            STAKE / 4
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 1 hours
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            target
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                0,
                0,
                target
            )
        );
    }

    function test_settleSelf_acrossSpan_heldAboveTracked_countsNoPresenceAfterRearm()
        public
    {
        uint256 target = WEEK_ZERO + 3 weeks + 1 days;

        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessMintBalance(
            user1,
            STAKE * 2
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 1 hours
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            target
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                0,
                0,
                target
            )
        );
    }

    function test_settleSelf_afterRearm_heldBelowTracked_keepsTracked()
        public
    {
        uint256 target = WEEK_ZERO + 3 weeks + 1 days;

        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 2 weeks + 4 days
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            target
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                STAKE * 1 days,
                STAKE * 3 days,
                target
            )
        );
    }

    function test_settleSelf_targetInsideSpan_stopsAtTarget()
        public
    {
        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 1 hours
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            WEEK_ZERO + 2 weeks
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                0,
                STAKE * 2 days,
                WEEK_ZERO + 2 weeks
            )
        );
    }

    function test_settleSelf_targetBeforeDisarm_ignoresSpan()
        public
    {
        harness.harnessSetTracked(
            user1,
            STAKE
        );

        harness.harnessSetSelfCrumb(
            user1,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                WEEK_ZERO + 1 hours
            )
        );

        _setSpan(
            WEEK_ZERO + 1 weeks + 2 days,
            WEEK_ZERO + 2 weeks + 3 days
        );

        harness.exposedSettleSelf(
            user1,
            WEEK_ZERO + 1 days
        );

        assertEq(
            harness.viewSelfCrumb(
                user1
            ),
            CohortWeeks._packSelfCrumb(
                STAKE * (1 days - 1 hours),
                0,
                WEEK_ZERO + 1 days
            )
        );
    }
}

/**
 * @dev Diamond pins of the disarm span on two armed vaults that share
 * one {ReferralRegistry} (the production topology of one chain). The
 * clock starts one hour into week 3,000. The stamp pins read slot 93
 * raw (the stamps have no getter) and so also pin its packing: an
 * actual disarm stamps its instant and clears the re-arm stamp with
 * {CohortDisarmSpanSet}, a repeated disarm and an arm of an armed
 * recorder write nothing, the first arming of a never-disarmed vault
 * writes nothing, the arming call after a disarm stamps the re-arm
 * once and a later `syncReferee(address(0))` poke leaves it, a second
 * cycle stamps both again, and a disarm and re-arm inside one second
 * leave an empty span that zero-weights nothing. The span pins: a
 * referee whose shares left during the disarm and who is synced at
 * the re-arm leaves its referrer's book exactly the crumbs up to the
 * disarm instant (no over-credit) and a self crumb with no presence
 * for the span (the book itself is emptied by the clamp either way;
 * the crumbs and the self word carry the pin); a stake that left one
 * vault during the disarm and was deposited into the other counts
 * once per week across the two; a book idle across the span settles
 * exactly to the disarm instant, graduates through the span and
 * resumes at the re-arm instant; and a sender parked before the
 * disarm is drained by the arming call at its park instant, its self
 * crumb settled to the park and not to the disarm instant, and the
 * park slot cleared. A pending registry pointer change refuses to
 * execute on an armed vault before and after its delay, executes
 * after a disarm, and the vault re-arms on the new pointer.
 */
contract WiseSovrenNodesCohortDisarmTest is DiamondTestHarness {

    event CohortDisarmSpanSet(
        uint256 disarmedAt,
        uint256 rearmedAt
    );

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DIVEST_SLOT = 91;

    uint256 internal constant DISARM_SLOT = 93;

    bytes32 internal constant DISARM_SPAN_TOPIC = keccak256(
        "CohortDisarmSpanSet(uint256,uint256)"
    );

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);
    address internal sink = address(0xC9);
    address internal poker = address(0xD7);

    DisarmMockUSD internal usd;
    ReferralRegistry internal registry;

    WiseSovrenNodesDiamond internal vaultA;
    WiseSovrenNodesDiamond internal vaultB;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new DisarmMockUSD();

        registry = new ReferralRegistry(
            address(this),
            0
        );

        vaultA = _buildArmedVault();

        vaultB = _buildArmedVault();
    }

    // ---- helpers ----

    function _buildArmedVault()
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new CohortBridgeHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            d,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            d,
            registry
        );

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    function _rec(
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

    function _fundAndApproveOn(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_vault),
            _amount
        );
    }

    function _depositWithReferralOn(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApproveOn(
            _vault,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_vault)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _plainDepositOn(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApproveOn(
            _vault,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_vault)).deposit(
            _amount
        );
    }

    function _transferOn(
        WiseSovrenNodesDiamond _vault,
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        _vault.transfer(
            _to,
            _amount
        );
    }

    function _stamps(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (
            uint256 disarmedAt,
            uint256 rearmedAt
        )
    {
        uint256 word = uint256(
            vm.load(
                address(_vault),
                bytes32(DISARM_SLOT)
            )
        );

        disarmedAt = word & type(uint64).max;

        rearmedAt = (word >> 64) & type(uint64).max;
    }

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _laneY1On(
        WiseSovrenNodesDiamond _vault,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return CohortWeeks._laneY1(
            _rec(_vault).getCohortWeekCrumb(
                refA,
                _week
            )
        );
    }

    // ---- stamps ----

    function test_disarm_stampsInstantAndClearsRearm()
        public
    {
        vm.warp(
            BASE_TIME + 1 days
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDisarmSpanSet(
            BASE_TIME + 1 days,
            0
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            BASE_TIME + 1 days
        );

        assertEq(
            rearmedAt,
            0
        );
    }

    function test_disarm_whileDisarmed_writesNothing()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        vm.recordLogs();

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                DISARM_SPAN_TOPIC
            ),
            0
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            BASE_TIME
        );

        assertEq(
            rearmedAt,
            0
        );
    }

    function test_arm_neverDisarmed_writesNoStamp()
        public
    {
        vm.recordLogs();

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                DISARM_SPAN_TOPIC
            ),
            0
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            0
        );

        assertEq(
            rearmedAt,
            0
        );
    }

    function test_rearm_stampsRearmInstantOnce()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDisarmSpanSet(
            BASE_TIME,
            BASE_TIME + 2 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        vm.recordLogs();

        vm.prank(
            poker
        );

        _rec(vaultA).syncReferee(
            address(0)
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                DISARM_SPAN_TOPIC
            ),
            0
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            BASE_TIME
        );

        assertEq(
            rearmedAt,
            BASE_TIME + 2 days
        );
    }

    function test_rearm_secondCycle_restampsBoth()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDisarmSpanSet(
            BASE_TIME + 2 days,
            0
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDisarmSpanSet(
            BASE_TIME + 2 days,
            BASE_TIME + 3 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            BASE_TIME + 2 days
        );

        assertEq(
            rearmedAt,
            BASE_TIME + 3 days
        );
    }

    function test_disarmRearm_sameSecond_zeroWeightsNothing()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        (
            uint256 disarmedAt,
            uint256 rearmedAt
        ) = _stamps(
            vaultA
        );

        assertEq(
            disarmedAt,
            BASE_TIME + 1 weeks + 1 days
        );

        assertEq(
            rearmedAt,
            BASE_TIME + 1 weeks + 1 days
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        vm.prank(
            poker
        );

        _rec(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_001
            ),
            DEPOSIT * 1 weeks
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_002
            ),
            DEPOSIT * 1 weeks
        );
    }

    // ---- the span ----

    function test_disarmSpan_exitDuringDisarm_leavesNoOverCredit()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        assertEq(
            _rec(vaultA).getTrackedContribution(user1),
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortBookSettled(
            refA,
            BASE_TIME,
            BASE_TIME + 4 weeks,
            4
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            DEPOSIT,
            0
        );

        vm.prank(
            poker
        );

        _rec(vaultA).syncReferee(
            user1
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_000
            ),
            DEPOSIT * (1 weeks - 1 hours)
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_001
            ),
            DEPOSIT * 1 weeks
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_002
            ),
            DEPOSIT * 1 hours
        );

        assertEq(
            _rec(vaultA).getCohortWeekCrumb(
                refA,
                3_003
            ),
            0
        );

        assertEq(
            _rec(vaultA).getCohortWeekCrumb(
                refA,
                3_004
            ),
            0
        );

        (
            uint256 settledAt,
            uint256 currentWeekSeconds,
            uint256 previousWeekSeconds
        ) = _rec(vaultA).getCohortSelfCrumb(
            user1
        );

        assertEq(
            settledAt,
            BASE_TIME + 4 weeks
        );

        assertEq(
            currentWeekSeconds,
            0
        );

        assertEq(
            previousWeekSeconds,
            0
        );
    }

    function test_disarmSpan_touredStake_countsOnceAcrossVaults()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        _plainDepositOn(
            vaultB,
            user1,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.prank(
            poker
        );

        _rec(vaultA).syncReferee(
            user1
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        vm.prank(
            poker
        );

        _rec(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        for (uint256 week = 3_002; week <= 3_004; ++week) {

            assertEq(
                _rec(vaultA).getCohortWeekCrumb(
                    refA,
                    week
                ),
                0
            );

            assertEq(
                _laneY1On(
                    vaultB,
                    week
                ),
                DEPOSIT * 1 weeks
            );
        }

        assertEq(
            _laneY1On(
                vaultA,
                3_001
            ),
            DEPOSIT * 1 hours
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_001
            ) + _laneY1On(
                vaultB,
                3_001
            ),
            DEPOSIT * 6 days
        );
    }

    function test_disarmSpan_idleBook_advanceParks_agesAtNextEvent()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 51 weeks + 3 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 53 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 53 weeks + 5 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortBookSettled(
            refA,
            BASE_TIME,
            BASE_TIME + 51 weeks + 3 days,
            51
        );

        vm.prank(
            poker
        );

        _rec(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_050
            ),
            DEPOSIT * 1 weeks
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_051
            ),
            DEPOSIT * (1 hours + 3 days)
        );

        vm.warp(
            BASE_TIME + 54 weeks + 2 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        assertEq(
            _rec(vaultA).getCohortWeekCrumb(
                refA,
                3_052
            ),
            0
        );

        assertEq(
            _laneY1On(
                vaultA,
                3_053
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY2(
                _rec(vaultA).getCohortWeekCrumb(
                    refA,
                    3_053
                )
            ),
            DEPOSIT * (1 weeks - 1 hours)
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _rec(vaultA).getCohortBook(
            refA
        );

        assertEq(
            year1,
            1_000 * 1e6
        );

        assertEq(
            year2,
            DEPOSIT
        );

        assertEq(
            mature,
            0
        );

        assertEq(
            lastSettle,
            BASE_TIME + 54 weeks + 2 days
        );
    }

    function test_rearm_drainsParkBeforeDisarmAtParkInstant()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT / 2
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        (
            uint256 settledAt,
            uint256 currentWeekSeconds,
            uint256 previousWeekSeconds
        ) = _rec(vaultA).getCohortSelfCrumb(
            user1
        );

        assertEq(
            settledAt,
            BASE_TIME + 1 days
        );

        assertEq(
            currentWeekSeconds,
            DEPOSIT * 1 days
        );

        assertEq(
            previousWeekSeconds,
            0
        );

        assertEq(
            _rec(vaultA).getTrackedContribution(user1),
            DEPOSIT / 2
        );

        assertEq(
            vm.load(
                address(vaultA),
                bytes32(DIVEST_SLOT)
            ),
            bytes32(0)
        );
    }

    function test_executeReferralRegistryChange_revertsWhenArmed()
        public
    {
        ReferralRegistry next = new ReferralRegistry(
            address(this),
            0
        );

        next.setAllowedVault(
            address(vaultA),
            true
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoReferralRegistryChangeProposed.selector
        );

        AdminFacet(address(vaultA)).executeReferralRegistryChange();

        AdminFacet(address(vaultA)).proposeReferralRegistry(
            address(next)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryChangeWhileArmed.selector
        );

        AdminFacet(address(vaultA)).executeReferralRegistryChange();

        vm.warp(
            block.timestamp + 3 days
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryChangeWhileArmed.selector
        );

        AdminFacet(address(vaultA)).executeReferralRegistryChange();

        assertEq(
            AdminFacet(address(vaultA)).getReferralRegistry(),
            address(registry)
        );

        assertEq(
            AdminFacet(address(vaultA)).getProposedReferralRegistry(),
            address(next)
        );

        assertGt(
            AdminFacet(address(vaultA)).getReferralRegistryChangeQueuedAt(),
            0
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        AdminFacet(address(vaultA)).executeReferralRegistryChange();

        assertEq(
            AdminFacet(address(vaultA)).getReferralRegistry(),
            address(next)
        );

        assertEq(
            AdminFacet(address(vaultA)).getReferralRegistryChangeQueuedAt(),
            0
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        assertTrue(
            _rec(vaultA).getCohortSyncEnabled()
        );
    }

    function test_advanceBook_completedSpan_stopsAtSpanStart()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 4 weeks + 6 days
        );

        vm.prank(
            poker
        );

        _rec(vaultA).advanceBook(
            refA,
            8
        );

        // inside the week after the re-arm a bare advance is not an
        // event: crossing a completed disarm span it records only up to
        // the span start and leaves every later week un-written, because
        // nothing after the re-arm has vouched the book's level yet
        assertEq(
            _rec(vaultA).getCohortWeekCrumb(
                refA,
                BASE_TIME / 1 weeks + 3
            ),
            0
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _rec(vaultA).getCohortBook(
            refA
        );

        assertEq(
            year1 + year2 + mature,
            DEPOSIT
        );

        assertEq(
            lastSettle,
            BASE_TIME + 2 weeks
        );
    }

    function test_advanceBook_completedSpan_weekAfterRearm_crossesSpan()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        vm.prank(
            poker
        );

        _rec(vaultA).advanceBook(
            refA,
            8
        );

        // one week past the re-arm the park ends: the advance crosses
        // the span, and an exit the operator never synced counts from
        // the re-arm instant until a clamp poke reaches it
        assertEq(
            _laneY1On(
                vaultA,
                BASE_TIME / 1 weeks + 4
            ),
            DEPOSIT * (1 weeks - 1 hours)
        );

        assertEq(
            _laneY1On(
                vaultA,
                BASE_TIME / 1 weeks + 5
            ),
            DEPOSIT * 1 weeks
        );
    }

    function test_disarmSpan_exitDuringDisarm_syncAfterRearm_noPhantomSelf()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 6 days
        );

        vm.prank(
            poker
        );

        _rec(vaultA).syncReferee(
            user1
        );

        (
            uint256 settledAt,
            uint256 currentWeekSeconds,
            uint256 previousWeekSeconds
        ) = _rec(vaultA).getCohortSelfCrumb(
            user1
        );

        assertEq(
            settledAt,
            BASE_TIME + 6 days
        );

        assertEq(
            currentWeekSeconds,
            DEPOSIT * 1 days
        );

        assertEq(
            previousWeekSeconds,
            0
        );
    }

    function test_advanceBook_refereeEventAfterSpan_revoicesTheBook()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        _transferOn(
            vaultA,
            user1,
            sink,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        vm.prank(
            poker
        );

        _rec(vaultA).syncReferee(
            user1
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        vm.prank(
            poker
        );

        _rec(vaultA).advanceBook(
            refA,
            8
        );

        // the clamp poke settles the book through the span at the
        // reconciled level and the referee's fresh deposit is a real
        // event, so the advance resumes from the settled cursor and the
        // weeks after it accrue at the vouched level again
        assertEq(
            _laneY1On(
                vaultA,
                BASE_TIME / 1 weeks + 5
            ),
            3_000 * 1e6 * 1 weeks
        );
    }
}
