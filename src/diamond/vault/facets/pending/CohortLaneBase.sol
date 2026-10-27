// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortBookBase} from "./CohortBookBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortLaneBase: credit, reduction and relocation of book lanes. A
 * credit lands in the current ring-1 slot. A reduction is the sale walk,
 * the only reduction code of the engine: newest first through both rings
 * from the settle cursor, then the mature lane, optionally capturing the
 * taken slots as carry pairs. A relocation (move, flip or bridge) lands
 * every captured pair at the slot of its own credit week, aged by the week
 * boundaries crossed between capture and landing, so a relocated cohort
 * graduates exactly when it would have stayed; mature lands as one amount.
 */
abstract contract CohortLaneBase is CohortBookBase {

    function _creditRingCohort(
        address _referrer,
        uint256 _amount
    )
        internal
    {
        _addRingSlotCohort(
            _referrer,
            cohortRingYear1[_referrer],
            (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS,
            _amount,
            0
        );

        _replantBookCohort(
            _referrer,
            _amount,
            0,
            0
        );
    }

    struct ClampSplit {
        uint256 carryDelta;
        uint256 saleLike;
        uint256 carryCharge;
    }

    struct CarryPairBuffer {
        uint256[] pairs;
        uint256 count;
    }

    function _reduceBookCohort(
        address _referrer,
        uint256 _delta
    )
        internal
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        CarryPairBuffer memory buffer;

        return _reduceBookCohortCore(
            _referrer,
            _delta,
            buffer
        );
    }

    function _reduceBookCohortCaptured(
        address _referrer,
        uint256 _delta
    )
        internal
        returns (
            uint256[] memory pairs,
            uint256 pairCount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        CarryPairBuffer memory buffer;

        buffer.pairs = new uint256[](
            CohortWeeks.MAX_CARRY_PAIRS
        );

        (
            fromYear1,
            fromYear2,
            fromMature
        ) = _reduceBookCohortCore(
            _referrer,
            _delta,
            buffer
        );

        pairs = buffer.pairs;

        pairCount = buffer.count;
    }

    function _reduceBookCohortCore(
        address _referrer,
        uint256 _delta,
        CarryPairBuffer memory _buffer
    )
        private
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        uint256 remaining;

        (
            fromYear1,
            fromYear2,
            remaining
        ) = _walkReduceRingsCohort(
            _referrer,
            _delta,
            _buffer
        );

        uint256 book = cohortBook[_referrer];

        uint256 year1 = CohortWeeks._laneY1(
            book
        );

        uint256 year2 = CohortWeeks._laneY2(
            book
        );

        uint256 mature = CohortWeeks._laneM(
            book
        );

        uint256 clippedTotal;

        uint256 clipped;

        if (fromYear1 > 0) {

            (
                year1,
                clipped
            ) = CohortWeeks._saturatingSub(
                year1,
                fromYear1
            );

            clippedTotal += clipped;
        }

        if (fromYear2 > 0) {

            (
                year2,
                clipped
            ) = CohortWeeks._saturatingSub(
                year2,
                fromYear2
            );

            clippedTotal += clipped;
        }

        if (remaining > 0) {

            (
                mature,
                clipped
            ) = CohortWeeks._saturatingSub(
                mature,
                remaining
            );

            fromMature = remaining - clipped;

            _emitClippedCohort(
                _referrer,
                5,
                0,
                clipped
            );
        }

        cohortBook[_referrer] = CohortWeeks._packLanes(
            year1,
            year2,
            mature
        );

        _emitClippedCohort(
            _referrer,
            2,
            0,
            clippedTotal
        );

        emit CohortBookReduced(
            _referrer,
            _delta,
            fromYear1,
            fromYear2,
            fromMature
        );
    }

    function _walkReduceRingsCohort(
        address _referrer,
        uint256 _delta,
        CarryPairBuffer memory _buffer
    )
        private
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 remaining
        )
    {
        uint256 currentWeek = cohortLastSettle[_referrer]
            / CohortWeeks.WEEK;

        (
            fromYear1,
            remaining
        ) = _walkRingCohort(
            cohortRingYear1[_referrer],
            currentWeek,
            _delta,
            CohortWeeks.CARRY_RING_YEAR1,
            _buffer
        );

        (
            fromYear2,
            remaining
        ) = _walkRingCohort(
            cohortRingYear2[_referrer],
            currentWeek,
            remaining,
            CohortWeeks.CARRY_RING_YEAR2,
            _buffer
        );
    }

    function _walkRingCohort(
        uint64[52] storage _ring,
        uint256 _currentWeek,
        uint256 _remaining,
        uint256 _ringTag,
        CarryPairBuffer memory _buffer
    )
        private
        returns (
            uint256 taken,
            uint256 remaining
        )
    {
        remaining = _remaining;

        for (uint256 back; back < CohortWeeks.RING_SLOTS; ++back) {

            if (remaining == 0) {
                break;
            }

            uint256 slot = (_currentWeek
                + CohortWeeks.RING_SLOTS
                - back) % CohortWeeks.RING_SLOTS;

            uint256 held = uint256(_ring[slot]);

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            _ring[slot] = uint64(held - take);

            remaining -= take;

            taken += take;

            if (_buffer.pairs.length > 0) {

                _buffer.pairs[_buffer.count] = CohortWeeks._packCarryPair(
                    take,
                    slot,
                    _ringTag
                );

                ++_buffer.count;
            }
        }
    }

    function _landCarryCohort(
        address _referrer,
        uint256[] memory _words,
        uint256 _firstPairWord,
        uint256 _pairCount,
        uint256 _captureWeek,
        uint256 _mature
    )
        internal
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature
        )
    {
        mature = _mature;

        for (uint256 i; i < _pairCount; ++i) {

            (
                uint256 lane,
                uint256 amount
            ) = _landCarryPairCohort(
                _referrer,
                CohortWeeks._carryPairOf(
                    _words,
                    _firstPairWord,
                    i
                ),
                _captureWeek
            );

            if (lane == CohortWeeks.CARRY_RING_YEAR1) {
                year1 += amount;
            } else if (lane == CohortWeeks.CARRY_RING_YEAR2) {
                year2 += amount;
            } else {
                mature += amount;
            }
        }

        _replantBookCohort(
            _referrer,
            year1,
            year2,
            mature
        );
    }

    function _landCarryPairCohort(
        address _referrer,
        uint256 _pair,
        uint256 _captureWeek
    )
        private
        returns (
            uint256 lane,
            uint256 amount
        )
    {
        amount = CohortWeeks._carryPairAmount(
            _pair
        );

        uint256 slot;

        (
            slot,
            lane
        ) = CohortWeeks._landedCarryPair(
            _pair,
            _captureWeek,
            block.timestamp / CohortWeeks.WEEK
        );

        if (amount == 0 || lane == CohortWeeks.CARRY_LANE_MATURE) {
            return (
                lane,
                amount
            );
        }

        _addRingSlotCohort(
            _referrer,
            lane == CohortWeeks.CARRY_RING_YEAR1
                ? cohortRingYear1[_referrer]
                : cohortRingYear2[_referrer],
            slot,
            amount,
            lane
        );
    }

    function _addRingSlotCohort(
        address _referrer,
        uint64[52] storage _ring,
        uint256 _slot,
        uint256 _amount,
        uint256 _laneKind
    )
        internal
    {
        (
            uint256 newLane,
            uint256 clipped
        ) = CohortWeeks._saturatingAdd64(
            uint256(_ring[_slot]),
            _amount
        );

        _ring[_slot] = uint64(newLane);

        _emitClippedCohort(
            _referrer,
            _laneKind,
            _slot,
            clipped
        );
    }

    function _replantBookCohort(
        address _referrer,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
    {
        (
            uint256 lanes,
            uint256 clippedTotal
        ) = _addLanesCohort(
            cohortBook[_referrer],
            _year1,
            _year2,
            _mature
        );

        cohortBook[_referrer] = lanes;

        _emitClippedCohort(
            _referrer,
            2,
            0,
            clippedTotal
        );
    }
}
