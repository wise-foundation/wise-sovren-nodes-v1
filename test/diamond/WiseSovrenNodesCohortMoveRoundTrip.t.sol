// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev Round-trip suite for the same-chain attribution carry: every
 * hop (A to B, and back) lands the moved cover at the oldest live
 * position of its ring (slot `(week + 1) % 52`), so a round trip can
 * only age a referrer's credit, never refresh it, which is also the
 * wash-move-futility proof (a round trip achieves nothing and costs
 * gas). Round trips are compared with a no-move control by
 * conservation (tracked contribution and the lane totals match) and
 * dominance (the moved world holds no more year-one and no more
 * pre-mature mass than the control). Controls are produced with
 * `vm.snapshotState` / `vm.revertToState`; both branches are settled
 * to the same final instant before comparison because rotation is
 * settle-driven, while `cohortLastSettle`, crumbs and the gap log
 * stay excluded from the comparison (honest per-vault history; the
 * crumb conservation test instead proves crumbA + crumbB equals the
 * control crumb per finalized week, the moved amount shifting from
 * the year-one lane to the year-two lane at the first boundary after
 * the move). The partial-move test pins the
 * no-inflation cap: the destination gains exactly the walk output,
 * bounded by min(tracked, moved). The same-address property of
 * `moveBetweenVaults` (no recipient parameter exists; `mintFromPeer`
 * is always called with the mover) is pinned via the `MovedIn` event,
 * the invariant a future cross-chain bridge carry must replicate with
 * an
 * explicit recipient gate. Fuzz amounts stay
 * below the shipped `graceThresholdAmount` (10,000 units): a larger
 * deposit grace-stamps the user and `moveBetweenVaults` reverts
 * `GracePeriodNotElapsed` for 45 days, pre-existing product policy
 * the carry composes with, not a behavior of the carry itself.
 * The single-hop tests pin the relocation itself: a partial Year-1
 * move takes the walk's newest-first `(ring, slot, take)` pairs (one
 * slot drained, the next split) and lands each at its own slot on the
 * destination with the staged and applied event sums matching; a
 * Year-2 pair lands at its own slot on the second ring and keeps its
 * age; a pairless mature aggregate
 * carries as a bare lane amount with every ring slot untouched on
 * both ends; and the destination-versus-control pair compares the
 * destination's own settled schedule directly against a no-move
 * control, so a destination-side rotation fault cannot hide behind
 * the return leg. The pre-populated round trips start with the
 * destination already holding another referee's credit for the same
 * referrer, so the mid-hop book is the exact sum of both referees,
 * the return walk takes the newest cover of the shared slot, every
 * slot keeps its age, and both registry mailbox
 * directions are asserted drained; the two-referee pin shows the same
 * newest-first take on the source vault, where the mover's own aged
 * cohort stays behind and the sibling's fresh cover travels.
 */
contract WiseSovrenNodesCohortMoveRoundTripTest is TwoVaultCohortHarness {

    event MovedIn(
        address indexed user,
        address indexed srcVault,
        uint256 amount
    );

    event CohortCarryStaged(
        address indexed user,
        address indexed dstVault,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortCarryApplied(
        address indexed user,
        address indexed srcVault,
        address indexed referrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal refA = address(0xB1);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _advanceBoth(
        address _referrer
    )
        internal
    {
        _recorderOf(vaultA).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _recorderOf(vaultB).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );
    }

    function _currentSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks) % 52;
    }

    function _assertExactRelocation(
        CohortSnap memory _before,
        CohortSnap memory _afterSrc,
        CohortSnap memory _afterDst
    )
        internal
        pure
    {
        for (uint256 i; i < 52; ++i) {

            assertEq(
                uint256(_afterDst.ring1[i]),
                uint256(_before.ring1[i]) - uint256(_afterSrc.ring1[i])
            );

            assertEq(
                uint256(_afterDst.ring2[i]),
                uint256(_before.ring2[i]) - uint256(_afterSrc.ring2[i])
            );
        }
    }

    function _assertRingsEmpty(
        CohortSnap memory _snap
    )
        internal
        pure
    {
        for (uint256 i; i < 52; ++i) {

            assertEq(
                _snap.ring1[i],
                0
            );

            assertEq(
                _snap.ring2[i],
                0
            );
        }
    }

    function _assertCarryDrained(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        address _user
    )
        internal
        view
    {
        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(_src),
            address(_dst),
            _user
        );

        assertEq(
            stagedAt,
            0
        );

        assertEq(
            payload.length,
            0
        );
    }

    function _expectCarryEvents(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        address _referrer,
        uint256 _trackedDelta,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _pairCount
    )
        internal
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(_src)
        );

        emit CohortCarryStaged(
            user1,
            address(_dst),
            _referrer,
            _trackedDelta,
            _year1,
            _year2,
            _mature,
            _pairCount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(_dst)
        );

        emit CohortCarryApplied(
            user1,
            address(_src),
            _referrer,
            _referrer,
            _trackedDelta,
            _year1,
            _year2,
            _mature,
            _pairCount
        );
    }

    // ---- same-block round trip ----

    function test_roundTrip_sameBlock_restoresTheSchedule()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 5 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refA
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            3_500 * 1e6
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            3_500 * 1e6
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _assertLandedTotals(
            vaultA,
            refA,
            3_500 * 1e6,
            0,
            0
        );

        assertEq(
            finalA.tracked,
            3_500 * 1e6
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    // ---- across week boundaries vs control ----

    function test_roundTrip_acrossWeekBoundary_scheduleEqualsControl()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 3 weeks
        );

        vm.warp(
            block.timestamp + 4 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 4 weeks
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            DEPOSIT
        );

        _assertLandedTotals(
            vaultA,
            refA,
            DEPOSIT,
            0,
            0
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            finalA.tracked,
            control.tracked
        );

        assertEq(
            finalA.year1
                + finalA.year2
                + finalA.mature,
            control.year1
                + control.year2
                + control.mature
        );

        assertEq(
            control.year1,
            DEPOSIT
        );

        _assertScheduleEq(
            finalA,
            control
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    // ---- graduation happens away from home ----

    function test_roundTrip_acrossGraduation_landsYearTwoAtItsSlot()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 60 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 50 weeks
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            DEPOSIT
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        _assertLandedTotals(
            vaultA,
            refA,
            0,
            DEPOSIT,
            0
        );

        assertEq(
            finalA.year2,
            DEPOSIT
        );

        assertEq(
            control.year2,
            DEPOSIT
        );

        assertEq(
            finalA.year1,
            0
        );
    }

    // ---- crumb conservation ----

    function test_roundTrip_crumbConservation_crumbsSumToControl()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 startWeek = block.timestamp / 1 weeks;

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 2 weeks + 3 days
        );

        vm.warp(
            block.timestamp + 4 weeks - 3 days
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        uint256[6] memory controlCrumbs;

        for (uint256 i; i < 6; ++i) {
            controlCrumbs[i] = _recorderOf(vaultA).getCohortWeekCrumb(
                refA,
                startWeek + i
            );
        }

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 2 weeks + 3 days
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            2_500 * 1e6
        );

        vm.warp(
            block.timestamp + 4 weeks - 3 days
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        for (uint256 i; i < 6; ++i) {

            uint256 crumbA = _recorderOf(vaultA).getCohortWeekCrumb(
                refA,
                startWeek + i
            );

            uint256 crumbB = _recorderOf(vaultB).getCohortWeekCrumb(
                refA,
                startWeek + i
            );

            assertEq(
                CohortWeeks._laneY1(
                    crumbA
                )
                    + CohortWeeks._laneY1(crumbB),
                CohortWeeks._laneY1(
                    controlCrumbs[i]
                )
            );

            assertEq(
                CohortWeeks._laneY2(crumbA) + CohortWeeks._laneY2(crumbB),
                CohortWeeks._laneY2(
                    controlCrumbs[i]
                )
            );

            assertEq(
                CohortWeeks._laneM(crumbA) + CohortWeeks._laneM(crumbB),
                CohortWeeks._laneM(
                    controlCrumbs[i]
                )
            );
        }
    }

    // ---- partial move: exact walk output, no inflation ----

    function test_move_partial_walkOutputBoundedByMinTrackedMoved()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        _depositOn(
            vaultA,
            user2,
            2_000 * 1e6
        );

        vm.prank(
            user2
        );

        vaultA.transfer(
            user1,
            2_000 * 1e6
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            4_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            2_000 * 1e6
        );
    }

    // ---- same-address property (bridge-carry forward pin) ----

    function test_moveBetweenVaults_alwaysSameAddressBothEnds()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit MovedIn(
            user1,
            address(vaultA),
            DEPOSIT
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );
    }

    // ---- fuzz: round trip vs control with warps + interleaves ----

    struct RoundTripRun {
        uint256 amount;
        uint256 warp1;
        uint256 warp2;
        uint256 interleave;
        uint256 snapshot;
        uint256 sojournBalance;
        CohortSnap control;
        CohortSnap finalA;
    }

    function testFuzz_roundTrip_scheduleNeverYoungerThanControl(
        uint256 _amountSeed,
        uint256 _warp1Seed,
        uint256 _warp2Seed,
        uint256 _interleaveSeed
    )
        public
    {
        RoundTripRun memory run;

        run.amount = bound(
            _amountSeed,
            50 * 1e6,
            9_999 * 1e6
        );

        run.warp1 = bound(
            _warp1Seed,
            0,
            120 weeks
        );

        run.warp2 = bound(
            _warp2Seed,
            0,
            120 weeks
        );

        run.interleave = bound(
            _interleaveSeed,
            0,
            2
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            run.amount,
            refA
        );

        run.snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + run.warp1
        );

        _controlInterleave(
            run
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            run.snapshot
        );

        vm.warp(
            block.timestamp + run.warp1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            run.amount
        );

        _moveInterleave(
            run
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        run.sojournBalance = vaultB.balanceOf(
            user1
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            run.sojournBalance
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            run.finalA.tracked,
            run.control.tracked
        );

        assertEq(
            run.finalA.year1
                + run.finalA.year2
                + run.finalA.mature,
            run.control.year1
                + run.control.year2
                + run.control.mature
        );

        assertLe(
            run.finalA.year1,
            run.control.year1
        );

        assertLe(
            run.finalA.year1 + run.finalA.year2,
            run.control.year1 + run.control.year2
        );

        if (run.interleave != 1) {
            _assertLandedTotals(
                vaultA,
                refA,
                run.finalA.year1,
                run.finalA.year2,
                run.finalA.mature
            );
        }

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );
    }

    function _controlInterleave(
        RoundTripRun memory _run
    )
        internal
    {
        if (_run.interleave == 1 || _run.interleave == 2) {
            _depositWithReferralOn(
                vaultA,
                user1,
                777 * 1e6,
                refA
            );
        }
    }

    function _moveInterleave(
        RoundTripRun memory _run
    )
        internal
    {
        if (_run.interleave == 1) {
            _depositWithReferralOn(
                vaultA,
                user1,
                777 * 1e6,
                refA
            );
        }

        if (_run.interleave == 2) {
            _depositWithReferralOn(
                vaultB,
                user1,
                777 * 1e6,
                refA
            );
        }
    }

    function test_move_singleHop_year2Pair_keepsItsSlotAndAge()
        public
    {
        uint256 s0 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 55 weeks
        );

        uint256 s1 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refA
        );

        CohortSnap memory beforeA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            uint256(beforeA.ring2[s0]),
            1_000 * 1e6
        );

        assertEq(
            uint256(beforeA.ring1[s1]),
            2_000 * 1e6
        );

        assertEq(
            beforeA.year1,
            2_000 * 1e6
        );

        assertEq(
            beforeA.year2,
            1_000 * 1e6
        );

        uint256 landSlot = _landingSlot();

        _expectCarryEvents(
            vaultA,
            vaultB,
            refA,
            2_500 * 1e6,
            2_000 * 1e6,
            500 * 1e6,
            0,
            2
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            2_500 * 1e6
        );

        CohortSnap memory afterA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        CohortSnap memory afterB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        _assertExactRelocation(
            beforeA,
            afterA,
            afterB
        );

        assertEq(
            uint256(afterA.ring1[s1]),
            0
        );

        assertEq(
            uint256(afterA.ring2[s0]),
            500 * 1e6
        );

        assertEq(
            afterA.year1,
            0
        );

        assertEq(
            afterA.year2,
            500 * 1e6
        );

        assertEq(
            afterA.mature,
            0
        );

        assertEq(
            afterA.tracked,
            500 * 1e6
        );

        assertEq(
            uint256(afterB.ring1[landSlot]),
            0
        );

        assertEq(
            uint256(afterB.ring2[landSlot]),
            0
        );

        assertEq(
            uint256(afterB.ring1[s1]),
            2_000 * 1e6
        );

        assertEq(
            uint256(afterB.ring2[s0]),
            500 * 1e6
        );

        assertEq(
            afterB.year1,
            2_000 * 1e6
        );

        assertEq(
            afterB.year2,
            500 * 1e6
        );

        assertEq(
            afterB.mature,
            0
        );

        assertEq(
            afterB.tracked,
            2_500 * 1e6
        );

        _assertCarryDrained(
            vaultA,
            vaultB,
            user1
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory graduatedB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            graduatedB.mature,
            0
        );

        assertEq(
            graduatedB.year2,
            500 * 1e6
        );

        assertEq(
            graduatedB.year1,
            2_000 * 1e6
        );
    }

    function test_move_singleHop_matureAggregate_carriesPairless()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 110 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory beforeA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            beforeA.mature,
            1_000 * 1e6
        );

        assertEq(
            beforeA.year1,
            0
        );

        assertEq(
            beforeA.year2,
            0
        );

        _assertRingsEmpty(
            beforeA
        );

        _expectCarryEvents(
            vaultA,
            vaultB,
            refA,
            400 * 1e6,
            0,
            0,
            400 * 1e6,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            400 * 1e6
        );

        CohortSnap memory afterA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        CohortSnap memory afterB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            afterA.mature,
            600 * 1e6
        );

        assertEq(
            afterA.tracked,
            600 * 1e6
        );

        assertEq(
            afterB.mature,
            400 * 1e6
        );

        assertEq(
            afterB.tracked,
            400 * 1e6
        );

        assertEq(
            afterB.year1,
            0
        );

        assertEq(
            afterB.year2,
            0
        );

        _assertRingsEmpty(
            afterA
        );

        _assertRingsEmpty(
            afterB
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            600 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            400 * 1e6
        );

        _assertCarryDrained(
            vaultA,
            vaultB,
            user1
        );
    }

    // ---- single hop: destination schedule vs control ----

    function test_move_singleHop_destinationScheduleEqualsControl()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 60 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 50 weeks
        );

        _recorderOf(vaultB).syncReferee(
            user1
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory finalB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        _assertScheduleEq(
            finalB,
            control
        );

        assertEq(
            finalB.year2,
            DEPOSIT
        );

        assertEq(
            control.year2,
            DEPOSIT
        );

        assertEq(
            finalB.year1,
            0
        );

        assertEq(
            finalB.tracked,
            control.tracked
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            _captureCohort(
                vaultB,
                refA,
                user1
            ).year2,
            DEPOSIT
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultA,
                refA,
                user1
            )
        );
    }

    struct SingleHopRun {
        uint256 amount;
        uint256 warp1;
        uint256 warp2;
        uint256 snapshot;
        CohortSnap control;
        CohortSnap finalB;
    }

    function testFuzz_move_singleHop_destinationNeverYoungerThanControl(
        uint256 _amountSeed,
        uint256 _warp1Seed,
        uint256 _warp2Seed
    )
        public
    {
        SingleHopRun memory run;

        run.amount = bound(
            _amountSeed,
            50 * 1e6,
            9_999 * 1e6
        );

        run.warp1 = bound(
            _warp1Seed,
            0,
            120 weeks
        );

        run.warp2 = bound(
            _warp2Seed,
            0,
            120 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            run.amount,
            refA
        );

        run.snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + run.warp1
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.control = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.revertToState(
            run.snapshot
        );

        vm.warp(
            block.timestamp + run.warp1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            run.amount
        );

        vm.warp(
            block.timestamp + run.warp2
        );

        _recorderOf(vaultB).syncReferee(
            user1
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        run.finalB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            run.finalB.tracked,
            run.control.tracked
        );

        assertEq(
            run.finalB.year1
                + run.finalB.year2
                + run.finalB.mature,
            run.control.year1
                + run.control.year2
                + run.control.mature
        );

        assertLe(
            run.finalB.year1,
            run.control.year1
        );

        assertLe(
            run.finalB.year1 + run.finalB.year2,
            run.control.year1 + run.control.year2
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultA,
                refA,
                user1
            )
        );
    }

    // ---- round trip into a pre-populated destination ----

    function test_roundTrip_destinationPrePopulated_returnTakesNewestAndKeepsSlots()
        public
    {
        uint256 s0 = _currentSlot();

        _depositWithReferralOn(
            vaultB,
            user2,
            4_000 * 1e6,
            refA
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 landSlot = _landingSlot();

        CohortSnap memory originB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        assertEq(
            originB.year1,
            4_000 * 1e6
        );

        assertEq(
            uint256(originB.ring1[s0]),
            4_000 * 1e6
        );

        assertEq(
            originB.tracked,
            4_000 * 1e6
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            3_000 * 1e6
        );

        CohortSnap memory midA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        CohortSnap memory midB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        assertEq(
            midA.tracked,
            0
        );

        assertEq(
            midA.year1,
            0
        );

        assertEq(
            midB.year1,
            7_000 * 1e6
        );

        assertEq(
            uint256(midB.ring1[s0]),
            7_000 * 1e6
        );

        assertEq(
            uint256(midB.ring1[landSlot]),
            0
        );

        assertEq(
            midB.tracked,
            4_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            3_000 * 1e6
        );

        _assertLandedTotals(
            vaultA,
            refA,
            3_000 * 1e6,
            0,
            0
        );

        CohortSnap memory finalB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        assertEq(
            uint256(finalB.ring1[s0]),
            4_000 * 1e6
        );

        assertEq(
            uint256(finalB.ring1[landSlot]),
            0
        );

        assertEq(
            finalB.year1,
            4_000 * 1e6
        );

        assertEq(
            finalB.year2,
            0
        );

        assertEq(
            finalB.mature,
            0
        );

        assertEq(
            finalB.tracked,
            4_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user2
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            4_000 * 1e6
        );

        _assertCarryDrained(
            vaultA,
            vaultB,
            user1
        );

        _assertCarryDrained(
            vaultB,
            vaultA,
            user1
        );
    }

    function test_roundTrip_destinationPrePopulated_acrossWeekBoundaryLeavesSiblingCoverItsAge()
        public
    {
        uint256 w0 = block.timestamp / 1 weeks;

        _depositWithReferralOn(
            vaultB,
            user2,
            4_000 * 1e6,
            refA
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        uint256 snapshot = vm.snapshotState();

        vm.warp(
            block.timestamp + 3 weeks
        );

        _advanceBoth(
            refA
        );

        CohortSnap memory controlA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        CohortSnap memory controlB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        vm.revertToState(
            snapshot
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            3_000 * 1e6
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            3_000 * 1e6
        );

        _assertLandedTotals(
            vaultA,
            refA,
            3_000 * 1e6,
            0,
            0
        );

        CohortSnap memory midB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        assertEq(
            uint256(midB.ring1[w0 % 52]),
            4_000 * 1e6
        );

        assertEq(
            uint256(midB.ring2[(w0 + 2) % 52]),
            0
        );

        assertEq(
            midB.year1,
            4_000 * 1e6
        );

        assertEq(
            midB.year2,
            0
        );

        assertEq(
            midB.mature,
            0
        );

        assertEq(
            midB.tracked,
            4_000 * 1e6
        );

        _advanceBoth(
            refA
        );

        CohortSnap memory finalA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        CohortSnap memory finalB = _captureCohort(
            vaultB,
            refA,
            user2
        );

        assertEq(
            finalA.year1
                + finalA.year2
                + finalA.mature,
            controlA.year1
                + controlA.year2
                + controlA.mature
        );

        assertEq(
            finalB.year1
                + finalB.year2
                + finalB.mature,
            controlB.year1
                + controlB.year2
                + controlB.mature
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        _assertScheduleEq(
            finalA,
            controlA
        );

        _assertScheduleEq(
            finalB,
            controlB
        );
    }

    // ---- two referees of one referrer on the source ----

    function test_move_twoRefereesOfOneReferrer_takesFreshCoverAndKeepsItsSlot()
        public
    {
        uint256 s0 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 30 weeks
        );

        uint256 s1 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user2,
            2_000 * 1e6,
            refA
        );

        uint256 landSlot = _landingSlot();

        _moveAs(
            user1,
            vaultA,
            vaultB,
            2_000 * 1e6
        );

        CohortSnap memory afterA = _captureCohort(
            vaultA,
            refA,
            user1
        );

        assertEq(
            uint256(afterA.ring1[s0]),
            3_000 * 1e6
        );

        assertEq(
            uint256(afterA.ring1[s1]),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        assertEq(
            afterA.tracked,
            1_000 * 1e6
        );

        _assertLandedTotals(
            vaultB,
            refA,
            2_000 * 1e6,
            0,
            0
        );

        CohortSnap memory afterB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            uint256(afterB.ring1[landSlot]),
            0
        );

        assertEq(
            uint256(afterB.ring1[s1]),
            2_000 * 1e6
        );

        assertEq(
            afterB.tracked,
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            2_000 * 1e6
        );

        vm.prank(
            user2
        );

        vaultA.transfer(
            outsider,
            2_000 * 1e6
        );

        _recorderOf(vaultA).syncReferee(
            user2
        );

        assertEq(
            uint256(
                _captureCohort(
                    vaultA,
                    refA,
                    user2
                ).ring1[s0]
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory graduatedB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            graduatedB.year1,
            2_000 * 1e6
        );

        assertEq(
            graduatedB.year2,
            0
        );

        assertEq(
            graduatedB.mature,
            0
        );
    }

    // ---- exact age: every moved pair lands at its own slot ----

    function test_move_singleHop_partial_keepsEachPairAtItsSlot()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        uint256 s1 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 10 weeks
        );

        uint256 s2 = _currentSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refA
        );

        uint256 landSlot = _landingSlot();

        _moveAs(
            user1,
            vaultA,
            vaultB,
            2_200 * 1e6
        );

        CohortSnap memory afterB = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            uint256(afterB.ring1[s2]),
            500 * 1e6
        );

        assertEq(
            uint256(afterB.ring1[s1]),
            1_700 * 1e6
        );

        assertEq(
            uint256(afterB.ring1[landSlot]),
            0
        );

        assertEq(
            afterB.year1,
            2_200 * 1e6
        );
    }

    function test_move_freshPair_graduatesFiftyTwoWeeksAfterItsDeposit()
        public
    {
        uint256 creditWeek = block.timestamp / 1 weeks;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            1_000 * 1e6
        );

        vm.warp(
            (creditWeek + 52) * 1 weeks - 1
        );

        _advanceBoth(
            refA
        );

        CohortSnap memory beforeGraduation = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            beforeGraduation.year1,
            1_000 * 1e6
        );

        assertEq(
            beforeGraduation.year2,
            0
        );

        vm.warp(
            (creditWeek + 52) * 1 weeks
        );

        _advanceBoth(
            refA
        );

        CohortSnap memory afterGraduation = _captureCohort(
            vaultB,
            refA,
            user1
        );

        assertEq(
            afterGraduation.year1,
            0
        );

        assertEq(
            afterGraduation.year2,
            1_000 * 1e6
        );
    }
}
