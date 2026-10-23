// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubCheckpoints} from "./ReferralHubCheckpoints.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubRates: the week-versioned rate tables and `_weeklyRates`,
 * the only rate computation. Year-1 pays the referrer's tier ladder up to
 * the cap; year-2 and mature pay only in weeks where the uncapped ladder
 * reaches the cap. A table keeps capBps within BPS, y2RateBps within capBps,
 * mRateBps within y2RateBps, rising tiers and thresholds and botShareBps
 * within MAX_BOT_SHARE_BPS, and applies to future weeks only. Every bps
 * field is a rate per 52-week year (`CohortWeeks.YEAR`, 364 days): a
 * cohort's year one runs from its credit to the 52nd week boundary after
 * its credit week starts, year two the 52 weeks after that. An elevated
 * referrer (master whitelist, every window of `elevationWindowsOf`, the
 * latest mirrored by `elevatedFromWeek` and `elevatedUntilWeek`, an until
 * week of zero meaning open) is priced as at the cap for every week any of
 * its windows holds, whatever its inputs, and keeps that verdict for good;
 * the inputs are recorded all the same, so the natural rate stays
 * derivable from `ladderInputsAt` and the table. A referrer never elevated
 * costs one warm SLOAD per priced week, the empty history's length.
 */
abstract contract ReferralHubRates is ReferralHubCheckpoints {

    function weeklyRates(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        )
    {
        return _weeklyRates(
            _referrer,
            _week
        );
    }

    function rateTableCount()
        external
        view
        returns (uint256)
    {
        return rateTables.length;
    }

    function rateTableAt(
        uint256 _index
    )
        external
        view
        returns (RateTable memory)
    {
        return rateTables[_index];
    }

    function _pushRateTable(
        RateTable memory _table
    )
        internal
    {
        _requireWithinHorizon(
            _table.effectiveFromWeek
        );

        require(
            _table.effectiveFromWeek > block.timestamp / CohortWeeks.WEEK,
            TableNotFuture()
        );

        require(
            _table.effectiveFromWeek > rateTables[rateTables.length - 1].effectiveFromWeek,
            TableNotOrdered()
        );

        require(
            _table.capBps <= BPS_DENOMINATOR
                && _table.y2RateBps <= _table.capBps
                && _table.mRateBps <= _table.y2RateBps,
            InvalidRateTable()
        );

        require(
            _table.botShareBps <= MAX_BOT_SHARE_BPS,
            BotShareTooHigh()
        );

        for (uint256 i; i < 8; ++i) {

            require(
                _table.tierBps[i] <= BPS_DENOMINATOR
                    && (i == 0 || _table.tierBps[i] >= _table.tierBps[i - 1]),
                InvalidRateTable()
            );

            require(
                _table.thresholds[i] > 0
                    && (i == 0 || _table.thresholds[i] > _table.thresholds[i - 1]),
                InvalidRateTable()
            );
        }

        rateTables.push(
            _table
        );

        emit RateTableScheduled(
            rateTables.length - 1,
            _table.effectiveFromWeek
        );
    }

    function _weeklyRates(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        )
    {
        RateTable storage table = _tableFor(
            _week
        );

        if (
            _isElevatedAt(
                _referrer,
                _week
            )
        ) {
            return (
                table.capBps,
                table.y2RateBps,
                table.mRateBps
            );
        }

        (
            uint256 referredInput,
            uint256 selfInput
        ) = _ladderInputsAt(
            _referrer,
            _week
        );

        y1Bps = _tierBps(
            table,
            selfInput
        ) + _tierBps(
            table,
            referredInput
        );

        if (y1Bps > table.capBps) {
            y1Bps = table.capBps;
        }

        if (y1Bps == table.capBps) {
            y2Bps = table.y2RateBps;
            mBps = table.mRateBps;
        }
    }

    function _isElevatedAt(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (bool)
    {
        uint256[] storage windows = elevationWindowsOf[_referrer];

        uint256 count = windows.length;

        for (uint256 i; i < count; ++i) {

            uint256 window = windows[i];

            uint256 untilWeek = window >> WEEK_HALF_SHIFT;

            if (
                _week >= (window & WEEK_HALF_MASK)
                    && (untilWeek == 0 || _week < untilWeek)
            ) {
                return true;
            }
        }

        return false;
    }

    function _tableFor(
        uint256 _week
    )
        internal
        view
        returns (RateTable storage)
    {
        return rateTables[
            _lastAtOrBefore(
                rateTables.length,
                _week,
                _tableWeekAt
            )
        ];
    }

    function _tableWeekAt(
        uint256 _index
    )
        internal
        view
        returns (uint256)
    {
        return rateTables[_index].effectiveFromWeek;
    }

    function _tierBps(
        RateTable storage _table,
        uint256 _value
    )
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 8; i > 0; --i) {

            if (_value >= _table.thresholds[i - 1]) {
                return _table.tierBps[i - 1];
            }
        }

        return 0;
    }
}
