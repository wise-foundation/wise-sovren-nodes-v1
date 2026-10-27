// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortPinnedBase} from "./CohortPinnedBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortBookBase: the referrer book of the cohort recorder. A book is
 * one word of three 80-bit lanes (year-1, year-2, mature) plus two 52-slot
 * rings that graduate credit at weekly boundaries. Every path that mutates
 * a book settles it first. A settle walks at most MAX_SETTLE_BOUNDARIES
 * boundaries, writes one crumb per completed week (a gap record for a
 * dormant tail) and counts only the seconds outside the disarm span
 * [cohortDisarmedAt, cohortRearmedAt). The bounded advance parks the
 * cursor at a disarm start until one week after the re-arm. Nothing here
 * reverts: lanes saturate and emit CohortLaneSaturated, because this code
 * runs inside the transfer hook and ccipReceive.
 */
abstract contract CohortBookBase is CohortPinnedBase {

    function _settleBookCohort(
        address _referrer
    )
        internal
    {
        _settleBookCohortTo(
            _referrer,
            block.timestamp
        );
    }

    function _settleBookCohortTo(
        address _referrer,
        uint256 _to
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last >= _to) {
            return;
        }

        if (last == 0) {

            cohortLastSettle[_referrer] = _to;

            emit CohortBookSettled(
                _referrer,
                0,
                _to,
                0
            );

            return;
        }

        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        (
            uint256 cursor,
            uint256 steps
        ) = _walkBookBoundariesCohort(
            _referrer,
            last,
            _to,
            CohortWeeks.MAX_SETTLE_BOUNDARIES,
            false,
            disarmedAt,
            rearmedAt
        );

        uint256 latestBoundary = (_to
            / CohortWeeks.WEEK)
            * CohortWeeks.WEEK;

        if (latestBoundary > cursor) {
            cursor = _recordGapSpanCohort(
                _referrer,
                cursor,
                latestBoundary,
                disarmedAt,
                rearmedAt
            );
        }

        if (_to > cursor) {
            _recordSegmentCohort(
                _referrer,
                cursor,
                _to,
                disarmedAt,
                rearmedAt
            );
        }

        cohortLastSettle[_referrer] = _to;

        emit CohortBookSettled(
            _referrer,
            last,
            _to,
            steps
        );
    }

    function _advanceBookCohort(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == 0) {
            return;
        }

        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        (
            uint256 cursor,
            uint256 steps
        ) = _walkBookBoundariesCohort(
            _referrer,
            last,
            block.timestamp,
            _maxBoundaries,
            true,
            disarmedAt,
            rearmedAt
        );

        if (cursor == last) {
            return;
        }

        cohortLastSettle[_referrer] = cursor;

        emit CohortBookSettled(
            _referrer,
            last,
            cursor,
            steps
        );
    }

    function _walkBookBoundariesCohort(
        address _referrer,
        uint256 _from,
        uint256 _bound,
        uint256 _maxSteps,
        bool _parkAtDisarm,
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
        returns (
            uint256 cursor,
            uint256 steps
        )
    {
        cursor = _from;

        while (steps < _maxSteps && steps < CohortWeeks.MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor
                / CohortWeeks.WEEK
                + 1)
                * CohortWeeks.WEEK;

            if (next > _bound) {
                break;
            }

            if (
                _parkAtDisarm
                    && next > _disarmedAt
                    && _parkedAtDisarmCohort(
                        cursor,
                        _disarmedAt,
                        _rearmedAt
                    )
            ) {

                if (cursor < _disarmedAt) {

                    _recordSegmentCohort(
                        _referrer,
                        cursor,
                        _disarmedAt,
                        _disarmedAt,
                        _rearmedAt
                    );

                    cursor = _disarmedAt;
                }

                break;
            }

            _recordSegmentCohort(
                _referrer,
                cursor,
                next,
                _disarmedAt,
                _rearmedAt
            );

            _rotateCohort(
                _referrer,
                next / CohortWeeks.WEEK
            );

            cursor = next;

            ++steps;
        }
    }

    function _recordSegmentCohort(
        address _referrer,
        uint256 _from,
        uint256 _to,
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
    {
        uint256 book = cohortBook[_referrer];

        if (book == 0) {
            return;
        }

        uint256 dt = CohortWeeks._liveSecondsCohort(
            _from,
            _to,
            _disarmedAt,
            _rearmedAt
        );

        if (dt == 0) {
            return;
        }

        _writeCrumbCohort(
            _referrer,
            _from / CohortWeeks.WEEK,
            CohortWeeks._laneY1(
                book
            ) * dt,
            CohortWeeks._laneY2(
                book
            ) * dt,
            CohortWeeks._laneM(
                book
            ) * dt
        );
    }

    function _writeCrumbCohort(
        address _referrer,
        uint256 _week,
        uint256 _y1Seconds,
        uint256 _y2Seconds,
        uint256 _mSeconds
    )
        internal
    {
        uint256 crumb = cohortWeekLog[_referrer][_week];

        if (crumb & CohortWeeks.CRUMB_WRITTEN_BIT == 0) {
            crumb = CohortWeeks.CRUMB_WRITTEN_BIT;
        }

        (
            uint256 lanes,
            uint256 clippedTotal
        ) = _addLanesCohort(
            crumb,
            _y1Seconds,
            _y2Seconds,
            _mSeconds
        );

        cohortWeekLog[_referrer][_week] = (
            crumb & ~(
                CohortWeeks.LANE_MASK_80
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_Y2_SHIFT)
                    | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_M_SHIFT)
            )
        ) | lanes;

        _emitClippedCohort(
            _referrer,
            3,
            _week,
            clippedTotal
        );
    }

    function _emitClippedCohort(
        address _referrer,
        uint256 _laneKind,
        uint256 _index,
        uint256 _clippedAmount
    )
        internal
    {
        if (_clippedAmount == 0) {
            return;
        }

        emit CohortLaneSaturated(
            _referrer,
            _laneKind,
            _index,
            _clippedAmount
        );
    }

    function _recordGapCohort(
        address _referrer,
        uint256 _from,
        uint256 _toBoundary
    )
        internal
        returns (uint256)
    {
        uint256 mature = CohortWeeks._laneM(
            cohortBook[_referrer]
        );

        uint256 fromWeek = _from
            / CohortWeeks.WEEK;

        uint256 toWeekExclusive = _toBoundary
            / CohortWeeks.WEEK;

        if (mature > 0) {

            cohortGapLog[_referrer].push(
                CohortWeeks._packGapRecord(
                    fromWeek,
                    toWeekExclusive,
                    mature
                )
            );

            emit CohortGapRecorded(
                _referrer,
                fromWeek,
                toWeekExclusive,
                mature
            );
        }

        return _toBoundary;
    }

    function _recordGapSpanCohort(
        address _referrer,
        uint256 _from,
        uint256 _toBoundary,
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
        returns (uint256)
    {
        if (
            _rearmedAt <= _disarmedAt
                || _disarmedAt >= _toBoundary
                || _rearmedAt <= _from
        ) {
            return _recordGapCohort(
                _referrer,
                _from,
                _toBoundary
            );
        }

        uint256 headEnd = _from;

        if (_disarmedAt > _from) {
            headEnd = (_disarmedAt
                / CohortWeeks.WEEK)
                * CohortWeeks.WEEK;
        }

        if (headEnd > _from) {
            _recordGapCohort(
                _referrer,
                _from,
                headEnd
            );
        }

        uint256 tailStart = _toBoundary;

        if (_rearmedAt < _toBoundary) {
            tailStart = ((_rearmedAt - 1)
                / CohortWeeks.WEEK
                + 1)
                * CohortWeeks.WEEK;
        }

        _recordSegmentCohort(
            _referrer,
            headEnd,
            headEnd + CohortWeeks.WEEK,
            _disarmedAt,
            _rearmedAt
        );

        if (tailStart - CohortWeeks.WEEK > headEnd) {
            _recordSegmentCohort(
                _referrer,
                tailStart - CohortWeeks.WEEK,
                tailStart,
                _disarmedAt,
                _rearmedAt
            );
        }

        if (_toBoundary > tailStart) {
            _recordGapCohort(
                _referrer,
                tailStart,
                _toBoundary
            );
        }

        return _toBoundary;
    }

    function _rotateCohort(
        address _referrer,
        uint256 _boundaryWeek
    )
        internal
    {
        uint256 slot = _boundaryWeek % CohortWeeks.RING_SLOTS;

        uint256 graduatingYear2 = uint256(cohortRingYear2[_referrer][slot]);

        uint256 graduatingYear1 = uint256(cohortRingYear1[_referrer][slot]);

        if (graduatingYear1 == 0 && graduatingYear2 == 0) {
            return;
        }

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

        if (graduatingYear2 > 0) {

            (
                year2,
                mature,
                clipped
            ) = _shiftLaneCohort(
                year2,
                mature,
                graduatingYear2
            );

            clippedTotal += clipped;
        }

        if (graduatingYear1 > 0) {

            (
                year1,
                year2,
                clipped
            ) = _shiftLaneCohort(
                year1,
                year2,
                graduatingYear1
            );

            clippedTotal += clipped;

            cohortRingYear1[_referrer][slot] = 0;
        }

        if (graduatingYear1 != graduatingYear2) {
            cohortRingYear2[_referrer][slot] = uint64(graduatingYear1);
        }

        cohortBook[_referrer] = CohortWeeks._packLanes(
            year1,
            year2,
            mature
        );

        _emitClippedCohort(
            _referrer,
            2,
            slot,
            clippedTotal
        );
    }

    function _shiftLaneCohort(
        uint256 _from,
        uint256 _to,
        uint256 _amount
    )
        internal
        pure
        returns (
            uint256 from,
            uint256 to,
            uint256 clipped
        )
    {
        uint256 clippedTo;

        uint256 clippedFrom;

        (
            to,
            clippedTo
        ) = CohortWeeks._saturatingAdd80(
            _to,
            _amount
        );

        (
            from,
            clippedFrom
        ) = CohortWeeks._saturatingSub(
            _from,
            _amount
        );

        clipped = clippedTo + clippedFrom;
    }

    function _addLanesCohort(
        uint256 _word,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        pure
        returns (
            uint256 lanes,
            uint256 clippedTotal
        )
    {
        (
            uint256 year1,
            uint256 clippedYear1
        ) = CohortWeeks._saturatingAdd80(
            CohortWeeks._laneY1(
                _word
            ),
            _year1
        );

        (
            uint256 year2,
            uint256 clippedYear2
        ) = CohortWeeks._saturatingAdd80(
            CohortWeeks._laneY2(
                _word
            ),
            _year2
        );

        (
            uint256 mature,
            uint256 clippedMature
        ) = CohortWeeks._saturatingAdd80(
            CohortWeeks._laneM(
                _word
            ),
            _mature
        );

        lanes = CohortWeeks._packLanes(
            year1,
            year2,
            mature
        );

        clippedTotal = clippedYear1
            + clippedYear2
            + clippedMature;
    }
}
