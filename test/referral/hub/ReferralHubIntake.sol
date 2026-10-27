// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRates} from "./ReferralHubRates.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushCodec} from "../../../src/diamond/shared/pending/CohortFlushCodec.sol";

/**
 * @dev ReferralHubIntake: the only writer of week buckets, paid cursors and
 * claimables. Only closed weeks are taken. A crumb or gap week first reports
 * its own referred average into W's bucket, a self run reports its weekly
 * self average, and a source's report for W is final, merged by maximum;
 * W's inputs are the sums of the sources' reports, referred and self.
 * Every (source, referrer, week) is paid exactly `floor(sum of lane times
 * rate / (BPS times YEAR))` over its cumulative cursor at W's current
 * rates, so a replay pays nothing twice and a regressing lane emits
 * CrumbLaneRegression and pays zero. A report that raises W's rates
 * records the bucket and emits WeekRatesRaised; a report that raises them
 * also re-settles its own source's cell, so a vault's later report never
 * leaves its own earlier crumb or gap week underpaid, and the permissionless
 * `settleWeeks` re-settles every other source already paid for W at W's
 * current rates, so W's price never depends on the order its sources
 * arrive in once settled, no top-up is ever negative because a bucket
 * only rises, and an apply's gas is bounded by its work alone, never by
 * how many sources a referrer is listed at. The referrer is always
 * credited the full commission; the courier fee is paid by the protocol
 * on top of a delivered increment, on that increment's own due at the
 * week's current rates and never on a top-up (not even one a delivery
 * collects for its own source), only when the deliverer is set and is not
 * the referrer (a vault names the caller as deliverer only when the caller
 * is one of its allowed flush bots), at the week's `botShareBps`, clamped by `delivererShareCap` when that cap is
 * nonzero (zero means no cap); `totalAccrued` counts both. A source's word
 * for a closed week is final, so a delivery that raises its referred
 * average also moves its cursor and settles its own cell; one that raises
 * the average with no lane above the cursor tops its own cell up the same
 * way. A self run's average is at most one 80-bit lane over one week, the
 * bound a crumb lane and a gap record already carry. A bucket joins
 * `totalPayable`, the amount the hub's pot owes, only once its owner has
 * a claim path.
 */
abstract contract ReferralHubIntake is ReferralHubRates {

    struct DeliveryOrigin {
        uint256 chainId;
        address deliverer;
        bytes32 messageId;
    }

    function _listSource(
        bytes32 _source,
        address _referrer,
        uint256 _chainId
    )
        internal
    {
        if (sourceListedFor[_referrer][_source] == true) {
            return;
        }

        sourceListedFor[_referrer][_source] = true;

        sourcesOf[_referrer].push(
            _source
        );

        if (sourceChainIdOf[_source] == 0) {
            sourceChainIdOf[_source] = _chainId;
        }

        emit SourceListed(
            _referrer,
            _source,
            sourceChainIdOf[_source]
        );
    }

    function _applySelfRun(
        bytes32 _source,
        address _referrer,
        uint256 _run,
        uint256 _chainId
    )
        internal
        returns (uint256)
    {
        uint256 fromWeek = CohortFlushCodec._selfRunFromWeek(
            _run
        );

        uint256 toWeek = CohortFlushCodec._selfRunToWeek(
            _run
        );

        require(
            _run >> CohortFlushCodec.SELF_RUN_RESERVED_SHIFT == 0
                && fromWeek < toWeek
                && toWeek <= block.timestamp / CohortWeeks.WEEK
                && toWeek - fromWeek <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            InvalidSelfRun()
        );

        _listSource(
            _source,
            _referrer,
            _chainId
        );

        uint256 average = CohortFlushCodec._selfRunAverage(
            _run
        );

        require(
            average <= CohortWeeks.LANE_MASK_80 / CohortWeeks.WEEK,
            InvalidSelfRun()
        );

        for (uint256 week = fromWeek; week < toWeek; ++week) {
            _recordSelf(
                _source,
                _referrer,
                week,
                average
            );
        }

        return toWeek - fromWeek;
    }

    function _recordReferred(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _average
    )
        internal
        returns (bool)
    {
        uint256 word = sourceWeekOf[_source][_referrer][_week];

        uint256 previous = word & WEEK_HALF_MASK;

        if (_average <= previous) {
            return false;
        }

        uint256 ratesBefore = _packedRates(
            _referrer,
            _week
        );

        sourceWeekOf[_source][_referrer][_week] = word
            - previous
            + _average;

        weekInputsOf[_referrer][_week] += _average - previous;

        emit WeekReferredReported(
            _source,
            _referrer,
            _week,
            _average
        );

        return _noteRatesRaised(
            _referrer,
            _week,
            ratesBefore
        );
    }

    function _recordSelf(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _average
    )
        internal
    {
        uint256 previous = sourceSelfOf[_source][_referrer][_week];

        if (_average <= previous) {
            return;
        }

        uint256 ratesBefore = _packedRates(
            _referrer,
            _week
        );

        sourceSelfOf[_source][_referrer][_week] = _average;

        weekInputsOf[_referrer][_week] += (_average - previous) << WEEK_HALF_SHIFT;

        emit WeekSelfReported(
            _source,
            _referrer,
            _week,
            _average
        );

        bool raised = _noteRatesRaised(
            _referrer,
            _week,
            ratesBefore
        );

        if (raised == false) {
            return;
        }

        _topUpSourceWeek(
            _source,
            _referrer,
            _week
        );
    }

    function _topUpSourceWeek(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        internal
    {
        uint256 amount = _settleSourceWeek(
            _source,
            _referrer,
            _week,
            _packedRates(
                _referrer,
                _week
            )
        );

        if (amount > 0) {
            emit WeekToppedUp(
                _source,
                _referrer,
                _week,
                amount
            );
        }
    }

    function _noteRatesRaised(
        address _referrer,
        uint256 _week,
        uint256 _ratesBefore
    )
        internal
        returns (bool)
    {
        uint256 rates = _packedRates(
            _referrer,
            _week
        );

        if (rates == _ratesBefore) {
            return false;
        }

        emit WeekRatesRaised(
            _referrer,
            _week
        );

        return true;
    }

    function _settleWeekSources(
        address _referrer,
        uint256 _week
    )
        internal
    {
        uint256 rates = _packedRates(
            _referrer,
            _week
        );

        bytes32[] storage sources = sourcesOf[_referrer];

        for (uint256 i; i < sources.length; ++i) {

            uint256 amount = _settleSourceWeek(
                sources[i],
                _referrer,
                _week,
                rates
            );

            if (amount > 0) {
                emit WeekToppedUp(
                    sources[i],
                    _referrer,
                    _week,
                    amount
                );
            }
        }
    }

    function _packedRates(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = _weeklyRates(
            _referrer,
            _week
        );

        return y1Bps
            | (y2Bps << RATE_Y2_SHIFT)
            | (mBps << RATE_M_SHIFT);
    }

    function _settleSourceWeek(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _rates
    )
        internal
        returns (uint256 amount)
    {
        uint256 cursorWord = paidCursor[_source][_referrer][_week];

        if (cursorWord == 0) {
            return 0;
        }

        uint256 due = _dueOf(
            cursorWord,
            _rates
        );

        uint256 word = sourceWeekOf[_source][_referrer][_week];

        uint256 paidSoFar = word >> WEEK_HALF_SHIFT;

        if (due <= paidSoFar) {
            return 0;
        }

        amount = due - paidSoFar;

        sourceWeekOf[_source][_referrer][_week] = (word & WEEK_HALF_MASK)
            | (due << WEEK_HALF_SHIFT);

        _creditClaimable(
            sourceChainIdOf[_source],
            _referrer,
            amount
        );

        totalAccrued += amount;
    }

    function _dueOf(
        uint256 _cursorWord,
        uint256 _rates
    )
        internal
        pure
        returns (uint256)
    {
        return (
            CohortWeeks._laneY1(
                _cursorWord
            ) * (_rates & RATE_MASK)
                + CohortWeeks._laneY2(
                    _cursorWord
                ) * ((_rates >> RATE_Y2_SHIFT) & RATE_MASK)
                + CohortWeeks._laneM(
                    _cursorWord
                ) * (_rates >> RATE_M_SHIFT)
        ) / (BPS_DENOMINATOR * CohortWeeks.YEAR);
    }

    function _deliverCrumb(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _word,
        DeliveryOrigin memory _origin
    )
        internal
    {
        if (_word == 0) {
            return;
        }

        require(
            _word & ~_crumbWordMask() == 0,
            InvalidCrumbWord()
        );

        require(
            _week < block.timestamp / CohortWeeks.WEEK,
            WeekNotClosed()
        );

        _listSource(
            _source,
            _referrer,
            _origin.chainId
        );

        uint256 lanes = _word & ~CohortWeeks.CRUMB_WRITTEN_BIT;

        bool raised = _recordReferred(
            _source,
            _referrer,
            _week,
            (
                CohortWeeks._laneY1(
                    lanes
                )
                    + CohortWeeks._laneY2(
                        lanes
                    )
                    + CohortWeeks._laneM(
                        lanes
                    )
            ) / CohortWeeks.WEEK
        );

        (
            uint256 paid,
            uint256 incrementWord
        ) = _priceWeek(
            _source,
            _referrer,
            _week,
            lanes,
            _origin
        );

        if (incrementWord == 0 && raised == true) {
            _topUpSourceWeek(
                _source,
                _referrer,
                _week
            );
        }

        if (incrementWord == 0) {
            return;
        }

        emit CrumbPriced(
            _source,
            _referrer,
            _week,
            _origin.deliverer,
            CohortWeeks._laneY1(
                incrementWord
            ),
            CohortWeeks._laneY2(
                incrementWord
            ),
            CohortWeeks._laneM(
                incrementWord
            ),
            paid
        );
    }

    function _deliverGap(
        bytes32 _source,
        address _referrer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks,
        DeliveryOrigin memory _origin
    )
        internal
    {
        (
            uint256 toWeekExclusive,
            uint256 mature
        ) = _parseGapRecord(
            _record,
            _fromWeek,
            _maxWeeks
        );

        _listSource(
            _source,
            _referrer,
            _origin.chainId
        );

        uint256 end = _windowEnd(
            _fromWeek,
            _maxWeeks,
            toWeekExclusive
        );

        (
            uint256 paidTotal,
            uint256 incrementTotal
        ) = _priceGapWindow(
            _source,
            _referrer,
            mature,
            _fromWeek,
            end,
            _origin
        );

        if (incrementTotal == 0) {
            return;
        }

        emit GapPriced(
            _source,
            _referrer,
            _origin.deliverer,
            _fromWeek,
            end,
            paidTotal
        );
    }

    function _parseGapRecord(
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        internal
        view
        returns (
            uint256 toWeekExclusive,
            uint256 mature
        )
    {
        uint256 fromWeek = _record & GAP_WEEK_MASK;

        toWeekExclusive = (_record >> CohortWeeks.GAP_TO_SHIFT) & GAP_WEEK_MASK;

        mature = (_record >> CohortWeeks.GAP_MATURE_SHIFT) & CohortWeeks.LANE_MASK_80;

        require(
            fromWeek < toWeekExclusive
                && _record >> (CohortWeeks.GAP_MATURE_SHIFT + 80) == 0
                && mature <= CohortWeeks.LANE_MASK_80 / CohortWeeks.WEEK,
            InvalidGapRecord()
        );

        require(
            toWeekExclusive <= block.timestamp / CohortWeeks.WEEK,
            FutureWeek()
        );

        require(
            _maxWeeks > 0
                && _fromWeek >= fromWeek
                && _fromWeek < toWeekExclusive,
            InvalidWindow()
        );
    }

    function _windowEnd(
        uint256 _fromWeek,
        uint256 _maxWeeks,
        uint256 _toWeekExclusive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 window = _maxWeeks < CohortWeeks.MAX_SETTLE_BOUNDARIES
            ? _maxWeeks
            : CohortWeeks.MAX_SETTLE_BOUNDARIES;

        return _fromWeek + window < _toWeekExclusive
            ? _fromWeek + window
            : _toWeekExclusive;
    }

    function _priceGapWindow(
        bytes32 _source,
        address _referrer,
        uint256 _mature,
        uint256 _fromWeek,
        uint256 _end,
        DeliveryOrigin memory _origin
    )
        internal
        returns (
            uint256 paidTotal,
            uint256 incrementTotal
        )
    {
        uint256 quantityWord = CohortWeeks._packLanes(
            0,
            0,
            _mature * CohortWeeks.WEEK
        );

        for (uint256 week = _fromWeek; week < _end; ++week) {

            _recordReferred(
                _source,
                _referrer,
                week,
                _mature
            );

            (
                uint256 paid,
                uint256 incrementWord
            ) = _priceWeek(
                _source,
                _referrer,
                week,
                quantityWord,
                _origin
            );

            paidTotal += paid;

            incrementTotal += incrementWord;
        }
    }

    function _priceWeek(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord,
        DeliveryOrigin memory _origin
    )
        internal
        returns (
            uint256 paid,
            uint256 incrementWord
        )
    {
        incrementWord = _cursorIncrements(
            _source,
            _referrer,
            _week,
            _quantityWord
        );

        if (incrementWord == 0) {
            return (
                0,
                0
            );
        }

        uint256 rates = _packedRates(
            _referrer,
            _week
        );

        uint256 dueBefore = _dueOf(
            paidCursor[_source][_referrer][_week],
            rates
        );

        _advanceCursor(
            _source,
            _referrer,
            _week,
            _quantityWord
        );

        paid = _settleSourceWeek(
            _source,
            _referrer,
            _week,
            rates
        );

        _payCourierFee(
            _referrer,
            _week,
            _dueOf(
                paidCursor[_source][_referrer][_week],
                rates
            ) - dueBefore,
            _origin
        );
    }

    function _cursorIncrements(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord
    )
        internal
        returns (uint256 incrementWord)
    {
        uint256 cursorWord = paidCursor[_source][_referrer][_week];

        incrementWord = CohortWeeks._packLanes(
            _laneIncrement(
                _source,
                _referrer,
                _week,
                0,
                CohortWeeks._laneY1(
                    _quantityWord
                ),
                CohortWeeks._laneY1(
                    cursorWord
                )
            ),
            _laneIncrement(
                _source,
                _referrer,
                _week,
                1,
                CohortWeeks._laneY2(
                    _quantityWord
                ),
                CohortWeeks._laneY2(
                    cursorWord
                )
            ),
            _laneIncrement(
                _source,
                _referrer,
                _week,
                2,
                CohortWeeks._laneM(
                    _quantityWord
                ),
                CohortWeeks._laneM(
                    cursorWord
                )
            )
        );
    }

    function _advanceCursor(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _quantityWord
    )
        internal
    {
        uint256 cursorWord = paidCursor[_source][_referrer][_week];

        paidCursor[_source][_referrer][_week] = CohortWeeks._packLanes(
            _max(
                CohortWeeks._laneY1(
                    _quantityWord
                ),
                CohortWeeks._laneY1(
                    cursorWord
                )
            ),
            _max(
                CohortWeeks._laneY2(
                    _quantityWord
                ),
                CohortWeeks._laneY2(
                    cursorWord
                )
            ),
            _max(
                CohortWeeks._laneM(
                    _quantityWord
                ),
                CohortWeeks._laneM(
                    cursorWord
                )
            )
        );
    }

    function _payCourierFee(
        address _referrer,
        uint256 _week,
        uint256 _increment,
        DeliveryOrigin memory _origin
    )
        internal
    {
        if (
            _increment == 0
                || _origin.deliverer == ZERO_ADDRESS
                || _origin.deliverer == _referrer
        ) {
            return;
        }

        uint256 fee = _increment * _tableFor(
            _week
        ).botShareBps / BPS_DENOMINATOR;

        uint256 cap = delivererShareCap;

        if (cap > 0 && fee > cap) {
            fee = cap;
        }

        if (fee == 0) {
            return;
        }

        _creditClaimable(
            _origin.chainId,
            _origin.deliverer,
            fee
        );

        totalAccrued += fee;

        emit DelivererSharePaid(
            _origin.chainId,
            _origin.deliverer,
            _referrer,
            _origin.messageId,
            fee
        );
    }

    function _creditClaimable(
        uint256 _chainId,
        address _account,
        uint256 _amount
    )
        internal
    {
        claimable[_chainId][_account] += _amount;

        if (payoutStamp[_chainId][_account] != 0) {
            totalPayable += _amount;
        }
    }

    function _releasePayoutBacklog(
        uint256 _chainId,
        address _owner
    )
        internal
    {
        uint256 backlog = claimable[_chainId][_owner];

        if (backlog == 0) {
            return;
        }

        totalPayable += backlog;

        emit PayoutBacklogReleased(
            _chainId,
            _owner,
            backlog
        );
    }

    function _stampPayout(
        uint256 _chainId,
        address _owner,
        uint256 _stamp
    )
        internal
    {
        if (payoutStamp[_chainId][_owner] == 0) {
            _releasePayoutBacklog(
                _chainId,
                _owner
            );
        }

        payoutStamp[_chainId][_owner] = _stamp;
    }

    function _laneIncrement(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _laneKind,
        uint256 _incoming,
        uint256 _cursor
    )
        internal
        returns (uint256)
    {
        if (_incoming > _cursor) {
            return _incoming - _cursor;
        }

        if (_incoming < _cursor) {

            emit CrumbLaneRegression(
                _source,
                _referrer,
                _week,
                _laneKind,
                _incoming,
                _cursor
            );
        }

        return 0;
    }

    function _crumbWordMask()
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.LANE_MASK_80
            | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_Y2_SHIFT)
            | (CohortWeeks.LANE_MASK_80 << CohortWeeks.LANE_M_SHIFT)
            | CohortWeeks.CRUMB_WRITTEN_BIT;
    }

    function _max(
        uint256 _a,
        uint256 _b
    )
        internal
        pure
        returns (uint256)
    {
        return _a > _b
            ? _a
            : _b;
    }
}

