// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 77 to 79: the chain ReferralRegistry pointer and
 * its timelocked change. A zero pointer turns referrals off in both
 * directions, which is also the virgin default; an execute probes
 * `referrerOf` for a 32-byte answer.
 */
abstract contract ReferralRegistryPointerDeclaration {

    address internal referralRegistry;

    address internal proposedReferralRegistry;

    uint256 internal referralRegistryChangeQueuedAt;

    uint256 internal constant REFERRAL_REGISTRY_CHANGE_DELAY = 3 days;
}
