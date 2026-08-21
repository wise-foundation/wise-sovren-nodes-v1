// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Two-bucket deposit-accumulator shard backing
 * `GraceAccumHookFacet`. `depositAccumWindow` is the master-set
 * bucket length in seconds over which sub-threshold share-balance
 * increases of one user sum toward `graceThresholdAmount`; `0` — the
 * shipped default, never seeded by the constructor or any deploy
 * script — keeps the accumulator off so the installed hook
 * reproduces the inline single-call semantics exactly until master
 * arms it (instant, no timelock, `setDepositAccumWindow`, bounded by
 * `MAX_GRACE_PERIOD`). `depositWindowStart` anchors the user's
 * current bucket and `depositWindowTotal` is its running total; the
 * full previous bucket is carried forward in
 * `depositWindowPrevTotal` (its own follow-up tail shard,
 * `DepositAccumPrevDeclaration`) and the hook always tests
 * previous plus current, so deposits landing within one window of
 * each other can never dodge the sum by straddling a bucket
 * boundary (lookback bounded by two windows). All per-user records
 * are cleared whenever a stamp happens, so post-stamp dust cannot
 * re-stamp while another full cumulative threshold does. Appended
 * as a tail shard so it takes fresh slots and moves no pre-existing
 * slot.
 */
abstract contract DepositAccumDeclaration {

    uint256 public depositAccumWindow;

    mapping(address => uint256) public depositWindowStart;

    mapping(address => uint256) public depositWindowTotal;
}
