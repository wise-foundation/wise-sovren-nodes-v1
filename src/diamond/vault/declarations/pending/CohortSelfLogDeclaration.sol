// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 95: the per-week self presence log of every
 * user with a self crumb on this vault (the
 * log once skipped users with no book and no flush, which dropped a
 * referrer's weeks before its first flush here). A self settle piece
 * that crosses a week boundary appends one record `fromWeek(32) |
 * completedSeconds(80) | stake(80)` with bits 192 and up zero: the
 * completed seconds of the week the settle started in and the stake held
 * through every following full week up to the next record. `fromWeek`
 * strictly increases along a log (a record needs a boundary crossing),
 * which the planner's binary search relies on, and a log grows by at most
 * one record per elapsed week. The flush reads a
 * closed week's realised self presence from the log, so a week is priced
 * from its own average however late it is flushed. An empty log, the
 * default, reads zero, which a live diamond holds until the engine is
 * armed. The field is internal; every push emits `CohortSelfLogged`.
 */
abstract contract CohortSelfLogDeclaration {

    mapping(address => uint256[]) internal cohortSelfLog;
}
