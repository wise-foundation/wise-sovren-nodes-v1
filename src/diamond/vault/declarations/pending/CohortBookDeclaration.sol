// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 70 to 75: each referrer's book. `cohortBook`
 * packs three 80-bit lanes (year-1, year-2, mature); `cohortLastSettle`
 * is the settle cursor, zero for a book never touched; the two 52-slot
 * rings are indexed by week mod 52; `cohortWeekLog` holds one frozen crumb
 * word per settled week (written flag at bit 252); `cohortGapLog` holds
 * `from | to << 32 | mature << 64` records for dormant tails. All zero by
 * default, so a disarmed diamond behaves as before.
 */
abstract contract CohortBookDeclaration {

    mapping(address => uint256) internal cohortBook;

    mapping(address => uint256) internal cohortLastSettle;

    mapping(address => uint64[52]) internal cohortRingYear1;

    mapping(address => uint64[52]) internal cohortRingYear2;

    mapping(address => mapping(uint256 => uint256)) internal cohortWeekLog;

    mapping(address => uint256[]) internal cohortGapLog;
}
