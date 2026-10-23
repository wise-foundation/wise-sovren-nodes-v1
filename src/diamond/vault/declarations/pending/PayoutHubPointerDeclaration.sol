// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 80 to 82, retired: the payout hub pointer of a
 * vault side payout rail that was removed before it shipped (the hub is
 * its own pot and never draws on a vault). The words stay declared and
 * unused so the shards behind them keep their slots; they are never
 * written.
 */
abstract contract PayoutHubPointerDeclaration {

    address internal payoutHub;

    address internal proposedPayoutHub;

    uint256 internal payoutHubChangeQueuedAt;

    uint256 internal constant PAYOUT_HUB_CHANGE_DELAY = 3 days;
}
