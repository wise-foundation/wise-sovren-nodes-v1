// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Pure-function fuzz suite for {CohortWeeks}, the FROZEN lane-packing
 * library shared by the cohort book and every crumb word. Covers the
 * lane codec (pack/decode round trip, disjoint-OR composition, and
 * immunity to the crumb-written flag and any stray high bits above the
 * three 80-bit lanes), the three saturating helpers (clip-at-cap for
 * `saturatingAdd80`/`saturatingAdd64` and floor-at-zero for
 * `saturatingSub`, each proven to conserve the algebraic sum or
 * difference across `result` and `clipped`), and a pinned-constant
 * regression test so any accidental edit to the frozen crumb-word
 * geometry (consumed byte for byte by the mainnet hub)
 * fails loudly. No diamond harness is needed: every target
 * function is `pure`, so this suite calls the library directly and
 * relies on Solidity inlining internal library members into the
 * caller. The move-carry codec (envelope, amounts word, packed
 * slot pairs; the same-chain move attribution payload) is covered by the
 * same round-trip/disjointness/pinned-constant treatment in its own
 * section below. The bridge-carry codec (the fixed four-word
 * cross-chain aggregate payload, whose envelope word carries the
 * referrer, codec version 2 and the source chain's capture week)
 * closes the file with the same round-trip/disjointness fuzz over its
 * packers, its own pinned-constant regression, and a table-driven
 * matrix over `bridgeCarryValid` proving the two canonical shapes
 * (referred and tracked-only) pass while each of the seven structural
 * rules (exact length, version, the three reserved-zero regions,
 * zero-referrer lane emptiness, the tracked/lane sum law, the
 * not-all-zero floor and the mint-amount conservation ceiling)
 * rejects in isolation, including the ceiling's exact boundary, the
 * rejected neighbouring versions 1 and 3, and the widest capture week
 * accepted while one week more spills into the envelope's reserved
 * bits. A table and a fuzz law over `ageBridgeCarryLanes` pin the
 * in-flight ageing of the three carried aggregates: no drift when the
 * arrival week is at or before the capture week, one to 52 boundaries
 * moving the year-1 aggregate to the year-2 lane and the year-2
 * aggregate to the mature lane, more than 52 moving everything to
 * mature, and the lane sum preserved throughout.
 */
contract WiseSovrenNodesCohortPackingTest is Test {

    uint256 internal constant MASK_80 = CohortWeeks.LANE_MASK_80;

    uint256 internal constant ADD_UPPER = 2 ** 128;

    function testFuzz_packLanes_laneRoundTripIdentity(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 word = CohortWeeks._packLanes(
            y1,
            y2,
            m
        );

        assertEq(
            CohortWeeks._laneY1(
                word
            ),
            y1
        );

        assertEq(
            CohortWeeks._laneY2(
                word
            ),
            y2
        );

        assertEq(
            CohortWeeks._laneM(
                word
            ),
            m
        );

        assertEq(
            word >> 240,
            0
        );
    }

    function testFuzz_laneDecode_ignoresWrittenBitAndHighBits(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 word = CohortWeeks._packLanes(
            y1,
            y2,
            m
        ) | CohortWeeks.CRUMB_WRITTEN_BIT;

        assertEq(
            CohortWeeks._laneY1(
                word
            ),
            y1
        );

        assertEq(
            CohortWeeks._laneY2(
                word
            ),
            y2
        );

        assertEq(
            CohortWeeks._laneM(
                word
            ),
            m
        );
    }

    function testFuzz_saturatingAdd80_neverExceedsMaskAndConserves(
        uint256 _lane,
        uint256 _add
    )
        external
        pure
    {
        uint256 lane = bound(
            _lane,
            0,
            MASK_80
        );

        uint256 add = bound(
            _add,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks._saturatingAdd80(
            lane,
            add
        );

        assertLe(
            result,
            MASK_80
        );

        assertEq(
            result + clipped,
            lane + add
        );

        if (lane + add > MASK_80) {
            assertGt(
                clipped,
                0
            );
        } else {
            assertEq(
                clipped,
                0
            );

            assertEq(
                result,
                lane + add
            );
        }
    }

    function testFuzz_saturatingAdd64_neverExceedsMaskAndConserves(
        uint256 _lane,
        uint256 _add
    )
        external
        pure
    {
        uint256 lane = bound(
            _lane,
            0,
            CohortWeeks.RING_LANE_MAX
        );

        uint256 add = bound(
            _add,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks._saturatingAdd64(
            lane,
            add
        );

        assertLe(
            result,
            CohortWeeks.RING_LANE_MAX
        );

        assertEq(
            result + clipped,
            lane + add
        );

        if (lane + add > CohortWeeks.RING_LANE_MAX) {
            assertGt(
                clipped,
                0
            );
        } else {
            assertEq(
                clipped,
                0
            );

            assertEq(
                result,
                lane + add
            );
        }
    }

    function testFuzz_saturatingSub_floorsAtZeroAndConserves(
        uint256 _value,
        uint256 _sub
    )
        external
        pure
    {
        uint256 value = bound(
            _value,
            0,
            ADD_UPPER
        );

        uint256 sub = bound(
            _sub,
            0,
            ADD_UPPER
        );

        (
            uint256 result,
            uint256 clipped
        ) = CohortWeeks._saturatingSub(
            value,
            sub
        );

        if (sub <= value) {
            assertEq(
                result,
                value - sub
            );

            assertEq(
                clipped,
                0
            );
        } else {
            assertEq(
                result,
                0
            );

            assertEq(
                clipped,
                sub - value
            );
        }
    }

    function testFuzz_packLanes_isDisjointOr(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
        pure
    {
        uint256 y1 = bound(
            _y1,
            0,
            MASK_80
        );

        uint256 y2 = bound(
            _y2,
            0,
            MASK_80
        );

        uint256 m = bound(
            _m,
            0,
            MASK_80
        );

        uint256 shiftedY2 = y2 << CohortWeeks.LANE_Y2_SHIFT;

        uint256 shiftedM = m << CohortWeeks.LANE_M_SHIFT;

        assertEq(
            CohortWeeks._packLanes(
                y1,
                y2,
                m
            ),
            y1 | shiftedY2 | shiftedM
        );

        assertEq(
            y1 & shiftedY2,
            0
        );

        assertEq(
            y1 & shiftedM,
            0
        );

        assertEq(
            shiftedY2 & shiftedM,
            0
        );
    }

    function test_constants_pinned()
        external
        pure
    {
        assertEq(
            CohortWeeks.WEEK,
            1 weeks
        );

        assertEq(
            CohortWeeks.RING_SLOTS,
            52
        );

        assertEq(
            CohortWeeks.YEAR,
            52 weeks
        );

        assertEq(
            CohortWeeks.MAX_SETTLE_BOUNDARIES,
            104
        );

        assertEq(
            CohortWeeks.LANE_MASK_80,
            (1 << 80) - 1
        );

        assertEq(
            CohortWeeks.CRUMB_WRITTEN_BIT,
            1 << 252
        );

        assertEq(
            CohortWeeks.CRUMB_VERSION,
            1
        );

        assertEq(
            CohortWeeks.RING_LANE_MAX,
            type(uint64).max
        );

        assertEq(
            CohortWeeks.LANE_Y2_SHIFT,
            80
        );

        assertEq(
            CohortWeeks.LANE_M_SHIFT,
            160
        );

        assertEq(
            CohortWeeks.GAP_TO_SHIFT,
            32
        );

        assertEq(
            CohortWeeks.GAP_MATURE_SHIFT,
            64
        );
    }

    // ---- Carry codec ----

    function testFuzz_packCarryEnvelope_roundTripIdentity(
        address _referrer,
        uint256 _pairCount
    )
        external
        pure
    {
        uint256 pairCount = bound(
            _pairCount,
            0,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        uint256 word = CohortWeeks._packCarryEnvelope(
            _referrer,
            pairCount
        );

        assertEq(
            CohortWeeks._carryEnvelopeReferrer(
                word
            ),
            _referrer
        );

        assertEq(
            CohortWeeks._carryEnvelopeVersion(
                word
            ),
            CohortWeeks.CARRY_VERSION
        );

        assertEq(
            CohortWeeks._carryEnvelopePairCount(
                word
            ),
            pairCount
        );

        assertEq(
            word >> 176,
            0
        );
    }

    function testFuzz_packCarryAmounts_roundTripIdentity(
        uint256 _trackedDelta,
        uint256 _mature
    )
        external
        pure
    {
        uint256 trackedDelta = bound(
            _trackedDelta,
            0,
            CohortWeeks.CARRY_HALF_MASK
        );

        uint256 mature = bound(
            _mature,
            0,
            CohortWeeks.CARRY_HALF_MASK
        );

        uint256 word = CohortWeeks._packCarryAmounts(
            trackedDelta,
            mature
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                word
            ),
            trackedDelta
        );

        assertEq(
            CohortWeeks._carryMature(
                word
            ),
            mature
        );
    }

    function testFuzz_packCarryPair_roundTripIdentityAndDisjoint(
        uint256 _amount,
        uint256 _slot,
        uint256 _ring
    )
        external
        pure
    {
        uint256 amount = bound(
            _amount,
            0,
            CohortWeeks.RING_LANE_MAX
        );

        uint256 slot = bound(
            _slot,
            0,
            CohortWeeks.RING_SLOTS - 1
        );

        uint256 ring = bound(
            _ring,
            CohortWeeks.CARRY_RING_YEAR1,
            CohortWeeks.CARRY_RING_YEAR2
        );

        uint256 pair = CohortWeeks._packCarryPair(
            amount,
            slot,
            ring
        );

        assertEq(
            CohortWeeks._carryPairAmount(
                pair
            ),
            amount
        );

        assertEq(
            CohortWeeks._carryPairSlot(
                pair
            ),
            slot
        );

        assertEq(
            CohortWeeks._carryPairRing(
                pair
            ),
            ring
        );

        assertEq(
            pair >> 80,
            0
        );

        uint256 shiftedSlot = slot << CohortWeeks.CARRY_PAIR_SLOT_SHIFT;

        uint256 shiftedRing = ring << CohortWeeks.CARRY_PAIR_RING_SHIFT;

        assertEq(
            pair,
            amount | shiftedSlot | shiftedRing
        );

        assertEq(
            amount & shiftedSlot,
            0
        );

        assertEq(
            amount & shiftedRing,
            0
        );

        assertEq(
            shiftedSlot & shiftedRing,
            0
        );
    }

    function testFuzz_packCarryPairsWord_roundTripIdentity(
        uint256 _amountLo,
        uint256 _slotLo,
        uint256 _amountHi,
        uint256 _slotHi
    )
        external
        pure
    {
        uint256 pairLo = CohortWeeks._packCarryPair(
            bound(
                _amountLo,
                0,
                CohortWeeks.RING_LANE_MAX
            ),
            bound(
                _slotLo,
                0,
                CohortWeeks.RING_SLOTS - 1
            ),
            CohortWeeks.CARRY_RING_YEAR1
        );

        uint256 pairHi = CohortWeeks._packCarryPair(
            bound(
                _amountHi,
                0,
                CohortWeeks.RING_LANE_MAX
            ),
            bound(
                _slotHi,
                0,
                CohortWeeks.RING_SLOTS - 1
            ),
            CohortWeeks.CARRY_RING_YEAR2
        );

        uint256 word = CohortWeeks._packCarryPairsWord(
            pairLo,
            pairHi
        );

        assertEq(
            CohortWeeks._carryPairLo(
                word
            ),
            pairLo
        );

        assertEq(
            CohortWeeks._carryPairHi(
                word
            ),
            pairHi
        );
    }

    function test_carryConstants_pinned()
        external
        pure
    {
        assertEq(
            CohortWeeks.CARRY_VERSION,
            1
        );

        assertEq(
            CohortWeeks.MAX_CARRY_PAIRS,
            104
        );

        assertEq(
            CohortWeeks.MAX_CARRY_PAIRS,
            2 * CohortWeeks.RING_SLOTS
        );

        assertEq(
            CohortWeeks.MAX_CARRY_WORDS,
            54
        );

        assertEq(
            CohortWeeks.MAX_CARRY_WORDS,
            2 + CohortWeeks.RING_SLOTS
        );

        assertEq(
            CohortWeeks.CARRY_RING_YEAR1,
            0
        );

        assertEq(
            CohortWeeks.CARRY_RING_YEAR2,
            1
        );

        assertEq(
            CohortWeeks.CARRY_VERSION_SHIFT,
            160
        );

        assertEq(
            CohortWeeks.CARRY_PAIR_COUNT_SHIFT,
            168
        );

        assertEq(
            CohortWeeks.CARRY_BYTE_MASK,
            0xff
        );

        assertEq(
            CohortWeeks.CARRY_HALF_SHIFT,
            128
        );

        assertEq(
            CohortWeeks.CARRY_HALF_MASK,
            (1 << 128) - 1
        );

        assertEq(
            CohortWeeks.CARRY_PAIR_SLOT_SHIFT,
            64
        );

        assertEq(
            CohortWeeks.CARRY_PAIR_RING_SHIFT,
            72
        );
    }

    // ---- Bridge carry codec ----

    struct CarryValidRow {
        bytes payload;
        uint256 mintAmount;
        bool expected;
        string label;
    }

    struct LandedPairRow {
        uint256 slot;
        uint256 ring;
        uint256 captureWeek;
        uint256 arrivalWeek;
        uint256 landedSlot;
        uint256 landedLane;
        string label;
    }

    function testFuzz_packBridgeCarryEnvelope_roundTripIdentityAndDisjoint(
        address _referrer,
        uint256 _captureWeek,
        uint256 _pairCount
    )
        external
        pure
    {
        uint256 captureWeek = bound(
            _captureWeek,
            0,
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK
        );

        uint256 pairCount = bound(
            _pairCount,
            0,
            CohortWeeks.CARRY_BYTE_MASK
        );

        uint256 word = CohortWeeks._packBridgeCarryEnvelope(
            _referrer,
            captureWeek,
            pairCount
        );

        assertEq(
            CohortWeeks._carryEnvelopeReferrer(
                word
            ),
            _referrer
        );

        assertEq(
            CohortWeeks._carryEnvelopeVersion(
                word
            ),
            CohortWeeks.BRIDGE_CARRY_VERSION
        );

        assertEq(
            CohortWeeks._carryEnvelopeVersion(
                word
            ),
            3
        );

        assertEq(
            CohortWeeks._bridgeCarryCaptureWeek(
                word
            ),
            captureWeek
        );

        assertEq(
            CohortWeeks._bridgeCarryPairCount(
                word
            ),
            pairCount
        );

        assertEq(
            word >> CohortWeeks.BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT,
            0
        );

        uint256 shiftedVersion = CohortWeeks.BRIDGE_CARRY_VERSION
            << CohortWeeks.CARRY_VERSION_SHIFT;

        uint256 shiftedCaptureWeek = captureWeek
            << CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_SHIFT;

        uint256 shiftedPairCount = pairCount
            << CohortWeeks.BRIDGE_CARRY_PAIR_COUNT_SHIFT;

        assertEq(
            word,
            uint256(uint160(_referrer))
                | shiftedVersion
                | shiftedCaptureWeek
                | shiftedPairCount
        );

        assertEq(
            uint256(uint160(_referrer)) & shiftedVersion,
            0
        );

        assertEq(
            uint256(uint160(_referrer)) & shiftedCaptureWeek,
            0
        );

        assertEq(
            shiftedVersion & shiftedCaptureWeek,
            0
        );

        assertEq(
            shiftedCaptureWeek & shiftedPairCount,
            0
        );
    }

    function testFuzz_packBridgeCarryTracked_roundTripIdentityAndDisjoint(
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank
    )
        external
        pure
    {
        uint256 trackedDelta = bound(
            _trackedDelta,
            0,
            CohortWeeks.CARRY_HALF_MASK
        );

        uint256 assignedAt = bound(
            _assignedAt,
            0,
            CohortWeeks.RING_LANE_MAX
        );

        uint256 rank = bound(
            _rank,
            0,
            CohortWeeks.CARRY_BYTE_MASK
        );

        uint256 word = CohortWeeks._packBridgeCarryTracked(
            trackedDelta,
            assignedAt,
            rank
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                word
            ),
            trackedDelta
        );

        assertEq(
            CohortWeeks._bridgeCarryAssignedAt(
                word
            ),
            assignedAt
        );

        assertEq(
            CohortWeeks._bridgeCarryRank(
                word
            ),
            rank
        );

        assertEq(
            word >> CohortWeeks.BRIDGE_CARRY_TRACKED_RESERVED_SHIFT,
            0
        );

        uint256 shiftedAssignedAt = assignedAt << CohortWeeks.BRIDGE_CARRY_ASSIGNED_AT_SHIFT;

        uint256 shiftedRank = rank << CohortWeeks.BRIDGE_CARRY_RANK_SHIFT;

        assertEq(
            word,
            trackedDelta | shiftedAssignedAt | shiftedRank
        );

        assertEq(
            trackedDelta & shiftedAssignedAt,
            0
        );

        assertEq(
            trackedDelta & shiftedRank,
            0
        );

        assertEq(
            shiftedAssignedAt & shiftedRank,
            0
        );
    }

    function testFuzz_packBridgeCarry_wordsRoundTripIdentity(
        uint256 _seed,
        uint256 _wordCount
    )
        external
        pure
    {
        uint256 wordCount = bound(
            _wordCount,
            0,
            CohortWeeks.BRIDGE_CARRY_BYTES / 32
        );

        uint256[] memory words = new uint256[](
            wordCount
        );

        for (uint256 i; i < wordCount; ++i) {
            words[i] = uint256(
                keccak256(
                    abi.encode(
                        _seed,
                        i
                    )
                )
            );
        }

        bytes memory data = CohortWeeks._packBridgeCarry(
            words
        );

        assertEq(
            data.length,
            32 * wordCount
        );

        uint256[] memory unpacked = CohortWeeks._unpackBridgeCarry(
            data
        );

        assertEq(
            unpacked.length,
            wordCount
        );

        for (uint256 i; i < wordCount; ++i) {
            assertEq(
                unpacked[i],
                words[i]
            );
        }
    }

    function test_bridgeCarryValid_ruleTable()
        external
        pure
    {
        address referrer = address(0xBEEF);

        uint256 captureWeek = 3_000;

        uint256 slot = captureWeek % 52;

        uint256 word0 = CohortWeeks._packBridgeCarryEnvelope(
            referrer,
            captureWeek,
            2
        );

        uint256 word1 = CohortWeeks._packBridgeCarryTracked(
            60,
            123_456,
            3
        );

        uint256 pairWord = CohortWeeks._packCarryPairsWord(
            CohortWeeks._packCarryPair(
                10,
                slot,
                0
            ),
            CohortWeeks._packCarryPair(
                20,
                slot,
                1
            )
        );

        bytes memory base = _carryBytes(
            word0,
            word1,
            30,
            pairWord
        );

        CarryValidRow[] memory rows = new CarryValidRow[](26);

        rows[0] = CarryValidRow(
            base,
            100,
            true,
            "referred payload valid"
        );

        rows[1] = CarryValidRow(
            _carryHeaderBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    address(0),
                    captureWeek,
                    0
                ),
                CohortWeeks._packBridgeCarryTracked(
                    40,
                    123_456,
                    3
                ),
                0
            ),
            100,
            true,
            "unreferred tracked-only payload valid"
        );

        rows[2] = CarryValidRow(
            _resizedCarry(
                base,
                127
            ),
            100,
            false,
            "length 127 rejected"
        );

        rows[3] = CarryValidRow(
            _resizedCarry(
                base,
                129
            ),
            100,
            false,
            "length 129 rejected"
        );

        rows[4] = CarryValidRow(
            _resizedCarry(
                base,
                64
            ),
            100,
            false,
            "length shorter than the header rejected"
        );

        rows[5] = CarryValidRow(
            _resizedCarry(
                base,
                CohortWeeks.BRIDGE_CARRY_BYTES + 32
            ),
            100,
            false,
            "length above the maximum rejected"
        );

        rows[6] = CarryValidRow(
            _carryBytes(
                uint256(uint160(referrer))
                    | (captureWeek << CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_SHIFT)
                    | (2 << CohortWeeks.BRIDGE_CARRY_PAIR_COUNT_SHIFT),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "version zero rejected"
        );

        rows[7] = CarryValidRow(
            _carryBytes(
                word0
                    ^ (1 << CohortWeeks.CARRY_VERSION_SHIFT),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "version two rejected"
        );

        rows[8] = CarryValidRow(
            _carryBytes(
                word0 | (1 << CohortWeeks.BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "envelope reserved bit rejected"
        );

        rows[9] = CarryValidRow(
            _carryBytes(
                word0,
                word1 | (1 << CohortWeeks.BRIDGE_CARRY_TRACKED_RESERVED_SHIFT),
                30,
                pairWord
            ),
            100,
            false,
            "tracked-word reserved bit rejected"
        );

        rows[10] = CarryValidRow(
            _carryBytes(
                word0,
                word1,
                30 | (1 << CohortWeeks.CARRY_HALF_SHIFT),
                pairWord
            ),
            100,
            false,
            "mature-word high half rejected"
        );

        rows[11] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    referrer,
                    captureWeek,
                    3
                ),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "pair count above the pair words rejected"
        );

        rows[12] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    referrer,
                    captureWeek,
                    1
                ),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "odd pair count with a filled high half rejected"
        );

        rows[13] = CarryValidRow(
            _carryBytes(
                word0,
                word1,
                30,
                pairWord | (1 << CohortWeeks.CARRY_PAIR_RESERVED_SHIFT)
            ),
            100,
            false,
            "pair reserved bit rejected"
        );

        rows[14] = CarryValidRow(
            _carryBytes(
                word0,
                word1,
                30,
                CohortWeeks._packCarryPairsWord(
                    CohortWeeks._packCarryPair(
                        10,
                        52,
                        0
                    ),
                    CohortWeeks._packCarryPair(
                        20,
                        slot,
                        1
                    )
                )
            ),
            100,
            false,
            "pair slot 52 rejected"
        );

        rows[15] = CarryValidRow(
            _carryBytes(
                word0,
                word1,
                30,
                CohortWeeks._packCarryPairsWord(
                    CohortWeeks._packCarryPair(
                        10,
                        slot,
                        0
                    ),
                    CohortWeeks._packCarryPair(
                        20,
                        slot,
                        2
                    )
                )
            ),
            100,
            false,
            "pair ring 2 rejected"
        );

        rows[16] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    address(0),
                    captureWeek,
                    2
                ),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "zero referrer with lanes rejected"
        );

        rows[17] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    address(0),
                    captureWeek,
                    1
                ),
                word1,
                0,
                CohortWeeks._packCarryPair(
                    0,
                    slot,
                    0
                )
            ),
            100,
            false,
            "zero referrer with an empty pair rejected"
        );

        rows[18] = CarryValidRow(
            _carryBytes(
                word0,
                CohortWeeks._packBridgeCarryTracked(
                    61,
                    123_456,
                    3
                ),
                30,
                pairWord
            ),
            100,
            true,
            "lane sum below trackedDelta accepted"
        );

        rows[19] = CarryValidRow(
            _carryBytes(
                word0,
                CohortWeeks._packBridgeCarryTracked(
                    59,
                    123_456,
                    3
                ),
                30,
                pairWord
            ),
            100,
            false,
            "lane sum above trackedDelta rejected"
        );

        rows[20] = CarryValidRow(
            _carryHeaderBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    referrer,
                    captureWeek,
                    0
                ),
                CohortWeeks._packBridgeCarryTracked(
                    0,
                    123_456,
                    3
                ),
                0
            ),
            100,
            false,
            "all-zero amounts rejected"
        );

        rows[21] = CarryValidRow(
            base,
            60,
            true,
            "trackedDelta equal to mint amount accepted"
        );

        rows[22] = CarryValidRow(
            base,
            59,
            false,
            "trackedDelta above mint amount rejected"
        );

        rows[23] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    referrer,
                    CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK,
                    2
                ),
                word1,
                30,
                pairWord
            ),
            100,
            true,
            "widest capture week accepted"
        );

        rows[24] = CarryValidRow(
            _carryBytes(
                CohortWeeks._packBridgeCarryEnvelope(
                    referrer,
                    CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK + 1,
                    2
                ),
                word1,
                30,
                pairWord
            ),
            100,
            false,
            "capture week spilling into the pair count rejected"
        );

        rows[25] = CarryValidRow(
            _fullBookCarry(
                referrer,
                captureWeek
            ),
            CohortWeeks.MAX_CARRY_PAIRS,
            true,
            "full 104 pair book at the maximum length accepted"
        );

        for (uint256 i; i < rows.length; ++i) {

            assertEq(
                CohortWeeks._bridgeCarryValid(
                    rows[i].payload,
                    rows[i].mintAmount
                ),
                rows[i].expected,
                rows[i].label
            );
        }
    }

    function test_bridgeCarryConstants_pinned()
        external
        pure
    {
        assertEq(
            CohortWeeks.BRIDGE_CARRY_VERSION,
            3
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
            3
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES,
            32 * CohortWeeks.BRIDGE_CARRY_HEADER_WORDS
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_BYTES,
            1_760
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_BYTES,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES
                + 32 * (CohortWeeks.MAX_CARRY_PAIRS / 2)
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_ASSIGNED_AT_SHIFT,
            128
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_RANK_SHIFT,
            192
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_SHIFT,
            168
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK,
            (1 << 32) - 1
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_PAIR_COUNT_SHIFT,
            200
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT,
            208
        );

        assertEq(
            CohortWeeks.BRIDGE_CARRY_TRACKED_RESERVED_SHIFT,
            200
        );

        assertEq(
            CohortWeeks.CARRY_PAIR_RESERVED_SHIFT,
            80
        );

        assertEq(
            CohortWeeks.CARRY_LANE_MATURE,
            2
        );
    }

    function test_landedCarryPair_table()
        external
        pure
    {
        LandedPairRow[] memory rows = new LandedPairRow[](10);

        rows[0] = LandedPairRow(
            36,
            0,
            3_000,
            3_000,
            36,
            0,
            "a fresh pair lands at its own slot"
        );

        rows[1] = LandedPairRow(
            36,
            0,
            3_000,
            3_001,
            36,
            0,
            "one boundary keeps a fresh pair on ring one"
        );

        rows[2] = LandedPairRow(
            37,
            0,
            3_000,
            3_001,
            37,
            1,
            "the last year-one week crosses to ring two at its slot"
        );

        rows[3] = LandedPairRow(
            37,
            1,
            3_000,
            3_001,
            0,
            2,
            "the last year-two week crosses to mature"
        );

        rows[4] = LandedPairRow(
            36,
            1,
            3_000,
            3_000,
            36,
            1,
            "a ring-two pair keeps its ring and slot"
        );

        rows[5] = LandedPairRow(
            36,
            0,
            3_000,
            2_999,
            35,
            0,
            "a pair younger than the lag lands in the arrival week"
        );

        rows[6] = LandedPairRow(
            36,
            0,
            3_000,
            3_052,
            36,
            1,
            "52 boundaries move a fresh pair to ring two"
        );

        rows[7] = LandedPairRow(
            36,
            0,
            3_000,
            4_000,
            0,
            2,
            "1000 boundaries mature everything"
        );

        rows[8] = LandedPairRow(
            30,
            0,
            3_000,
            2_998,
            30,
            0,
            "a lag behind capture keeps the credit week slot"
        );

        rows[9] = LandedPairRow(
            37,
            1,
            3_000,
            2_999,
            37,
            1,
            "a lag takes one week off a ring-two pair at its slot"
        );

        for (uint256 i; i < rows.length; ++i) {

            (
                uint256 landedSlot,
                uint256 landedLane
            ) = CohortWeeks._landedCarryPair(
                CohortWeeks._packCarryPair(
                    1,
                    rows[i].slot,
                    rows[i].ring
                ),
                rows[i].captureWeek,
                rows[i].arrivalWeek
            );

            assertEq(
                landedSlot,
                rows[i].landedSlot,
                rows[i].label
            );

            assertEq(
                landedLane,
                rows[i].landedLane,
                rows[i].label
            );
        }
    }

    function testFuzz_landedCarryPair_keepsSlotAndAgesByBoundaries(
        uint256 _slot,
        uint256 _ring,
        uint256 _captureWeek,
        uint256 _boundaries
    )
        external
        pure
    {
        uint256 slot = bound(
            _slot,
            0,
            51
        );

        uint256 ring = bound(
            _ring,
            0,
            1
        );

        uint256 captureWeek = bound(
            _captureWeek,
            52,
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK
        );

        uint256 boundaries = bound(
            _boundaries,
            0,
            300
        );

        uint256 age = (captureWeek + 52 - slot) % 52 + ring * 52;

        (
            uint256 landedSlot,
            uint256 landedLane
        ) = CohortWeeks._landedCarryPair(
            CohortWeeks._packCarryPair(
                1,
                slot,
                ring
            ),
            captureWeek,
            captureWeek + boundaries
        );

        if (age + boundaries >= 104) {

            assertEq(
                landedLane,
                CohortWeeks.CARRY_LANE_MATURE
            );

            return;
        }

        assertEq(
            landedSlot,
            slot
        );

        assertEq(
            landedLane,
            (age + boundaries) / 52
        );
    }

    function testFuzz_landedCarryPair_lagBehindCaptureFloorsAgeAtArrival(
        uint256 _slot,
        uint256 _ring,
        uint256 _captureWeek,
        uint256 _lag
    )
        external
        pure
    {
        uint256 slot = bound(
            _slot,
            0,
            51
        );

        uint256 ring = bound(
            _ring,
            0,
            1
        );

        uint256 captureWeek = bound(
            _captureWeek,
            400,
            CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_MASK
        );

        uint256 lag = bound(
            _lag,
            1,
            300
        );

        uint256 age = (captureWeek + 52 - slot) % 52 + ring * 52;

        (
            uint256 landedSlot,
            uint256 landedLane
        ) = CohortWeeks._landedCarryPair(
            CohortWeeks._packCarryPair(
                1,
                slot,
                ring
            ),
            captureWeek,
            captureWeek - lag
        );

        if (lag >= age) {

            assertEq(
                landedSlot,
                (captureWeek - lag) % 52
            );

            assertEq(
                landedLane,
                0
            );

            return;
        }

        assertEq(
            landedSlot,
            slot
        );

        assertEq(
            landedLane,
            (age - lag) / 52
        );
    }

    function _carryHeaderBytes(
        uint256 _word0,
        uint256 _word1,
        uint256 _mature
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            _word0,
            _word1,
            _mature
        );
    }

    function _carryBytes(
        uint256 _word0,
        uint256 _word1,
        uint256 _mature,
        uint256 _pairWord
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            _word0,
            _word1,
            _mature,
            _pairWord
        );
    }

    function _fullBookCarry(
        address _referrer,
        uint256 _captureWeek
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](
            3 + CohortWeeks.MAX_CARRY_PAIRS / 2
        );

        words[0] = CohortWeeks._packBridgeCarryEnvelope(
            _referrer,
            _captureWeek,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        words[1] = CohortWeeks._packBridgeCarryTracked(
            CohortWeeks.MAX_CARRY_PAIRS,
            123_456,
            3
        );

        for (uint256 i; i < CohortWeeks.MAX_CARRY_PAIRS / 2; ++i) {
            words[3 + i] = CohortWeeks._packCarryPairsWord(
                CohortWeeks._packCarryPair(
                    1,
                    i,
                    0
                ),
                CohortWeeks._packCarryPair(
                    1,
                    i,
                    1
                )
            );
        }

        return CohortWeeks._packBridgeCarry(
            words
        );
    }

    function _resizedCarry(
        bytes memory _data,
        uint256 _length
    )
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(
            _length
        );

        uint256 copyLength = _length < _data.length
            ? _length
            : _data.length;

        for (uint256 i; i < copyLength; ++i) {
            out[i] = _data[i];
        }
    }
}
