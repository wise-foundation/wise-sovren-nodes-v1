// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {CohortLaneHarness} from "../utils/CohortLaneHarness.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../referral/registry/ReferralRegistry.sol";

/**
 * @dev REFB property family: clamp-monotonicity properties for
 * the production PACKED book mirror: uint64 ring lanes, the three-lane
 * book word, and the saturating arithmetic of {CohortWeeks}. Each
 * `testFuzz_*` is written to run under both engines: fuzzed by
 * `forge test` today, symbolically provable by `kontrol prove`
 * (concrete actors and week-aligned
 * concrete timestamps per the methodology in this directory's README;
 * amounts and lane values are the symbolic inputs, bounded below every
 * saturation threshold except where saturation itself is the
 * property). Seeded states are I2-consistent by construction (ring
 * sums equal book lanes) because that is the reachable-state envelope
 * the stateful invariant suite maintains.
 *
 * REFB1 sync never increases the referee ledger or the book total;
 * REFB2 a clamp lands exactly on min(tracked, balance) and reduces
 * the book by exactly the attributed slice of the deficit (the
 * harness stages tracked fully attributed, so that slice is the whole
 * deficit here); REFB3 a credit adds exactly its
 * amount to ring slot and Y1 lane; REFB4 rotation preserves the book
 * total while relocating lanes; REFB5 reduction never reverts and
 * conserves (book drops by exactly min(delta, total), floor at zero);
 * REFB7 crumb lanes are monotone and the written bit is sticky.
 * (REFB6, lane-algebra never-bleed, lives in
 * `WiseSovrenNodesCohortPacking.t.sol` as pure-function fuzzes.)
 */
contract CohortPropertiesTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant SAFE_LANE_BOUND = 1 << 62;

    address internal user = address(0xA1);
    address internal referrer = address(0xB1);

    CohortLaneHarness internal harness;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        harness = new CohortLaneHarness();

        ReferralRegistry registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            address(harness),
            true
        );

        harness.harnessSetRegistry(
            address(registry)
        );

        harness.harnessSetReferrer(
            user,
            referrer
        );

        harness.harnessSetLastSettle(
            referrer,
            block.timestamp
        );
    }

    function _currentSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;
    }

    function _bookTotal()
        internal
        view
        returns (uint256)
    {
        uint256 word = harness.viewBookWord(
            referrer
        );

        return CohortWeeks._laneY1(word)
            + CohortWeeks._laneY2(word)
            + CohortWeeks._laneM(word);
    }

    function testFuzz_REFB1_syncNeverIncreasesTrackedOrBookTotal(
        uint256 _tracked,
        uint256 _balance
    )
        public
    {
        _tracked = bound(
            _tracked,
            0,
            SAFE_LANE_BOUND
        );

        _balance = bound(
            _balance,
            0,
            SAFE_LANE_BOUND
        );

        harness.harnessSetTracked(
            user,
            _tracked
        );

        harness.harnessMintBalance(
            user,
            _balance
        );

        harness.harnessSetRingYear1(
            referrer,
            _currentSlot(),
            uint64(_tracked % (1 << 62))
        );

        harness.harnessSetBookLanes(
            referrer,
            _tracked % (1 << 62),
            0,
            0
        );

        uint256 bookBefore = _bookTotal();

        harness.exposedSyncReferee(
            user
        );

        assertLe(
            harness.viewTracked(
                user
            ),
            _tracked
        );

        assertLe(
            _bookTotal(),
            bookBefore
        );

        assertEq(
            harness.viewTracked(
                user
            ),
            _balance < _tracked
                ? _balance
                : _tracked
        );
    }

    function testFuzz_REFB2_clampReducesBookExactlyByDeficit(
        uint256 _cover,
        uint256 _deficit
    )
        public
    {
        _cover = bound(
            _cover,
            0,
            SAFE_LANE_BOUND
        );

        _deficit = bound(
            _deficit,
            1,
            SAFE_LANE_BOUND
        );

        uint256 tracked = _cover + _deficit;

        harness.harnessSetTracked(
            user,
            tracked
        );

        harness.harnessMintBalance(
            user,
            _cover
        );

        harness.harnessSetRingYear1(
            referrer,
            _currentSlot(),
            uint64(tracked)
        );

        harness.harnessSetBookLanes(
            referrer,
            tracked,
            0,
            0
        );

        harness.exposedSyncReferee(
            user
        );

        assertEq(
            harness.viewTracked(
                user
            ),
            _cover
        );

        assertEq(
            _bookTotal(),
            _cover
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    referrer,
                    _currentSlot()
                )
            ),
            _cover
        );
    }

    function testFuzz_REFB3_creditAddsExactlyToRingAndBook(
        uint256 _pre,
        uint256 _add
    )
        public
    {
        _pre = bound(
            _pre,
            0,
            SAFE_LANE_BOUND
        );

        _add = bound(
            _add,
            0,
            SAFE_LANE_BOUND
        );

        harness.harnessSetRingYear1(
            referrer,
            _currentSlot(),
            uint64(_pre)
        );

        harness.harnessSetBookLanes(
            referrer,
            _pre,
            0,
            0
        );

        harness.exposedCreditRing(
            referrer,
            _add
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    referrer,
                    _currentSlot()
                )
            ),
            _pre + _add
        );

        assertEq(
            CohortWeeks._laneY1(
                harness.viewBookWord(
                    referrer
                )
            ),
            _pre + _add
        );
    }

    function testFuzz_REFB4_rotatePreservesBookTotal(
        uint256 _slotSeed,
        uint256 _graduating1,
        uint256 _graduating2,
        uint256 _restYear1,
        uint256 _restYear2,
        uint256 _mature
    )
        public
    {
        uint256 slot = bound(
            _slotSeed,
            0,
            51
        );

        _graduating1 = bound(
            _graduating1,
            0,
            SAFE_LANE_BOUND
        );

        _graduating2 = bound(
            _graduating2,
            0,
            SAFE_LANE_BOUND
        );

        _restYear1 = bound(
            _restYear1,
            0,
            SAFE_LANE_BOUND
        );

        _restYear2 = bound(
            _restYear2,
            0,
            SAFE_LANE_BOUND
        );

        _mature = bound(
            _mature,
            0,
            SAFE_LANE_BOUND
        );

        harness.harnessSetRingYear1(
            referrer,
            slot,
            uint64(_graduating1)
        );

        harness.harnessSetRingYear2(
            referrer,
            slot,
            uint64(_graduating2)
        );

        harness.harnessSetBookLanes(
            referrer,
            _graduating1 + _restYear1,
            _graduating2 + _restYear2,
            _mature
        );

        uint256 totalBefore = _bookTotal();

        harness.exposedRotate(
            referrer,
            5_200 + slot
        );

        assertEq(
            _bookTotal(),
            totalBefore
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    referrer,
                    slot
                )
            ),
            0
        );

        assertEq(
            uint256(
                harness.viewRingYear2(
                    referrer,
                    slot
                )
            ),
            _graduating1
        );
    }

    function testFuzz_REFB5_reduceNeverRevertsAndConserves(
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _delta
    )
        public
    {
        _year1 = bound(
            _year1,
            0,
            type(uint64).max
        );

        _year2 = bound(
            _year2,
            0,
            type(uint64).max
        );

        _mature = bound(
            _mature,
            0,
            SAFE_LANE_BOUND
        );

        _delta = bound(
            _delta,
            0,
            1 << 78
        );

        harness.harnessSetRingYear1(
            referrer,
            _currentSlot(),
            uint64(_year1)
        );

        harness.harnessSetRingYear2(
            referrer,
            _currentSlot(),
            uint64(_year2)
        );

        harness.harnessSetBookLanes(
            referrer,
            _year1,
            _year2,
            _mature
        );

        uint256 totalBefore = _bookTotal();

        harness.exposedReduceBook(
            referrer,
            _delta
        );

        uint256 taken = _delta < totalBefore
            ? _delta
            : totalBefore;

        assertEq(
            _bookTotal(),
            totalBefore - taken
        );
    }

    function testFuzz_REFB7_crumbLanesMonotoneAndWrittenBitSticky(
        uint256 _preYear1,
        uint256 _preYear2,
        uint256 _preMature,
        uint256 _addYear1,
        uint256 _addYear2,
        uint256 _addMature
    )
        public
    {
        _preYear1 = bound(
            _preYear1,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _preYear2 = bound(
            _preYear2,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _preMature = bound(
            _preMature,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _addYear1 = bound(
            _addYear1,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _addYear2 = bound(
            _addYear2,
            0,
            CohortWeeks.LANE_MASK_80
        );

        _addMature = bound(
            _addMature,
            0,
            CohortWeeks.LANE_MASK_80
        );

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        harness.harnessSetCrumb(
            referrer,
            week,
            CohortWeeks.CRUMB_WRITTEN_BIT
                | CohortWeeks._packLanes(
                    _preYear1,
                    _preYear2,
                    _preMature
                )
        );

        harness.exposedWriteCrumb(
            referrer,
            week,
            _addYear1,
            _addYear2,
            _addMature
        );

        uint256 word = harness.viewCrumb(
            referrer,
            week
        );

        assertGe(
            CohortWeeks._laneY1(
                word
            ),
            _preYear1
        );

        assertGe(
            CohortWeeks._laneY2(
                word
            ),
            _preYear2
        );

        assertGe(
            CohortWeeks._laneM(
                word
            ),
            _preMature
        );

        assertEq(
            word & CohortWeeks.CRUMB_WRITTEN_BIT,
            CohortWeeks.CRUMB_WRITTEN_BIT
        );
    }
}
