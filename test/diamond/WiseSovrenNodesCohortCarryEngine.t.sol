// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CohortCarryHarness} from "./utils/CohortCarryHarness.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

/**
 * @dev Hostile registry mock whose `consumeCarry` answers with a
 * payload longer than `MAX_CARRY_WORDS` and a fresh `stagedAt`, so
 * the destination's wholesale payload validation is the only line
 * of defense left standing.
 */
contract OversizeCarryRegistry {

    function consumeCarry(
        address,
        address
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = block.timestamp;

        payload = new uint256[](
            CohortWeeks.MAX_CARRY_WORDS + 6
        );
    }
}

/**
 * @dev Hostile registry mock for the destination side of the move
 * carry: `consumeCarry` serves whatever payload the test staged with
 * a fresh `stagedAt`, so the payload validates, while the referrer
 * lookup either reverts or answers the zero address, the two ways the
 * destination's own resolution can come back empty after a valid
 * payload was consumed.
 */
contract MoveInLookupRegistry {

    bool internal immutable revertLookup;

    uint256[] internal payload;

    constructor(
        bool _revertLookup
    )
    {
        revertLookup = _revertLookup;
    }

    function setPayload(
        uint256[] calldata _payload
    )
        external
    {
        payload = _payload;
    }

    function consumeCarry(
        address,
        address
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory served
        )
    {
        stagedAt = block.timestamp;

        served = payload;
    }

    function effectiveReferrerOf(
        address,
        address
    )
        external
        view
        returns (address)
    {
        if (revertLookup) {
            revert(
                "MoveInLookupRegistry: reverts"
            );
        }

        return address(0);
    }
}

/**
 * @dev Engine-level suite for the same-chain move-carry machinery in
 * {CohortRecorderBase}, driven through two standalone
 * {CohortCarryHarness} instances sharing ONE {ReferralRegistry}, the
 * per-chain topology of production, without diamond wiring. Section A
 * proves the captured reduction walk: its `(ring, slot, take)` pairs
 * equal the exact storage delta the walk applied (every changed slot
 * appears exactly once, sums match the returned aggregates), and the
 * captured walk is storage-identical to the plain `_reduceBookCohort`
 * it refactors (snapshot differential). Section B proves the
 * capture→stage→apply seam end to end: exact-walk staging, the
 * min(delta, burned) cap with sale-like excess reduction, the
 * unreferred tracked-only envelope, per-ring conservation across
 * harnesses, and the engine-level A to B to A round trip returning
 * the source's book lanes, rings and tracked contribution exactly
 * while each hop lands every pair at its own slot. Section C
 * covers the
 * failure doctrine: every arm must degrade without reverting and
 * without blocking: pointer unset (a failed lookup: clamp deferred + skip),
 * lookup failure on the source (full retry semantics, nothing
 * mutated) and on the destination (the tracked delta lands, the
 * lanes drop unattributed, and a tracked-only envelope never asks
 * the registry at all), revoked
 * allowlist (clamp lands, staging skipped), stale payloads
 * (discarded), malformed payloads (validator rejects wholesale),
 * an empty mailbox (silent: the source staged nothing, so nothing
 * is lost), a codeless registry (discarded with a zero stamp), an
 * unset destination pointer (discarded with a zero stamp, like a
 * codeless registry); plus
 * the per-component floor scaling and its lane-max cap. Section B
 * also carries a fuzzed partial twin of the round trip: four tranches
 * spread across up to
 * sixty weeks (so Year-2 pairs arise through the credit-triggered
 * settle) and an arbitrary partial amount, asserting that the
 * destination's rings equal the source's per-slot takes after the
 * first leg and that the return restores the source's rings, book
 * lanes and tracked contribution exactly.
 * Section C also pins the conservation
 * ceiling of the destination validator: a lane sum above the tracked
 * delta or a tracked delta above the mover's post-mint headroom is
 * discarded wholesale, the equal case lands at the ceiling, and every
 * direct apply mints the headroom first, as production mints before
 * the move-in.
 */
contract WiseSovrenNodesCohortCarryEngineTest is Test {

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

    event CohortCarrySkipped(
        address indexed user,
        address indexed dstVault
    );

    event CohortCarryDiscarded(
        address indexed user,
        address indexed srcVault,
        uint256 stagedAt
    );

    event CohortCarryBookDropped(
        address indexed user,
        address indexed srcVault,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 mature,
        uint256 pairCount
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_TIME = BASE_WEEK * 1 weeks + 1 hours;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);

    address internal refA = address(0xB1);

    CohortCarryHarness internal harnessA;

    CohortCarryHarness internal harnessB;

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        harnessA = new CohortCarryHarness();

        harnessB = new CohortCarryHarness();

        registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            address(harnessA),
            true
        );

        registry.setAllowedVault(
            address(harnessB),
            true
        );

        registry.setAllowedVault(
            address(this),
            true
        );

        harnessA.harnessSetRegistry(
            address(registry)
        );

        harnessB.harnessSetRegistry(
            address(registry)
        );
    }

    // ---- helpers ----

    function _warpToWeek(
        uint256 _week
    )
        internal
    {
        vm.warp(
            _week * 1 weeks + 1 hours
        );
    }

    function _referUser1()
        internal
    {
        registry.assignReferrer(
            user1,
            refA
        );
    }

    function _creditAt(
        CohortCarryHarness _harness,
        uint256 _week,
        uint256 _amount
    )
        internal
    {
        _warpToWeek(
            _week
        );

        _harness.exposedCreditContribution(
            user1,
            _amount
        );
    }

    function _ringSnapshot(
        CohortCarryHarness _harness,
        address _referrer
    )
        internal
        view
        returns (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        )
    {
        for (uint256 i; i < 52; ++i) {
            ring1[i] = _harness.viewRingYear1(
                _referrer,
                i
            );

            ring2[i] = _harness.viewRingYear2(
                _referrer,
                i
            );
        }
    }

    function _assertRingsEqual(
        uint64[52] memory _left1,
        uint64[52] memory _left2,
        uint64[52] memory _right1,
        uint64[52] memory _right2
    )
        internal
        pure
    {
        for (uint256 i; i < 52; ++i) {
            assertEq(
                _left1[i],
                _right1[i]
            );

            assertEq(
                _left2[i],
                _right2[i]
            );
        }
    }

    function _carryTopicCount(
        bytes32 _topic
    )
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _assertCarryDrained(
        address _src,
        address _dst
    )
        internal
        view
    {
        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            _src,
            _dst,
            user1
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

    // ---- Section A: captured walk ----

    struct WalkCheck {
        uint256 total;
        uint256 delta;
        uint256 pairCount;
        uint256 fromYear1;
        uint256 fromYear2;
        uint256 fromMature;
        uint256 pairYear1;
        uint256 pairYear2;
        uint64[52] before1;
        uint64[52] before2;
        uint64[52] after1;
        uint64[52] after2;
        uint256[] pairs;
    }

    function _seedRings(
        uint256 _slotSeed,
        uint256 _amountSeed
    )
        internal
        returns (uint256 total)
    {
        for (uint256 i; i < 6; ++i) {

            uint256 slot = uint256(
                keccak256(
                    abi.encode(
                        _slotSeed,
                        i
                    )
                )
            ) % 52;

            uint256 amount = bound(
                uint256(
                    keccak256(
                        abi.encode(
                            _amountSeed,
                            i
                        )
                    )
                ),
                1,
                1_000_000 * 1e6
            );

            if (i % 2 == 0) {

                uint256 currentYear1 = harnessA.viewRingYear1(
                    refA,
                    slot
                );

                harnessA.harnessSetRingYear1(
                    refA,
                    slot,
                    uint64(currentYear1 + amount)
                );
            } else {

                uint256 currentYear2 = harnessA.viewRingYear2(
                    refA,
                    slot
                );

                harnessA.harnessSetRingYear2(
                    refA,
                    slot,
                    uint64(currentYear2 + amount)
                );
            }

            total += amount;
        }
    }

    function _seedBookFromRings()
        internal
    {
        uint256 year1Total;

        uint256 year2Total;

        for (uint256 i; i < 52; ++i) {
            year1Total += uint256(
                harnessA.viewRingYear1(
                    refA,
                    i
                )
            );

            year2Total += uint256(
                harnessA.viewRingYear2(
                    refA,
                    i
                )
            );
        }

        harnessA.harnessSetBookLanes(
            refA,
            year1Total,
            year2Total,
            0
        );

        harnessA.harnessSetLastSettle(
            refA,
            block.timestamp
        );
    }

    function testFuzz_reduceBookCaptured_pairsEqualStorageDelta(
        uint256 _slotSeed,
        uint256 _amountSeed,
        uint256 _deltaSeed
    )
        public
    {
        WalkCheck memory check;

        check.total = _seedRings(
            _slotSeed,
            _amountSeed
        );

        _seedBookFromRings();

        (
            check.before1,
            check.before2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        check.delta = bound(
            _deltaSeed,
            1,
            check.total
        );

        (
            check.pairs,
            check.pairCount,
            check.fromYear1,
            check.fromYear2,
            check.fromMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            check.delta
        );

        assertEq(
            check.fromMature,
            0
        );

        assertEq(
            check.fromYear1 + check.fromYear2,
            check.delta
        );

        assertLe(
            check.pairCount,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        (
            check.after1,
            check.after2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        for (uint256 i; i < check.pairCount; ++i) {

            uint256 pair = check.pairs[i];

            uint256 slot = CohortWeeks._carryPairSlot(
                pair
            );

            if (CohortWeeks._carryPairRing(pair) == CohortWeeks.CARRY_RING_YEAR1) {

                assertEq(
                    uint256(check.before1[slot]) - uint256(check.after1[slot]),
                    CohortWeeks._carryPairAmount(
                        pair
                    )
                );

                check.pairYear1 += CohortWeeks._carryPairAmount(
                    pair
                );
            } else {

                assertEq(
                    uint256(check.before2[slot]) - uint256(check.after2[slot]),
                    CohortWeeks._carryPairAmount(
                        pair
                    )
                );

                check.pairYear2 += CohortWeeks._carryPairAmount(
                    pair
                );
            }
        }

        assertEq(
            check.pairYear1,
            check.fromYear1
        );

        assertEq(
            check.pairYear2,
            check.fromYear2
        );

        for (uint256 i; i < 52; ++i) {

            if (check.before1[i] != check.after1[i]) {
                assertTrue(
                    _slotInPairs(
                        check.pairs,
                        check.pairCount,
                        i,
                        CohortWeeks.CARRY_RING_YEAR1
                    )
                );
            }

            if (check.before2[i] != check.after2[i]) {
                assertTrue(
                    _slotInPairs(
                        check.pairs,
                        check.pairCount,
                        i,
                        CohortWeeks.CARRY_RING_YEAR2
                    )
                );
            }
        }
    }

    function _slotInPairs(
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _slot,
        uint256 _ring
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < _pairCount; ++i) {

            if (
                CohortWeeks._carryPairSlot(_pairs[i]) == _slot
                && CohortWeeks._carryPairRing(_pairs[i]) == _ring
            ) {
                return true;
            }
        }

        return false;
    }

    struct DiffCheck {
        uint256 total;
        uint256 delta;
        uint256 snapshot;
        uint256 plainYear1;
        uint256 plainYear2;
        uint256 plainMature;
        uint256 plainBook;
        uint64[52] plain1;
        uint64[52] plain2;
    }

    function testFuzz_reduceBookCaptured_equalsPlainReduce(
        uint256 _slotSeed,
        uint256 _amountSeed,
        uint256 _deltaSeed
    )
        public
    {
        DiffCheck memory check;

        check.total = _seedRings(
            _slotSeed,
            _amountSeed
        );

        harnessA.harnessSetBookLanes(
            refA,
            check.total,
            check.total,
            1_000 * 1e6
        );

        check.delta = bound(
            _deltaSeed,
            1,
            check.total + 1_000 * 1e6
        );

        check.snapshot = vm.snapshotState();

        (
            check.plainYear1,
            check.plainYear2,
            check.plainMature
        ) = harnessA.exposedReduceBook(
            refA,
            check.delta
        );

        (
            check.plain1,
            check.plain2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        check.plainBook = harnessA.viewBookWord(
            refA
        );

        vm.revertToState(
            check.snapshot
        );

        (
            ,
            ,
            uint256 capturedYear1,
            uint256 capturedYear2,
            uint256 capturedMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            check.delta
        );

        assertEq(
            capturedYear1,
            check.plainYear1
        );

        assertEq(
            capturedYear2,
            check.plainYear2
        );

        assertEq(
            capturedMature,
            check.plainMature
        );

        assertEq(
            harnessA.viewBookWord(
                refA
            ),
            check.plainBook
        );

        (
            uint64[52] memory captured1,
            uint64[52] memory captured2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        _assertRingsEqual(
            captured1,
            captured2,
            check.plain1,
            check.plain2
        );
    }

    function test_reduceBookCaptured_matureResidualPairless()
        public
    {
        harnessA.harnessSetBookLanes(
            refA,
            0,
            0,
            5_000 * 1e6
        );

        (
            ,
            uint256 pairCount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        ) = harnessA.exposedReduceBookCaptured(
            refA,
            2_000 * 1e6
        );

        assertEq(
            pairCount,
            0
        );

        assertEq(
            fromYear1,
            0
        );

        assertEq(
            fromYear2,
            0
        );

        assertEq(
            fromMature,
            2_000 * 1e6
        );
    }

    // ---- Section B: capture → stage → apply ----

    function test_captureApply_referredFull_conservesEveryPairAtItsSlot()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_000 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 10,
            2_000 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 20,
            500 * 1e6
        );

        uint256 bookBefore = harnessA.viewBookWord(
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessA)
        );

        emit CohortCarryStaged(
            user1,
            address(harnessB),
            refA,
            3_500 * 1e6,
            3_500 * 1e6,
            0,
            0,
            3
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_500 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        harnessB.harnessMintBalance(
            user1,
            3_500 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessB)
        );

        emit CohortCarryApplied(
            user1,
            address(harnessA),
            refA,
            refA,
            3_500 * 1e6,
            3_500 * 1e6,
            0,
            0,
            3
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            3_500 * 1e6
        );

        (
            uint64[52] memory afterA1,
            uint64[52] memory afterA2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        (
            uint64[52] memory afterB1,
            uint64[52] memory afterB2
        ) = _ringSnapshot(
            harnessB,
            refA
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                afterA1[i],
                0
            );

            assertEq(
                afterA2[i],
                0
            );

            assertEq(
                afterB2[i],
                0
            );

            if (
                i != BASE_WEEK % 52
                    && i != (BASE_WEEK + 10) % 52
                    && i != (BASE_WEEK + 20) % 52
            ) {
                assertEq(
                    afterB1[i],
                    0
                );
            }
        }

        assertEq(
            uint256(afterB1[BASE_WEEK % 52]),
            1_000 * 1e6
        );

        assertEq(
            uint256(afterB1[(BASE_WEEK + 10) % 52]),
            2_000 * 1e6
        );

        assertEq(
            uint256(afterB1[(BASE_WEEK + 20) % 52]),
            500 * 1e6
        );

        uint256 bookAfterA = CohortWeeks._laneY1(
            harnessA.viewBookWord(
                refA
            )
        );

        uint256 bookAfterB = CohortWeeks._laneY1(
            harnessB.viewBookWord(
                refA
            )
        );

        assertEq(
            CohortWeeks._laneY1(bookBefore) - bookAfterA,
            bookAfterB
        );

        (
            uint256 stagedAt,
            uint256[] memory leftover
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            stagedAt,
            0
        );

        assertEq(
            leftover.length,
            0
        );
    }

    function test_captureMoveOut_excessBeyondBurn_reducesSaleLikeFirst()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            5_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            2_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                payload[1]
            ),
            2_000 * 1e6
        );
    }

    function test_captureApply_unreferred_stagesTrackedOnly()
        public
    {
        _creditAt(
            harnessA,
            BASE_WEEK,
            4_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000 * 1e6,
            1,
            1
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            payload.length,
            2
        );

        assertEq(
            CohortWeeks._carryEnvelopePairCount(
                payload[0]
            ),
            0
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                payload[1]
            ),
            4_000 * 1e6
        );

        harnessB.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            4_000 * 1e6
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_captureApply_engineRoundTrip_restoresTheOriginSchedule()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_500 * 1e6
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 30,
            2_500 * 1e6
        );

        uint256 originBook = harnessA.viewBookWord(
            refA
        );

        uint256 originTracked = harnessA.viewTracked(
            user1
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000 * 1e6,
            1,
            1
        );

        harnessB.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        harnessB.harnessBurnBalance(
            user1,
            4_000 * 1e6
        );

        harnessB.exposedCaptureMoveOut(
            user1,
            address(harnessA),
            4_000 * 1e6,
            1,
            1
        );

        harnessA.harnessMintBalance(
            user1,
            4_000 * 1e6
        );

        harnessA.exposedApplyMoveIn(
            user1,
            address(harnessB)
        );

        (
            uint64[52] memory final1,
            uint64[52] memory final2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                final2[i],
                0
            );

            if (
                i != BASE_WEEK % 52
                    && i != (BASE_WEEK + 30) % 52
            ) {
                assertEq(
                    final1[i],
                    0
                );
            }
        }

        assertEq(
            uint256(final1[BASE_WEEK % 52]),
            1_500 * 1e6
        );

        assertEq(
            uint256(final1[(BASE_WEEK + 30) % 52]),
            2_500 * 1e6
        );

        assertEq(
            harnessA.viewBookWord(
                refA
            ),
            originBook
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            originTracked
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    struct PartialRoundTrip {
        uint256 week;
        uint256 total;
        uint256 delta;
        uint256 originBook;
        uint256 originTracked;
        uint64[52] origin1;
        uint64[52] origin2;
        uint64[52] afterA1;
        uint64[52] afterA2;
        uint64[52] afterB1;
        uint64[52] afterB2;
        uint64[52] final1;
        uint64[52] final2;
    }

    function testFuzz_captureApply_engineRoundTrip_partialRestoresTheOriginSchedule(
        uint256 _weekSeed,
        uint256 _amountSeed,
        uint256 _deltaSeed
    )
        public
    {
        PartialRoundTrip memory run;

        _referUser1();

        run.week = BASE_WEEK;

        for (uint256 i; i < 4; ++i) {

            run.week += bound(
                uint256(uint8(_weekSeed >> (8 * i))),
                0,
                20
            );

            uint256 amount = bound(
                uint256(uint32(_amountSeed >> (32 * i))),
                1e6,
                3_000 * 1e6
            );

            _creditAt(
                harnessA,
                run.week,
                amount
            );

            run.total += amount;
        }

        harnessA.harnessMintBalance(
            user1,
            run.total
        );

        run.delta = bound(
            _deltaSeed,
            1,
            run.total
        );

        (
            run.origin1,
            run.origin2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        run.originBook = harnessA.viewBookWord(
            refA
        );

        run.originTracked = harnessA.viewTracked(
            user1
        );

        harnessA.harnessBurnBalance(
            user1,
            run.delta
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            run.delta,
            1,
            1
        );

        harnessB.harnessMintBalance(
            user1,
            run.delta
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            run.total - run.delta
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            run.delta
        );

        (
            run.afterA1,
            run.afterA2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        (
            run.afterB1,
            run.afterB2
        ) = _ringSnapshot(
            harnessB,
            refA
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                uint256(run.afterB1[i]),
                uint256(run.origin1[i]) - uint256(run.afterA1[i])
            );

            assertEq(
                uint256(run.afterB2[i]),
                uint256(run.origin2[i]) - uint256(run.afterA2[i])
            );
        }

        harnessB.harnessBurnBalance(
            user1,
            run.delta
        );

        harnessB.exposedCaptureMoveOut(
            user1,
            address(harnessA),
            run.delta,
            1,
            1
        );

        harnessA.harnessMintBalance(
            user1,
            run.delta
        );

        harnessA.exposedApplyMoveIn(
            user1,
            address(harnessB)
        );

        (
            run.final1,
            run.final2
        ) = _ringSnapshot(
            harnessA,
            refA
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                run.final1[i],
                run.origin1[i]
            );

            assertEq(
                run.final2[i],
                run.origin2[i]
            );
        }

        assertEq(
            harnessA.viewBookWord(
                refA
            ),
            run.originBook
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            run.originTracked
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );

        _assertCarryDrained(
            address(harnessA),
            address(harnessB)
        );

        _assertCarryDrained(
            address(harnessB),
            address(harnessA)
        );
    }

    // ---- Section C: failure doctrine + scaling ----

    function test_captureMoveOut_zeroDeficit_noop()
        public
    {
        _referUser1();

        harnessA.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        vm.recordLogs();

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            500 * 1e6,
            1,
            1
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryStaged(address,address,address,uint256,uint256,uint256,uint256,uint256)"
                )
            ),
            0
        );
    }

    function test_captureMoveOut_registryUnset_defersClampAndSkips()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        harnessA.harnessSetRegistry(
            address(0)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harnessA)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            3_000 * 1e6
        );
    }

    function test_captureMoveOut_lookupFails_skipsEntirelyThenRetries()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            3_000 * 1e6
        );

        vm.etch(
            address(registry),
            realCode
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );
    }

    function test_captureMoveOut_revokedVault_clampLandsStagingSkipped()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        registry.setAllowedVault(
            address(harnessA),
            false
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessA)
        );

        emit CohortCarrySkipped(
            user1,
            address(harnessB)
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            stagedAt,
            0
        );
    }

    function test_applyMoveIn_staleStage_discardsAndDrains()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            3_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            3_000 * 1e6,
            1,
            1
        );

        uint256 stagedTime = block.timestamp;

        harnessB.harnessMintBalance(
            user1,
            3_000 * 1e6
        );

        vm.warp(
            block.timestamp + 1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            stagedTime
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            stagedAt,
            0
        );
    }

    function test_applyMoveIn_emptyMailbox_returnsSilently()
        public
    {
        vm.recordLogs();

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryDiscarded(address,address,uint256)"
                )
            ),
            0
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    function test_applyMoveIn_registryUnset_discardsWithZeroStamp()
        public
    {
        harnessB.harnessSetRegistry(
            address(0)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            0
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    function test_applyMoveIn_codelessRegistry_discards()
        public
    {
        harnessB.harnessSetRegistry(
            address(0xDEAD)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            0
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );
    }

    function test_applyMoveIn_malformedPayloads_discardedWholesale()
        public
    {
        uint256[][] memory bads = new uint256[][](5);

        bads[0] = new uint256[](2);

        bads[0][0] = CohortWeeks._packCarryEnvelope(
            refA,
            0
        ) ^ (1 << CohortWeeks.CARRY_VERSION_SHIFT);

        bads[1] = new uint256[](2);

        bads[1][0] = CohortWeeks._packCarryEnvelope(
            refA,
            4
        );

        bads[2] = new uint256[](3);

        bads[2][0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        bads[2][2] = CohortWeeks._packCarryPair(
            1_000,
            52,
            CohortWeeks.CARRY_RING_YEAR1
        );

        bads[3] = new uint256[](3);

        bads[3][0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        bads[3][2] = CohortWeeks._packCarryPair(
            1_000,
            10,
            2
        );

        bads[4] = new uint256[](3);

        bads[4][0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        bads[4][2] = CohortWeeks._packCarryPairsWord(
            CohortWeeks._packCarryPair(
                1_000,
                10,
                CohortWeeks.CARRY_RING_YEAR1
            ),
            CohortWeeks._packCarryPair(
                999,
                11,
                CohortWeeks.CARRY_RING_YEAR1
            )
        );

        bads[2][1] = CohortWeeks._packCarryAmounts(
            1_000,
            0
        );

        bads[3][1] = CohortWeeks._packCarryAmounts(
            1_000,
            0
        );

        bads[4][1] = CohortWeeks._packCarryAmounts(
            1_000,
            0
        );

        harnessB.harnessMintBalance(
            user1,
            1_000
        );

        for (uint256 i; i < bads.length; ++i) {

            registry.stageCarry(
                address(harnessB),
                user1,
                bads[i]
            );

            vm.expectEmit(
                true,
                true,
                false,
                true,
                address(harnessB)
            );

            emit CohortCarryDiscarded(
                user1,
                address(this),
                block.timestamp
            );

            harnessB.exposedApplyMoveIn(
                user1,
                address(this)
            );

            assertEq(
                harnessB.viewTracked(
                    user1
                ),
                0
            );

            assertEq(
                harnessB.viewBookWord(
                    refA
                ),
                0
            );
        }
    }

    function test_captureMoveOut_scaleDown_floorsPerComponent()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_500
        );

        _creditAt(
            harnessA,
            BASE_WEEK + 1,
            2_500
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            4_000,
            1,
            1_000
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                payload[1]
            ),
            4
        );

        assertEq(
            CohortWeeks._carryEnvelopePairCount(
                payload[0]
            ),
            2
        );

        harnessB.harnessMintBalance(
            user1,
            4
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            4
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessB.viewBookWord(
                    refA
                )
            ),
            3
        );
    }

    function test_captureMoveOut_partiallyAttributed_capturesOnlyAttributedAndCarriesFullTracked()
        public
    {
        _creditAt(
            harnessA,
            BASE_WEEK,
            500
        );

        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK + 1,
            1_000
        );

        registry.assignReferrer(
            user2,
            refA
        );

        harnessA.exposedCreditContribution(
            user2,
            2_000
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            1_500
        );

        assertEq(
            harnessA.viewAttributed(
                user1
            ),
            1_000
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            1_500,
            1,
            1
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            harnessA.viewAttributed(
                user1
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessA.viewBookWord(
                    refA
                )
            ),
            2_000
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                payload[1]
            ),
            1_500
        );

        harnessB.harnessMintBalance(
            user1,
            1_500
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            1_500
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            1_000
        );

        assertEq(
            CohortWeeks._laneY1(
                harnessB.viewBookWord(
                    refA
                )
            ),
            1_000
        );
    }

    function test_captureMoveOut_unreferredScaledToZero_stagesNothing()
        public
    {
        _creditAt(
            harnessA,
            BASE_WEEK,
            500
        );

        vm.recordLogs();

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            500,
            1,
            1_000_000
        );

        assertEq(
            _carryTopicCount(
                keccak256(
                    "CohortCarryStaged(address,address,address,uint256,uint256,uint256,uint256,uint256)"
                )
            ),
            0
        );

        assertEq(
            harnessA.viewTracked(
                user1
            ),
            0
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            stagedAt,
            0
        );
    }

    function test_applyMoveIn_lengthOnePayload_discards()
        public
    {
        uint256[] memory payload = new uint256[](1);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            0
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    function test_applyMoveIn_pairCountOverflow_discards()
        public
    {
        uint256[] memory payload = new uint256[](
            CohortWeeks.MAX_CARRY_WORDS
        );

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            200
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    function test_applyMoveIn_oversizeFromHostileRegistry_discards()
        public
    {
        OversizeCarryRegistry hostile = new OversizeCarryRegistry();

        harnessB.harnessSetRegistry(
            address(hostile)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(harnessA),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );
    }

    function test_applyMoveIn_zeroAmountPairSkipped()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            7
        );

        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            7,
            0
        );

        payload[2] = CohortWeeks._packCarryPair(
            0,
            5,
            CohortWeeks.CARRY_RING_YEAR1
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            7
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                5
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                (BASE_WEEK + 1) % CohortWeeks.RING_SLOTS
            ),
            0
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );
    }

    function _assertPayloadDiscarded(
        uint256[] memory _payload
    )
        internal
    {
        registry.stageCarry(
            address(harnessB),
            user1,
            _payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            0
        );

        _assertCarryDrained(
            address(this),
            address(harnessB)
        );
    }

    function test_applyMoveIn_trackedAboveHeadroom_discards()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        harnessB.harnessSetTracked(
            user1,
            400 * 1e6
        );

        harnessB.harnessSetAttributed(
            user1,
            0
        );

        uint256[] memory payload = new uint256[](2);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            0
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            600 * 1e6 + 1,
            0
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            400 * 1e6
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            600 * 1e6,
            0
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            1_000 * 1e6
        );
    }

    function test_applyMoveIn_deficitAboveHeadroom_discardsHonestCarry()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        harnessB.harnessSetTracked(
            user1,
            1_500 * 1e6
        );

        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            100 * 1e6,
            0
        );

        payload[2] = CohortWeeks._packCarryPair(
            100 * 1e6,
            BASE_WEEK % CohortWeeks.RING_SLOTS,
            CohortWeeks.CARRY_RING_YEAR1
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(this),
            block.timestamp
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            1_500 * 1e6
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_applyMoveIn_lanesAboveTracked_discards()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            10_000 * 1e6
        );

        uint256 slot = BASE_WEEK % CohortWeeks.RING_SLOTS;

        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            1_000 * 1e6,
            0
        );

        payload[2] = CohortWeeks._packCarryPair(
            1_000 * 1e6 + 1,
            slot,
            CohortWeeks.CARRY_RING_YEAR1
        );

        _assertPayloadDiscarded(
            payload
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            1_000 * 1e6,
            1
        );

        payload[2] = CohortWeeks._packCarryPair(
            1_000 * 1e6,
            slot,
            CohortWeeks.CARRY_RING_YEAR1
        );

        _assertPayloadDiscarded(
            payload
        );

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            2
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            1_000 * 1e6,
            0
        );

        payload[2] = CohortWeeks._packCarryPairsWord(
            CohortWeeks._packCarryPair(
                500 * 1e6,
                slot,
                CohortWeeks.CARRY_RING_YEAR1
            ),
            CohortWeeks._packCarryPair(
                500 * 1e6 + 1,
                slot,
                CohortWeeks.CARRY_RING_YEAR2
            )
        );

        _assertPayloadDiscarded(
            payload
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                slot
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear2(
                refA,
                slot
            ),
            0
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_applyMoveIn_lanesEqualTracked_appliesAtCeiling()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            10_000 * 1e6
        );

        uint256 slot = BASE_WEEK % CohortWeeks.RING_SLOTS;

        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            2
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            1_000 * 1e6,
            100 * 1e6
        );

        payload[2] = CohortWeeks._packCarryPairsWord(
            CohortWeeks._packCarryPair(
                600 * 1e6,
                slot,
                CohortWeeks.CARRY_RING_YEAR1
            ),
            CohortWeeks._packCarryPair(
                300 * 1e6,
                slot,
                CohortWeeks.CARRY_RING_YEAR2
            )
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessB)
        );

        emit CohortCarryApplied(
            user1,
            address(this),
            refA,
            refA,
            1_000 * 1e6,
            600 * 1e6,
            300 * 1e6,
            100 * 1e6,
            2
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            1_000 * 1e6
        );

        uint256 landSlot = (BASE_WEEK + 1) % CohortWeeks.RING_SLOTS;

        assertEq(
            harnessB.viewRingYear1(
                refA,
                landSlot
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear2(
                refA,
                landSlot
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                slot
            ),
            600 * 1e6
        );

        assertEq(
            harnessB.viewRingYear2(
                refA,
                slot
            ),
            300 * 1e6
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                600 * 1e6,
                300 * 1e6,
                100 * 1e6
            )
        );
    }

    function test_applyMoveIn_matureOverflow_clipsBookLane()
        public
    {
        _referUser1();

        harnessB.harnessMintBalance(
            user1,
            100
        );

        harnessB.harnessSetBookLanes(
            refA,
            0,
            0,
            CohortWeeks.LANE_MASK_80 - 5
        );

        uint256[] memory payload = new uint256[](2);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            0
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            100,
            100
        );

        registry.stageCarry(
            address(harnessB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harnessB)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            95
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(this)
        );

        assertEq(
            CohortWeeks._laneM(
                harnessB.viewBookWord(
                    refA
                )
            ),
            CohortWeeks.LANE_MASK_80
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            100
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            100
        );
    }

    function test_captureMoveOut_scaleUp_capsAtLaneMax()
        public
    {
        _referUser1();

        _creditAt(
            harnessA,
            BASE_WEEK,
            1_000_000 * 1e6
        );

        harnessA.exposedCaptureMoveOut(
            user1,
            address(harnessB),
            1_000_000 * 1e6,
            1e12,
            1
        );

        (
            ,
            uint256[] memory payload
        ) = registry.getCarry(
            address(harnessA),
            address(harnessB),
            user1
        );

        assertEq(
            CohortWeeks._carryPairAmount(
                CohortWeeks._carryPairLo(
                    payload[2]
                )
            ),
            CohortWeeks.RING_LANE_MAX
        );
    }

    // ---- Section D: destination resolution ----

    function _lanePayload(
        uint256 _amount
    )
        internal
        view
        returns (uint256[] memory payload)
    {
        payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            _amount,
            0
        );

        payload[2] = CohortWeeks._packCarryPair(
            _amount,
            BASE_WEEK % CohortWeeks.RING_SLOTS,
            CohortWeeks.CARRY_RING_YEAR1
        );
    }

    function _assertBookDropped(
        MoveInLookupRegistry _hostile,
        uint256 _amount,
        bool _expectLookupFailed
    )
        internal
    {
        harnessB.harnessSetRegistry(
            address(_hostile)
        );

        _hostile.setPayload(
            _lanePayload(
                _amount
            )
        );

        harnessB.harnessMintBalance(
            user1,
            _amount
        );

        if (_expectLookupFailed) {

            vm.expectEmit(
                true,
                false,
                false,
                true,
                address(harnessB)
            );

            emit CohortReferrerLookupFailed(
                user1
            );
        }

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(harnessB)
        );

        emit CohortCarryBookDropped(
            user1,
            address(harnessA),
            refA,
            _amount,
            0,
            1
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            _amount
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            0
        );

        assertEq(
            harnessB.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            harnessB.viewRingYear1(
                refA,
                BASE_WEEK % CohortWeeks.RING_SLOTS
            ),
            0
        );
    }

    function test_applyMoveIn_destinationLookupReverts_bookDroppedTrackedLands()
        public
    {
        _assertBookDropped(
            new MoveInLookupRegistry(
                true
            ),
            2_500 * 1e6,
            true
        );
    }

    function test_applyMoveIn_destinationLookupZero_bookDroppedTrackedLands()
        public
    {
        _assertBookDropped(
            new MoveInLookupRegistry(
                false
            ),
            2_500 * 1e6,
            false
        );
    }

    function test_applyMoveIn_referredTrackedOnlyPayload_landsWithoutLookup()
        public
    {
        MoveInLookupRegistry hostile = new MoveInLookupRegistry(
            true
        );

        harnessB.harnessSetRegistry(
            address(hostile)
        );

        uint256[] memory payload = new uint256[](2);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            0
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            900 * 1e6,
            0
        );

        hostile.setPayload(
            payload
        );

        harnessB.harnessMintBalance(
            user1,
            900 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harnessB)
        );

        emit CohortCarryApplied(
            user1,
            address(harnessA),
            address(0),
            refA,
            900 * 1e6,
            0,
            0,
            0,
            0
        );

        harnessB.exposedApplyMoveIn(
            user1,
            address(harnessA)
        );

        assertEq(
            harnessB.viewTracked(
                user1
            ),
            900 * 1e6
        );

        assertEq(
            harnessB.viewAttributed(
                user1
            ),
            0
        );
    }
}
