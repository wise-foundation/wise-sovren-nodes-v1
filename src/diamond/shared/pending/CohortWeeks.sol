// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev CohortWeeks: the week epoch, lane geometry and carry codecs of the
 * referral cohort recorder, shared by the vault facets and the hub so no
 * contract restates these numbers (`week = timestamp / WEEK`).
 *
 * The book word and every crumb word hold three 80-bit lanes (year-1,
 * year-2, mature); a crumb word also sets bit 252 when written, and its
 * format is frozen because the hub prices it. Ring slots pack four uint64
 * lanes per storage word. The saturating helpers return the clipped
 * remainder and never revert, since they run inside the transfer hook.
 *
 * Same-chain carry (moves only, staged and consumed in one transaction):
 * word0 `referrer(160) | version(8) | pairCount(8)`, word1
 * `trackedDelta(128) | mature(128)`, then two pairs per word, a pair being
 * `amount(64) | slot(8) | ring(8)`. Bridge carry (cross-chain only), three
 * header words `referrer(160) | version(8) | captureWeek(32) |
 * pairCount(8)`, `trackedDelta(128) | assignedAt(64) | originRank(8)` and
 * `mature(128)`, then the pairs two per word in the same pair format.
 * `_bridgeCarryValid` rejects a payload wholesale unless its length and
 * layout hold, every reserved bit is zero, its lanes sum to at most
 * trackedDelta and trackedDelta is at most the amount the same message
 * mints. Every carried pair lands at the slot of its own credit week,
 * aged only by the week boundaries crossed between capture and landing
 * (`_landedCarryPair`), so a relocation never changes a cohort's age. A
 * destination clock behind the capture week takes the lag off the age,
 * floored at zero: a slot ahead of the destination week is the one its
 * next boundary graduates, so only credit younger than the lag lands in
 * the destination's current week.
 *
 * Self crumb word: `currentWeekSeconds(80) | previousWeekSeconds(80) |
 * settledAt(64)`. It is settled before every change of the tracked
 * contribution, which keeps the completed previous week exact.
 */
library CohortWeeks {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    // The 52-week year, the divisor of the commission rate: a rate is per
    // 52 weeks, the length of one ring year, so every full ring year pays
    // exactly the stated rate.
    uint256 internal constant YEAR = RING_SLOTS * WEEK;

    uint256 internal constant MAX_SETTLE_BOUNDARIES = 104;

    uint256 internal constant LANE_MASK_80 = (1 << 80) - 1;

    uint256 internal constant LANE_Y2_SHIFT = 80;

    uint256 internal constant LANE_M_SHIFT = 160;

    uint256 internal constant SELF_STAMP_SHIFT = 160;

    uint256 internal constant SELF_STAMP_MASK = (1 << 64) - 1;

    uint256 internal constant CRUMB_WRITTEN_BIT = 1 << 252;

    uint256 internal constant CRUMB_VERSION = 1;

    uint256 internal constant GAP_TO_SHIFT = 32;

    uint256 internal constant GAP_MATURE_SHIFT = 64;

    uint256 internal constant RING_LANE_MAX = type(uint64).max;

    uint256 internal constant CARRY_VERSION = 1;

    uint256 internal constant MAX_CARRY_PAIRS = 104;

    uint256 internal constant MAX_CARRY_WORDS = 54;

    uint256 internal constant CARRY_RING_YEAR1 = 0;

    uint256 internal constant CARRY_RING_YEAR2 = 1;

    uint256 internal constant CARRY_VERSION_SHIFT = 160;

    uint256 internal constant CARRY_PAIR_COUNT_SHIFT = 168;

    uint256 internal constant CARRY_BYTE_MASK = 0xff;

    uint256 internal constant CARRY_HALF_SHIFT = 128;

    uint256 internal constant CARRY_HALF_MASK = (1 << 128) - 1;

    uint256 internal constant CARRY_PAIR_SLOT_SHIFT = 64;

    uint256 internal constant CARRY_PAIR_RING_SHIFT = 72;

    uint256 internal constant CARRY_PAIR_RESERVED_SHIFT = 80;

    uint256 internal constant CARRY_LANE_MATURE = 2;

    uint256 internal constant BRIDGE_CARRY_VERSION = 3;

    uint256 internal constant BRIDGE_CARRY_HEADER_WORDS = 3;

    uint256 internal constant BRIDGE_CARRY_HEADER_BYTES = 96;

    // The longest bridge carry: three header words and 104 pairs.
    uint256 internal constant BRIDGE_CARRY_BYTES = 1_760;

    uint256 internal constant BRIDGE_CARRY_PAIR_COUNT_SHIFT = 200;

    uint256 internal constant BRIDGE_CARRY_ASSIGNED_AT_SHIFT = 128;

    uint256 internal constant BRIDGE_CARRY_RANK_SHIFT = 192;

    uint256 internal constant BRIDGE_CARRY_CAPTURE_WEEK_SHIFT = 168;

    uint256 internal constant BRIDGE_CARRY_CAPTURE_WEEK_MASK = (1 << 32) - 1;

    uint256 internal constant BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT = 208;

    uint256 internal constant BRIDGE_CARRY_TRACKED_RESERVED_SHIFT = 200;

    uint256 internal constant SELF_LOG_WEEK_MASK = (1 << 32) - 1;

    uint256 internal constant SELF_LOG_SECONDS_SHIFT = 32;

    uint256 internal constant SELF_LOG_STAKE_SHIFT = 112;

    function _packCarryEnvelope(
        address _referrer,
        uint256 _pairCount
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_referrer))
            | (CARRY_VERSION << CARRY_VERSION_SHIFT)
            | (_pairCount << CARRY_PAIR_COUNT_SHIFT);
    }

    function _carryEnvelopeReferrer(
        uint256 _word
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(_word)
        );
    }

    function _carryEnvelopeVersion(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> CARRY_VERSION_SHIFT) & CARRY_BYTE_MASK;
    }

    function _carryEnvelopePairCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> CARRY_PAIR_COUNT_SHIFT) & CARRY_BYTE_MASK;
    }

    function _packCarryAmounts(
        uint256 _trackedDelta,
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        return _trackedDelta
            | (_mature << CARRY_HALF_SHIFT);
    }

    function _carryTrackedDelta(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & CARRY_HALF_MASK;
    }

    function _carryMature(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word >> CARRY_HALF_SHIFT;
    }

    function _packCarryPair(
        uint256 _amount,
        uint256 _slot,
        uint256 _ring
    )
        internal
        pure
        returns (uint256)
    {
        return _amount
            | (_slot << CARRY_PAIR_SLOT_SHIFT)
            | (_ring << CARRY_PAIR_RING_SHIFT);
    }

    function _carryPairAmount(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return _pair & RING_LANE_MAX;
    }

    function _carryPairSlot(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return (_pair >> CARRY_PAIR_SLOT_SHIFT) & CARRY_BYTE_MASK;
    }

    function _carryPairRing(
        uint256 _pair
    )
        internal
        pure
        returns (uint256)
    {
        return (_pair >> CARRY_PAIR_RING_SHIFT) & CARRY_BYTE_MASK;
    }

    function _packCarryPairsWord(
        uint256 _pairLo,
        uint256 _pairHi
    )
        internal
        pure
        returns (uint256)
    {
        return _pairLo
            | (_pairHi << CARRY_HALF_SHIFT);
    }

    function _carryPairLo(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & CARRY_HALF_MASK;
    }

    function _carryPairHi(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word >> CARRY_HALF_SHIFT;
    }

    function _packBridgeCarryEnvelope(
        address _referrer,
        uint256 _captureWeek,
        uint256 _pairCount
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_referrer))
            | (BRIDGE_CARRY_VERSION << CARRY_VERSION_SHIFT)
            | (_captureWeek << BRIDGE_CARRY_CAPTURE_WEEK_SHIFT)
            | (_pairCount << BRIDGE_CARRY_PAIR_COUNT_SHIFT);
    }

    function _packBridgeCarryTracked(
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return _trackedDelta
            | (_assignedAt << BRIDGE_CARRY_ASSIGNED_AT_SHIFT)
            | (_rank << BRIDGE_CARRY_RANK_SHIFT);
    }

    function _bridgeCarryAssignedAt(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> BRIDGE_CARRY_ASSIGNED_AT_SHIFT) & RING_LANE_MAX;
    }

    function _bridgeCarryRank(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> BRIDGE_CARRY_RANK_SHIFT) & CARRY_BYTE_MASK;
    }

    function _bridgeCarryCaptureWeek(
        uint256 _word0
    )
        internal
        pure
        returns (uint256)
    {
        return (_word0 >> BRIDGE_CARRY_CAPTURE_WEEK_SHIFT) & BRIDGE_CARRY_CAPTURE_WEEK_MASK;
    }

    function _bridgeCarryPairCount(
        uint256 _word0
    )
        internal
        pure
        returns (uint256)
    {
        return (_word0 >> BRIDGE_CARRY_PAIR_COUNT_SHIFT) & CARRY_BYTE_MASK;
    }

    function _packBridgeCarry(
        uint256[] memory _words
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            _words
        );
    }

    function _unpackBridgeCarry(
        bytes memory _data
    )
        internal
        pure
        returns (uint256[] memory words)
    {
        words = new uint256[](
            _data.length / 32
        );

        for (uint256 i; i < words.length; ++i) {

            uint256 word;

            assembly {
                word := mload(add(_data, mul(add(i, 1), 0x20)))
            }

            words[i] = word;
        }
    }

    function _carryPairOf(
        uint256[] memory _words,
        uint256 _firstPairWord,
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        uint256 word = _words[_firstPairWord + _index / 2];

        return _index % 2 == 0
            ? _carryPairLo(
                word
            )
            : _carryPairHi(
                word
            );
    }

    function _carryPairSums(
        uint256[] memory _words,
        uint256 _firstPairWord,
        uint256 _pairCount
    )
        internal
        pure
        returns (
            uint256 year1,
            uint256 year2
        )
    {
        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = _carryPairOf(
                _words,
                _firstPairWord,
                i
            );

            if (_carryPairRing(pair) == CARRY_RING_YEAR1) {
                year1 += _carryPairAmount(
                    pair
                );
            } else {
                year2 += _carryPairAmount(
                    pair
                );
            }
        }
    }

    function _carryPairsValid(
        uint256[] memory _words,
        uint256 _firstPairWord,
        uint256 _pairCount,
        uint256 _laneSum,
        bool _checkReserved
    )
        internal
        pure
        returns (
            bool ok,
            uint256 laneSum
        )
    {
        laneSum = _laneSum;

        if (
            _pairCount % 2 == 1
                && _carryPairHi(_words[_words.length - 1]) != 0
        ) {
            return (
                false,
                _laneSum
            );
        }

        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = _carryPairOf(
                _words,
                _firstPairWord,
                i
            );

            if (
                _checkReserved
                    && pair >> CARRY_PAIR_RESERVED_SHIFT != 0
            ) {
                return (
                    false,
                    _laneSum
                );
            }

            if (
                _carryPairSlot(pair) >= RING_SLOTS
                    || _carryPairRing(pair) > CARRY_RING_YEAR2
            ) {
                return (
                    false,
                    _laneSum
                );
            }

            laneSum += _carryPairAmount(
                pair
            );
        }

        return (
            true,
            laneSum
        );
    }

    function _bridgeCarryValid(
        bytes memory _data,
        uint256 _mintAmount
    )
        internal
        pure
        returns (bool)
    {
        if (
            _data.length < BRIDGE_CARRY_HEADER_BYTES
                || _data.length > BRIDGE_CARRY_BYTES
                || _data.length % 32 != 0
        ) {
            return false;
        }

        uint256[] memory words = _unpackBridgeCarry(
            _data
        );

        uint256 pairCount = _bridgeCarryPairCount(
            words[0]
        );

        if (
            _carryEnvelopeVersion(words[0]) != BRIDGE_CARRY_VERSION
                || words[0] >> BRIDGE_CARRY_ENVELOPE_RESERVED_SHIFT != 0
                || words[1] >> BRIDGE_CARRY_TRACKED_RESERVED_SHIFT != 0
                || words[2] >> CARRY_HALF_SHIFT != 0
                || words.length != BRIDGE_CARRY_HEADER_WORDS + (pairCount + 1) / 2
        ) {
            return false;
        }

        (
            bool pairsOk,
            uint256 laneSum
        ) = _carryPairsValid(
            words,
            BRIDGE_CARRY_HEADER_WORDS,
            pairCount,
            words[2],
            true
        );

        if (pairsOk == false) {
            return false;
        }

        uint256 trackedDelta = _carryTrackedDelta(
            words[1]
        );

        if (_carryEnvelopeReferrer(words[0]) == address(0)) {

            if (laneSum != 0 || pairCount != 0) {
                return false;
            }
        } else {

            if (laneSum > trackedDelta) {
                return false;
            }
        }

        if (trackedDelta == 0 && laneSum == 0) {
            return false;
        }

        return trackedDelta <= _mintAmount;
    }

    function _landedCarryPair(
        uint256 _pair,
        uint256 _captureWeek,
        uint256 _arrivalWeek
    )
        internal
        pure
        returns (
            uint256 slot,
            uint256 lane
        )
    {
        uint256 age = (_captureWeek + RING_SLOTS - _carryPairSlot(_pair)) % RING_SLOTS
            + _carryPairRing(_pair) * RING_SLOTS;

        if (_arrivalWeek > _captureWeek) {
            age += _arrivalWeek - _captureWeek;
        }

        if (_captureWeek > _arrivalWeek) {

            uint256 lag = _captureWeek - _arrivalWeek;

            age = age > lag
                ? age - lag
                : 0;
        }

        if (age >= 2 * RING_SLOTS) {
            return (
                0,
                CARRY_LANE_MATURE
            );
        }

        return (
            (_arrivalWeek + 2 * RING_SLOTS - age) % RING_SLOTS,
            age / RING_SLOTS
        );
    }

    function _packSelfLogRecord(
        uint256 _fromWeek,
        uint256 _completedSeconds,
        uint256 _stake
    )
        internal
        pure
        returns (uint256)
    {
        return _fromWeek
            | (_completedSeconds << SELF_LOG_SECONDS_SHIFT)
            | (_stake << SELF_LOG_STAKE_SHIFT);
    }

    function _selfLogFromWeek(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return _record & SELF_LOG_WEEK_MASK;
    }

    function _selfLogSeconds(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return (_record >> SELF_LOG_SECONDS_SHIFT) & LANE_MASK_80;
    }

    function _selfLogStake(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return (_record >> SELF_LOG_STAKE_SHIFT) & LANE_MASK_80;
    }

    function _packGapRecord(
        uint256 _fromWeek,
        uint256 _toWeekExclusive,
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        return _fromWeek
            | (_toWeekExclusive << GAP_TO_SHIFT)
            | (_mature << GAP_MATURE_SHIFT);
    }

    function _gapRecordFromWeek(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return _record & ((1 << GAP_TO_SHIFT) - 1);
    }

    function _gapRecordToWeek(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return (_record >> GAP_TO_SHIFT) & ((1 << GAP_TO_SHIFT) - 1);
    }

    function _gapRecordMature(
        uint256 _record
    )
        internal
        pure
        returns (uint256)
    {
        return (_record >> GAP_MATURE_SHIFT) & LANE_MASK_80;
    }

    function _laneY1(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & LANE_MASK_80;
    }

    function _laneY2(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_Y2_SHIFT) & LANE_MASK_80;
    }

    function _laneM(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_M_SHIFT) & LANE_MASK_80;
    }

    function _packLanes(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return _y1
            | (_y2 << LANE_Y2_SHIFT)
            | (_m << LANE_M_SHIFT);
    }

    function _saturatingAddCapped(
        uint256 _lane,
        uint256 _add,
        uint256 _cap
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        uint256 sum = _lane + _add;

        if (sum > _cap) {
            return (
                _cap,
                sum - _cap
            );
        }

        return (
            sum,
            0
        );
    }

    function _saturatingAdd80(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        return _saturatingAddCapped(
            _lane,
            _add,
            LANE_MASK_80
        );
    }

    function _saturatingAdd64(
        uint256 _lane,
        uint256 _add
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        return _saturatingAddCapped(
            _lane,
            _add,
            RING_LANE_MAX
        );
    }

    function _saturatingSub(
        uint256 _value,
        uint256 _sub
    )
        internal
        pure
        returns (
            uint256 result,
            uint256 clipped
        )
    {
        if (_sub > _value) {
            return (
                0,
                _sub - _value
            );
        }

        return (
            _value - _sub,
            0
        );
    }

    function _clampLane80(
        uint256 _value
    )
        internal
        pure
        returns (uint256)
    {
        return _value < LANE_MASK_80
            ? _value
            : LANE_MASK_80;
    }

    function _packSelfCrumb(
        uint256 _currentSeconds,
        uint256 _previousSeconds,
        uint256 _settledAt
    )
        internal
        pure
        returns (uint256)
    {
        return _currentSeconds
            | (_previousSeconds << LANE_Y2_SHIFT)
            | (_settledAt << SELF_STAMP_SHIFT);
    }

    function _selfCrumbCurrent(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return _word & LANE_MASK_80;
    }

    function _selfCrumbPrevious(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> LANE_Y2_SHIFT) & LANE_MASK_80;
    }

    function _selfCrumbSettledAt(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> SELF_STAMP_SHIFT) & SELF_STAMP_MASK;
    }

    function _settleSelfCrumb(
        uint256 _word,
        uint256 _tracked,
        uint256 _to
    )
        internal
        pure
        returns (uint256)
    {
        uint256 settledAt = _selfCrumbSettledAt(
            _word
        );

        if (settledAt >= _to) {
            return _word;
        }

        uint256 stake = _clampLane80(
            _tracked
        );

        uint256 fromWeek = settledAt / WEEK;

        uint256 toWeek = _to / WEEK;

        uint256 current = _selfCrumbCurrent(
            _word
        );

        uint256 previous = _selfCrumbPrevious(
            _word
        );

        if (toWeek == fromWeek) {
            current = _clampLane80(
                current + stake * (_to - settledAt)
            );
        } else {
            previous = _completedPreviousSeconds(
                current,
                stake,
                settledAt,
                toWeek
            );

            current = _clampLane80(
                stake * (_to - toWeek * WEEK)
            );
        }

        return _packSelfCrumb(
            current,
            previous,
            _to
        );
    }

    function _completedPreviousSeconds(
        uint256 _current,
        uint256 _stake,
        uint256 _settledAt,
        uint256 _week
    )
        internal
        pure
        returns (uint256)
    {
        if (_settledAt / WEEK + 1 == _week) {
            return _clampLane80(
                _current + _stake * (_week * WEEK - _settledAt)
            );
        }

        return _clampLane80(
            _stake * WEEK
        );
    }

    function _liveSecondsCohort(
        uint256 _from,
        uint256 _to,
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
        pure
        returns (uint256)
    {
        uint256 skipFrom = _from > _disarmedAt
            ? _from
            : _disarmedAt;

        uint256 skipTo = _to < _rearmedAt
            ? _to
            : _rearmedAt;

        if (skipTo <= skipFrom) {
            return _to - _from;
        }

        return _to
            - _from
            - (skipTo - skipFrom);
    }
}
