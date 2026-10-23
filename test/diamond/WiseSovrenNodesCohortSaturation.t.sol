// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {CohortLaneHarness} from "./utils/CohortLaneHarness.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

/**
 * @dev Saturation-guard suite for the cohort recorder engine
 * ({CohortRecorderBase}). Every lane-clip path is exercised directly
 * through {CohortLaneHarness} narrow writers and exposers, because the
 * magnitudes that saturate a uint64 ring lane or an 80-bit book/crumb
 * lane are unreachable through the public deposit-cap API (1e9 * 1e6).
 * The suite proves invariant I6 (the hook path never reverts; every
 * clip fails soft through {CohortLaneSaturated}) and that a clip on
 * one lane never corrupts a sibling lane, a neighboring ring slot, or
 * the crumb-word's written bit / reserved bit ranges. Ring-array slot
 * arithmetic (base + index / 4 for the packed uint64[52]) is pinned
 * against `forge inspect CohortRecorderFacet storage-layout`:
 * cohortRingYear1 is slot 72, cohortRingYear2 is slot 73; verified,
 * not assumed.
 */
contract WiseSovrenNodesCohortSaturationTest is Test {

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortBookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant BASE_SLOT = 3_000 % 52;

    uint256 internal constant MASK80 = CohortWeeks.LANE_MASK_80;

    uint256 internal constant WRITTEN_BIT = CohortWeeks.CRUMB_WRITTEN_BIT;

    address internal referrer = address(0xB1);

    address internal user = address(0xC1);

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
    }

    // ---- ring lane saturation (kind 0) ----

    function test_ringLane_saturatesAtUint64MaxAndEmitsAnomaly()
        external
    {
        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT,
            type(uint64).max - 5
        );

        harness.harnessSetBookLanes(
            referrer,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            referrer,
            0,
            BASE_SLOT,
            95
        );

        harness.exposedCreditRing(
            referrer,
            100
        );

        uint64 laneAfter = harness.viewRingYear1(
            referrer,
            BASE_SLOT
        );

        assertEq(
            laneAfter,
            type(uint64).max
        );

        uint256 book = harness.viewBookWord(
            referrer
        );

        assertEq(
            CohortWeeks._laneY1(
                book
            ),
            100
        );
    }

    function test_ringLane_saturation_neighborSlotsUntouched()
        external
    {
        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT - 1,
            111
        );

        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT,
            type(uint64).max - 5
        );

        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT + 1,
            222
        );

        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT + 2,
            333
        );

        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT + 3,
            444
        );

        harness.exposedCreditRing(
            referrer,
            100
        );

        uint64 before = harness.viewRingYear1(
            referrer,
            BASE_SLOT - 1
        );

        assertEq(
            before,
            111
        );

        uint64 saturated = harness.viewRingYear1(
            referrer,
            BASE_SLOT
        );

        assertEq(
            saturated,
            type(uint64).max
        );

        uint64 afterPlusOne = harness.viewRingYear1(
            referrer,
            BASE_SLOT + 1
        );

        assertEq(
            afterPlusOne,
            222
        );

        uint64 afterPlusTwo = harness.viewRingYear1(
            referrer,
            BASE_SLOT + 2
        );

        assertEq(
            afterPlusTwo,
            333
        );

        uint64 afterPlusThree = harness.viewRingYear1(
            referrer,
            BASE_SLOT + 3
        );

        assertEq(
            afterPlusThree,
            444
        );

        uint256 base = uint256(
            keccak256(
                abi.encode(
                    referrer,
                    uint256(72)
                )
            )
        );

        uint256 wordSlot = base + BASE_SLOT / 4;

        bytes32 raw = vm.load(
            address(harness),
            bytes32(wordSlot)
        );

        uint256 expectedWord = uint256(type(uint64).max)
            | (uint256(222) << 64)
            | (uint256(333) << 128)
            | (uint256(444) << 192);

        assertEq(
            uint256(raw),
            expectedWord
        );
    }

    // ---- book/ring rotate saturation (kind 2) ----

    function test_bookLane_rotateSaturatesMatureAndEmitsAnomaly()
        external
    {
        uint256 boundaryWeek = 5;

        uint256 ringYear2Value = 1_000;

        harness.harnessSetRingYear2(
            referrer,
            boundaryWeek,
            uint64(ringYear2Value)
        );

        harness.harnessSetBookLanes(
            referrer,
            0,
            ringYear2Value,
            MASK80 - 10
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            referrer,
            2,
            boundaryWeek,
            990
        );

        harness.exposedRotate(
            referrer,
            boundaryWeek
        );

        uint256 book = harness.viewBookWord(
            referrer
        );

        assertEq(
            CohortWeeks._laneY1(
                book
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY2(
                book
            ),
            0
        );

        assertEq(
            CohortWeeks._laneM(
                book
            ),
            MASK80
        );

        uint64 ring2After = harness.viewRingYear2(
            referrer,
            boundaryWeek
        );

        assertEq(
            ring2After,
            0
        );

        uint64 ring1After = harness.viewRingYear1(
            referrer,
            boundaryWeek
        );

        assertEq(
            ring1After,
            0
        );
    }

    // ---- crumb lane saturation (kind 3) ----

    function test_crumbLane_saturatesAt80BitsAndEmitsAnomaly()
        external
    {
        uint256 week = 3_050;

        uint256 crumbSeed = WRITTEN_BIT | (MASK80 - 7);

        harness.harnessSetCrumb(
            referrer,
            week,
            crumbSeed
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            referrer,
            3,
            week,
            93
        );

        harness.exposedWriteCrumb(
            referrer,
            week,
            100,
            0,
            0
        );

        uint256 crumb = harness.viewCrumb(
            referrer,
            week
        );

        uint256 expected = WRITTEN_BIT | MASK80;

        assertEq(
            crumb,
            expected
        );
    }

    function test_crumbLane_saturation_otherLanesUntouched()
        external
    {
        uint256 week = 3_060;

        uint256 y1Seed = MASK80 - 3;

        uint256 y2Seed = MASK80 - 777;

        uint256 mSeed = MASK80 - 999_999;

        uint256 crumbSeed = WRITTEN_BIT | CohortWeeks._packLanes(
            y1Seed,
            y2Seed,
            mSeed
        );

        harness.harnessSetCrumb(
            referrer,
            week,
            crumbSeed
        );

        harness.exposedWriteCrumb(
            referrer,
            week,
            10,
            0,
            0
        );

        uint256 crumb = harness.viewCrumb(
            referrer,
            week
        );

        uint256 expected = WRITTEN_BIT | CohortWeeks._packLanes(
            MASK80,
            y2Seed,
            mSeed
        );

        assertEq(
            crumb,
            expected
        );
    }

    // ---- reduce-book floor saturation (kind 5) ----

    function test_reduceBook_floorsAtZeroAndEmitsAnomaly()
        external
    {
        harness.harnessSetLastSettle(
            referrer,
            BASE_TIME
        );

        harness.harnessSetBookLanes(
            referrer,
            5,
            3,
            2
        );

        harness.harnessSetRingYear1(
            referrer,
            BASE_SLOT,
            5
        );

        harness.harnessSetRingYear2(
            referrer,
            BASE_SLOT,
            3
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            referrer,
            5,
            0,
            90
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookReduced(
            referrer,
            100,
            5,
            3,
            2
        );

        (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        ) = harness.exposedReduceBook(
            referrer,
            100
        );

        assertEq(
            fromYear1,
            5
        );

        assertEq(
            fromYear2,
            3
        );

        assertEq(
            fromMature,
            2
        );

        uint256 book = harness.viewBookWord(
            referrer
        );

        assertEq(
            book,
            0
        );
    }

    // ---- never-block guarantee (invariant I6) ----

    function test_settle_extremeDormancyWithSaturatedLanes_neverReverts()
        external
    {
        harness.harnessSetBookLanes(
            referrer,
            MASK80 - 1,
            MASK80 - 1,
            MASK80 - 1
        );

        uint256 farPast = BASE_TIME - 200 weeks;

        harness.harnessSetLastSettle(
            referrer,
            farPast
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        harness.exposedSettleBook(
            referrer
        );

        uint256 lastSettleAfter = harness.viewLastSettle(
            referrer
        );

        assertEq(
            lastSettleAfter,
            block.timestamp
        );
    }

    function test_syncReferee_saturatedBookDeficit_neverReverts()
        external
    {
        uint256 bigTracked = 1e30;

        harness.harnessSetReferrer(
            user,
            referrer
        );

        harness.harnessSetTracked(
            user,
            bigTracked
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            referrer,
            5,
            0,
            bigTracked
        );

        harness.exposedSyncReferee(
            user
        );

        uint256 trackedAfter = harness.viewTracked(
            user
        );

        assertEq(
            trackedAfter,
            0
        );

        uint256 book = harness.viewBookWord(
            referrer
        );

        assertEq(
            book,
            0
        );
    }
}
