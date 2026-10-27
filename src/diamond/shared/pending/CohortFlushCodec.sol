// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortWeeks} from "./CohortWeeks.sol";

/**
 * @dev CohortFlushCodec: the envelope a spoke vault sends to the mainnet
 * hub, a packed sequence of 32-byte words without ABI framing.
 *
 * Header `deliverer(160) | flushVersion(8) | crumbVersion(8) |
 * entryCount(8) | flushStamp(64)`, bits 248+ zero; the stamp is the
 * source build time. Each entry is the entry word `referrer(160) |
 * crumbCount(8) | gapCount(8) | flags(8) | selfRunCount(8)`, bits 192+
 * zero, flag bit 0 marking a designation word; the optional designation
 * word `payout(160) | setAt(64) | chainRank(8)`, bits 232+ zero; then
 * `selfRunCount` self runs `fromWeek(32) | toWeekExclusive(32) |
 * selfAverage(80)`, bits 144+ zero, each a span of closed weeks with one
 * realised weekly self average; then `crumbCount` pairs of (week, raw
 * crumb word) and `gapCount` raw gap records. A week's referred average
 * is read by the hub from that week's own crumb or gap record. The
 * builder and the hub both enforce 1 to MAX_FLUSH_ENTRIES entries and at
 * most MAX_FLUSH_WORK work units, a crumb, a self week and a gap week
 * costing one each.
 */
library CohortFlushCodec {

    uint256 internal constant FLUSH_VERSION = 2;

    uint256 internal constant FLUSH_VERSION_SHIFT = 160;

    uint256 internal constant FLUSH_CRUMB_VERSION_SHIFT = 168;

    uint256 internal constant FLUSH_ENTRY_COUNT_SHIFT = 176;

    uint256 internal constant FLUSH_STAMP_SHIFT = 184;

    uint256 internal constant FLUSH_HEADER_RESERVED_SHIFT = 248;

    uint256 internal constant FLUSH_ENTRY_CRUMBS_SHIFT = 160;

    uint256 internal constant FLUSH_ENTRY_GAPS_SHIFT = 168;

    uint256 internal constant FLUSH_ENTRY_FLAGS_SHIFT = 176;

    uint256 internal constant FLUSH_ENTRY_SELF_RUNS_SHIFT = 184;

    uint256 internal constant FLUSH_ENTRY_RESERVED_SHIFT = 192;

    uint256 internal constant FLUSH_FLAG_DESIGNATION = 1;

    uint256 internal constant SELF_RUN_WEEK_MASK = (1 << 32) - 1;

    uint256 internal constant SELF_RUN_TO_SHIFT = 32;

    uint256 internal constant SELF_RUN_AVERAGE_SHIFT = 64;

    uint256 internal constant SELF_RUN_RESERVED_SHIFT = 144;

    uint256 internal constant FLUSH_DESIGNATION_SET_AT_SHIFT = 160;

    uint256 internal constant FLUSH_DESIGNATION_RANK_SHIFT = 224;

    uint256 internal constant FLUSH_DESIGNATION_RESERVED_SHIFT = 232;

    uint256 internal constant DESIGNATION_STAMP_SHIFT = 8;

    uint256 internal constant MAX_FLUSH_ENTRIES = 16;

    // A gas bound: 160 work units measured about 12.5M gas on the worst
    // cold apply at the hub, under the EIP-7825 cap of 16,777,216.
    uint256 internal constant MAX_FLUSH_WORK = 160;

    function _packFlushHeader(
        address _deliverer,
        uint256 _entryCount,
        uint256 _stamp
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_deliverer))
            | (FLUSH_VERSION << FLUSH_VERSION_SHIFT)
            | (CohortWeeks.CRUMB_VERSION << FLUSH_CRUMB_VERSION_SHIFT)
            | (_entryCount << FLUSH_ENTRY_COUNT_SHIFT)
            | (_stamp << FLUSH_STAMP_SHIFT);
    }

    function _flushHeaderDeliverer(
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

    function _flushHeaderVersion(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_VERSION_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushHeaderCrumbVersion(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_CRUMB_VERSION_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushHeaderEntryCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_ENTRY_COUNT_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushHeaderStamp(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_STAMP_SHIFT) & CohortWeeks.RING_LANE_MAX;
    }

    function _packFlushEntry(
        address _referrer,
        uint256 _crumbCount,
        uint256 _gapCount,
        uint256 _flags,
        uint256 _selfRunCount
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_referrer))
            | (_crumbCount << FLUSH_ENTRY_CRUMBS_SHIFT)
            | (_gapCount << FLUSH_ENTRY_GAPS_SHIFT)
            | (_flags << FLUSH_ENTRY_FLAGS_SHIFT)
            | (_selfRunCount << FLUSH_ENTRY_SELF_RUNS_SHIFT);
    }

    function _flushEntrySelfRunCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_ENTRY_SELF_RUNS_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushEntryReferrer(
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

    function _flushEntryCrumbCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_ENTRY_CRUMBS_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushEntryGapCount(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_ENTRY_GAPS_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _flushEntryFlags(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_ENTRY_FLAGS_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }

    function _packSelfRun(
        uint256 _fromWeek,
        uint256 _toWeekExclusive,
        uint256 _selfAverage
    )
        internal
        pure
        returns (uint256)
    {
        return _fromWeek
            | (_toWeekExclusive << SELF_RUN_TO_SHIFT)
            | (_selfAverage << SELF_RUN_AVERAGE_SHIFT);
    }

    function _selfRunFromWeek(
        uint256 _run
    )
        internal
        pure
        returns (uint256)
    {
        return _run & SELF_RUN_WEEK_MASK;
    }

    function _selfRunToWeek(
        uint256 _run
    )
        internal
        pure
        returns (uint256)
    {
        return (_run >> SELF_RUN_TO_SHIFT) & SELF_RUN_WEEK_MASK;
    }

    function _selfRunAverage(
        uint256 _run
    )
        internal
        pure
        returns (uint256)
    {
        return (_run >> SELF_RUN_AVERAGE_SHIFT) & CohortWeeks.LANE_MASK_80;
    }

    function _packFlushDesignation(
        address _payout,
        uint256 _setAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(_payout))
            | (_setAt << FLUSH_DESIGNATION_SET_AT_SHIFT)
            | (_rank << FLUSH_DESIGNATION_RANK_SHIFT);
    }

    function _flushDesignationPayout(
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

    function _flushDesignationSetAt(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_DESIGNATION_SET_AT_SHIFT) & CohortWeeks.RING_LANE_MAX;
    }

    function _flushDesignationRank(
        uint256 _word
    )
        internal
        pure
        returns (uint256)
    {
        return (_word >> FLUSH_DESIGNATION_RANK_SHIFT) & CohortWeeks.CARRY_BYTE_MASK;
    }
}
