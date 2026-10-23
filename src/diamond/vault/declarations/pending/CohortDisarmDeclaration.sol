// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 93 and 94: the disarm span and the outage grace
 * stamps (slot 93 byte offsets 0, 8, 16 and 24; slot 94 offsets 0 and 8).
 * A span exists only while `cohortRearmedAt` is above `cohortDisarmedAt`;
 * the grace ends are never lowered or cleared. Zero stamps, the default,
 * describe no span, so every segment counts in full as before.
 */
abstract contract CohortDisarmDeclaration {

    uint256 internal constant FLUSH_OUTAGE_GRACE = 1 days;

    uint64 internal cohortDisarmedAt;

    uint64 internal cohortRearmedAt;

    uint64 internal referralReopenStamp;

    uint64 internal referralPauseStamp;

    uint64 internal referralPauseGraceEnd;

    uint64 internal referralDisarmGraceEnd;
}
