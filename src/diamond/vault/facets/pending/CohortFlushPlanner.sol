// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortPinnedBase} from "./CohortPinnedBase.sol";
import {CohortFlushCodec} from "../../../shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortFlushPlanner: builds the flush envelope entries from storage.
 * Everything sent is storage derived; the caller chooses only the
 * referrers and the timing, so every caller sends the same numbers. Only
 * closed weeks are planned: each carries its own crumb and its own
 * completed self presence (read from the self log, or from the self crumb
 * for weeks after its last settle, read the way the next settle would
 * write them: a crumb settled before a disarm counts its stake up to the
 * disarm and no presence after it, whether the span is closed or still
 * open, and a zero length span counts as no span), sent
 * as runs of equal weekly averages, so the hub prices a week from that
 * week alone. Weeks, crumbs and gap slices are planned within
 * MAX_FLUSH_ENTRIES, MAX_SETTLE_BOUNDARIES and MAX_FLUSH_WORK (a crumb, a
 * self week and a gap week each cost one; LOCAL_FLUSH_WORK on the hub
 * chain, where the same transaction also pays the hub intake), with
 * GAP_WORK_RESERVE held for
 * the gap lane; a gap record exhausted by its cursor is skipped even when
 * no work is left, and a book parked at a disarm keeps its through week
 * below the disarm week. The payout designation is read from the
 * registry by a guarded staticcall in CCIP mode only.
 */
abstract contract CohortFlushPlanner is CohortPinnedBase {

    uint256 internal constant GAP_WORK_RESERVE = 40;

    uint256 internal constant LOCAL_FLUSH_WORK = 96;

    uint256 internal constant LOCAL_FLUSH_ENTRIES = 6;

    struct FlushEntryData {
        address referrer;
        uint256 designationWord;
        uint256[] selfRuns;
        uint256[] crumbWeeks;
        uint256[] crumbWords;
        uint256[] gapSlices;
        uint256 throughWeek;
        uint256 gapIndex;
        uint256 gapResumeWeek;
        uint256 workUsed;
    }

    function _windowGapResumeWeek(
        address _referrer,
        uint256 _fromGapIndex
    )
        internal
        view
        returns (uint256)
    {
        uint256 cursor = flushGapCursor[_referrer];

        if (_fromGapIndex == cursor & CohortWeeks.CARRY_HALF_MASK) {
            return cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT;
        }

        return 0;
    }

    function _gapWorkWaiting(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResumeWeek
    )
        internal
        view
        returns (bool)
    {
        uint256 length = cohortGapLog[_referrer].length;

        if (_gapIndex >= length) {
            return false;
        }

        uint256 record = cohortGapLog[_referrer][_gapIndex];

        uint256 sliceFrom = CohortWeeks._gapRecordFromWeek(
            record
        );

        if (_gapResumeWeek > sliceFrom) {
            sliceFrom = _gapResumeWeek;
        }

        return sliceFrom < CohortWeeks._gapRecordToWeek(
            record
        );
    }

    function _flushWorkBudget()
        internal
        view
        returns (uint256)
    {
        if (flushHubChainSelector == 0) {
            return LOCAL_FLUSH_WORK;
        }

        return CohortFlushCodec.MAX_FLUSH_WORK;
    }

    function _planFlushBatch(
        address[] calldata _referrers
    )
        internal
        view
        returns (FlushEntryData[] memory entries)
    {
        uint256 currentWeek = block.timestamp
            / CohortWeeks.WEEK;

        uint256 budget = _flushWorkBudget();

        entries = new FlushEntryData[](
            _referrers.length
        );

        for (uint256 i; i < _referrers.length; ++i) {

            uint256 gapCursor = flushGapCursor[_referrers[i]];

            entries[i] = _planFlushEntry(
                _referrers[i],
                _cursorFromWeek(
                    _referrers[i],
                    currentWeek
                ),
                gapCursor & CohortWeeks.CARRY_HALF_MASK,
                gapCursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT,
                budget
            );

            budget -= entries[i].workUsed;
        }
    }

    struct SelfCursor {
        uint256 length;
        uint256 index;
        uint256 crumb;
        uint256 tracked;
    }

    struct WeekPlan {
        uint256[] crumbWeeks;
        uint256[] crumbWords;
        uint256[] selfRuns;
        uint256 crumbCount;
        uint256 runCount;
        uint256 throughWeek;
        uint256 workUsed;
    }

    function _selfCursorAt(
        address _referrer,
        uint256 _fromWeek
    )
        internal
        view
        returns (SelfCursor memory cursor)
    {
        uint256[] storage log = cohortSelfLog[_referrer];

        cursor.length = log.length;

        cursor.crumb = cohortSelfCrumb[_referrer];

        cursor.tracked = trackedContribution[_referrer];

        uint256 low;

        uint256 high = cursor.length;

        while (low < high) {

            uint256 mid = (low + high) / 2;

            uint256 midWeek = CohortWeeks._selfLogFromWeek(
                log[mid]
            );

            if (midWeek <= _fromWeek) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        cursor.index = low > 0
            ? low - 1
            : 0;
    }

    function _selfWeekSeconds(
        address _referrer,
        SelfCursor memory _cursor,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        uint256 settledAt = CohortWeeks._selfCrumbSettledAt(
            _cursor.crumb
        );

        if (settledAt > 0 && _week >= settledAt / CohortWeeks.WEEK) {
            return _unsettledSelfSeconds(
                _cursor,
                settledAt,
                _week
            );
        }

        if (_cursor.length == 0) {
            return 0;
        }

        uint256[] storage log = cohortSelfLog[_referrer];

        while (_cursor.index + 1 < _cursor.length) {

            uint256 nextWeek = CohortWeeks._selfLogFromWeek(
                log[_cursor.index + 1]
            );

            if (nextWeek > _week) {
                break;
            }

            ++_cursor.index;
        }

        uint256 record = log[_cursor.index];

        uint256 fromWeek = CohortWeeks._selfLogFromWeek(
            record
        );

        if (fromWeek > _week) {
            return 0;
        }

        if (fromWeek == _week) {
            return CohortWeeks._selfLogSeconds(
                record
            );
        }

        return CohortWeeks._clampLane80(
            CohortWeeks._selfLogStake(
                record
            ) * CohortWeeks.WEEK
        );
    }

    function _unsettledSelfSeconds(
        SelfCursor memory _cursor,
        uint256 _settledAt,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        uint256 stake = CohortWeeks._clampLane80(
            _cursor.tracked
        );

        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        if (
            disarmedAt == 0
                || rearmedAt == disarmedAt
                || _settledAt >= (rearmedAt > disarmedAt ? rearmedAt : disarmedAt)
        ) {
            return CohortWeeks._completedPreviousSeconds(
                CohortWeeks._selfCrumbCurrent(
                    _cursor.crumb
                ),
                stake,
                _settledAt,
                _week + 1
            );
        }

        uint256 weekStart = _week
            * CohortWeeks.WEEK;

        uint256 weekEnd = weekStart
            + CohortWeeks.WEEK;

        uint256 from = _settledAt > weekStart
            ? _settledAt
            : weekStart;

        uint256 total = _week == _settledAt / CohortWeeks.WEEK
            ? CohortWeeks._selfCrumbCurrent(
                _cursor.crumb
            )
            : 0;

        total += stake * _overlapSeconds(
            from,
            disarmedAt,
            weekEnd
        );

        return CohortWeeks._clampLane80(
            total
        );
    }

    function _overlapSeconds(
        uint256 _from,
        uint256 _to,
        uint256 _weekEnd
    )
        internal
        pure
        returns (uint256)
    {
        uint256 end = _to < _weekEnd
            ? _to
            : _weekEnd;

        return end > _from
            ? end - _from
            : 0;
    }

    function _planFlushEntry(
        address _referrer,
        uint256 _fromWeek,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (FlushEntryData memory entry)
    {
        entry.referrer = _referrer;

        if (flushHubChainSelector != 0) {
            entry.designationWord = _readDesignationWord(
                _referrer
            );
        }

        uint256 weekBudget = _workBudget;

        if (_gapWorkWaiting(
            _referrer,
            _gapIndex,
            _gapResumeWeek
        )) {
            weekBudget = _workBudget > GAP_WORK_RESERVE
                ? _workBudget - GAP_WORK_RESERVE
                : 0;
        }

        WeekPlan memory plan = _planWeeks(
            _referrer,
            _fromWeek,
            weekBudget
        );

        entry.crumbWeeks = plan.crumbWeeks;

        entry.crumbWords = plan.crumbWords;

        entry.selfRuns = plan.selfRuns;

        entry.throughWeek = plan.throughWeek;

        uint256 gapWork;

        (
            entry.gapSlices,
            entry.gapIndex,
            entry.gapResumeWeek,
            gapWork
        ) = _planGaps(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget - plan.workUsed
        );

        entry.workUsed = plan.workUsed
            + gapWork;
    }

    function _planWeeks(
        address _referrer,
        uint256 _fromWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (WeekPlan memory plan)
    {
        uint256 lastWeek = _lastPlannableWeek(
            _referrer,
            _fromWeek
        );

        plan.throughWeek = lastWeek;

        uint256 span = lastWeek + 1 > _fromWeek
            ? lastWeek + 1 - _fromWeek
            : 0;

        plan.crumbWeeks = new uint256[](span);

        plan.crumbWords = new uint256[](span);

        plan.selfRuns = new uint256[](span);

        SelfCursor memory cursor = _selfCursorAt(
            _referrer,
            _fromWeek
        );

        for (uint256 week = _fromWeek; week <= lastWeek; ++week) {

            if (
                _planWeek(
                    _referrer,
                    week,
                    cursor,
                    plan,
                    _workBudget
                ) == false
            ) {
                plan.throughWeek = week > 0
                    ? week - 1
                    : 0;

                break;
            }
        }

        _shrinkWords(
            plan.crumbWeeks,
            plan.crumbCount
        );

        _shrinkWords(
            plan.crumbWords,
            plan.crumbCount
        );

        _shrinkWords(
            plan.selfRuns,
            plan.runCount
        );
    }

    function _planWeek(
        address _referrer,
        uint256 _week,
        SelfCursor memory _cursor,
        WeekPlan memory _plan,
        uint256 _workBudget
    )
        internal
        view
        returns (bool)
    {
        uint256 selfAvg = _selfWeekSeconds(
            _referrer,
            _cursor,
            _week
        ) / CohortWeeks.WEEK;

        uint256 word = cohortWeekLog[_referrer][_week];

        bool hasCrumb = word & ~CohortWeeks.CRUMB_WRITTEN_BIT != 0;

        uint256 cost = (selfAvg > 0 ? 1 : 0) + (hasCrumb ? 1 : 0);

        if (_plan.workUsed + cost > _workBudget) {
            return false;
        }

        _plan.workUsed += cost;

        if (hasCrumb) {

            _plan.crumbWeeks[_plan.crumbCount] = _week;

            _plan.crumbWords[_plan.crumbCount] = word;

            ++_plan.crumbCount;
        }

        if (selfAvg == 0) {
            return true;
        }

        if (_plan.runCount > 0) {

            uint256 last = _plan.selfRuns[_plan.runCount - 1];

            uint256 lastTo = CohortFlushCodec._selfRunToWeek(
                last
            );

            uint256 lastAverage = CohortFlushCodec._selfRunAverage(
                last
            );

            if (lastTo == _week && lastAverage == selfAvg) {
                _plan.selfRuns[_plan.runCount - 1] = CohortFlushCodec._packSelfRun(
                    CohortFlushCodec._selfRunFromWeek(
                        last
                    ),
                    _week + 1,
                    selfAvg
                );

                return true;
            }
        }

        _plan.selfRuns[_plan.runCount] = CohortFlushCodec._packSelfRun(
            _week,
            _week + 1,
            selfAvg
        );

        ++_plan.runCount;

        return true;
    }

    function _lastPlannableWeek(
        address _referrer,
        uint256 _fromWeek
    )
        internal
        view
        returns (uint256)
    {
        uint256 currentWeek = block.timestamp
            / CohortWeeks.WEEK;

        uint256 lastWeek = currentWeek > 0
            ? currentWeek - 1
            : 0;

        uint256 scanCap = _fromWeek
            + CohortWeeks.MAX_SETTLE_BOUNDARIES
            - 1;

        if (scanCap < lastWeek) {
            lastWeek = scanCap;
        }

        return _capParkedThroughWeek(
            _referrer,
            lastWeek
        );
    }

    function _shrinkWords(
        uint256[] memory _words,
        uint256 _length
    )
        internal
        pure
    {
        assembly {
            mstore(_words, _length)
        }
    }

    function _capParkedThroughWeek(
        address _referrer,
        uint256 _throughWeek
    )
        internal
        view
        returns (uint256)
    {
        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        uint256 last = cohortLastSettle[_referrer];

        if (last == 0 || _parkedAtDisarmCohort(last, disarmedAt, rearmedAt) == false) {
            return _throughWeek;
        }

        uint256 cap = disarmedAt
            / CohortWeeks.WEEK
            - 1;

        return _throughWeek < cap
            ? _throughWeek
            : cap;
    }

    function _planGaps(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget
    )
        internal
        view
        returns (
            uint256[] memory slices,
            uint256 gapIndex,
            uint256 gapResumeWeek,
            uint256 workUsed
        )
    {
        (
            uint256 count,
            ,
            ,
        ) = _walkGapSlices(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget,
            new uint256[](0)
        );

        slices = new uint256[](count);

        (
            ,
            gapIndex,
            gapResumeWeek,
            workUsed
        ) = _walkGapSlices(
            _referrer,
            _gapIndex,
            _gapResumeWeek,
            _workBudget,
            slices
        );
    }

    function _walkGapSlices(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResumeWeek,
        uint256 _workBudget,
        uint256[] memory _fill
    )
        internal
        view
        returns (
            uint256 count,
            uint256 gapIndex,
            uint256 gapResumeWeek,
            uint256 workUsed
        )
    {
        uint256 length = cohortGapLog[_referrer].length;

        uint256 left = _workBudget;

        uint256 resume = _gapResumeWeek;

        uint256 index = _gapIndex;

        while (index < length) {

            uint256 record = cohortGapLog[_referrer][index];

            uint256 sliceFrom = CohortWeeks._gapRecordFromWeek(
                record
            );

            if (resume > sliceFrom) {
                sliceFrom = resume;
            }

            uint256 sliceTo = CohortWeeks._gapRecordToWeek(
                record
            );

            if (sliceFrom >= sliceTo) {
                ++index;
                resume = 0;
                continue;
            }

            if (left == 0) {
                break;
            }

            uint256 take = left < CohortWeeks.MAX_SETTLE_BOUNDARIES
                ? left
                : CohortWeeks.MAX_SETTLE_BOUNDARIES;

            if (take > sliceTo - sliceFrom) {
                take = sliceTo - sliceFrom;
            }

            if (_fill.length > 0) {
                _fill[count] = CohortWeeks._packGapRecord(
                    sliceFrom,
                    sliceFrom + take,
                    _clampGapMature(
                        CohortWeeks._gapRecordMature(
                            record
                        )
                    )
                );
            }

            ++count;

            left -= take;

            if (sliceFrom + take == sliceTo) {
                ++index;
                resume = 0;
            } else {
                resume = sliceFrom + take;
            }
        }

        return (
            count,
            index,
            resume,
            _workBudget - left
        );
    }

    function _clampGapMature(
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        uint256 ceiling = CohortWeeks.LANE_MASK_80
            / CohortWeeks.WEEK;

        return _mature < ceiling
            ? _mature
            : ceiling;
    }

    function _cursorFromWeek(
        address _referrer,
        uint256 _currentWeek
    )
        internal
        view
        returns (uint256)
    {
        uint256 stored = flushedThroughWeek[_referrer];

        if (stored > 0) {
            return stored + 1;
        }

        if (_currentWeek < CohortWeeks.MAX_SETTLE_BOUNDARIES) {
            return 0;
        }

        return _currentWeek
            - CohortWeeks.MAX_SETTLE_BOUNDARIES
            + 1;
    }

    function _readDesignationWord(
        address _owner
    )
        internal
        view
        returns (uint256)
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return 0;
        }

        bytes4 selector = IReferralRegistry.getPayoutDesignation.selector;

        (
            bool success,
            uint256 word0,
            uint256 word1,
        ) = _staticWordsCohort(
            registry,
            selector,
            uint256(uint160(_owner)),
            0,
            0x24,
            2
        );

        if (
            success == false
                || word0 > type(uint160).max
                || word1 == 0
                || (word1 >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT) > CohortWeeks.RING_LANE_MAX
        ) {
            return 0;
        }

        return CohortFlushCodec._packFlushDesignation(
            address(uint160(word0)),
            word1 >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT,
            word1 & CohortWeeks.CARRY_BYTE_MASK
        );
    }
}
