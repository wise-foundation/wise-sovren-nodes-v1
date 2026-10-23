// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 76, retired: `pendingReferralPayout` backed the
 * vault half of a payout rail that was removed before it shipped (the hub
 * is its own pot and never draws on a vault). The word stays declared and
 * unused so the shards behind it keep their slots; it is never written.
 */
abstract contract ReferralPayoutDeclaration {

    uint256 internal pendingReferralPayout;
}
