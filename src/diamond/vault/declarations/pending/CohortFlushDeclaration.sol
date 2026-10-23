// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 83 to 89: the flush transport. The hub pointer
 * and chain selector with their timelocked change, each referrer's send
 * cursors (`flushedThroughWeek`; `flushGapCursor` with the gap index in the
 * low 128 bits and the resume week in the high 128), the courier allowlist,
 * the public flush switch and the message gas limit (zero means the
 * default). A zero hub, the virgin default, makes every flush revert
 * FlushHubNotSet.
 */
abstract contract CohortFlushDeclaration {

    address internal flushHub;

    uint64 internal flushHubChainSelector;

    address internal proposedFlushHub;

    uint64 internal proposedFlushHubChainSelector;

    uint256 internal flushHubChangeQueuedAt;

    mapping(address => uint256) internal flushedThroughWeek;

    mapping(address => uint256) internal flushGapCursor;

    mapping(address => bool) internal allowedFlushBot;

    bool internal publicFlushEnabled;

    uint64 internal flushGasLimit;

    uint256 internal constant FLUSH_HUB_CHANGE_DELAY = 3 days;

    uint256 internal constant FLUSH_GAP_CURSOR_WEEK_SHIFT = 128;

    uint64 internal constant FLUSH_GAS_LIMIT = 300_000;

    uint64 internal constant MAX_FLUSH_GAS_LIMIT = 2_000_000;
}
