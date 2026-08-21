// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Third-party custodian rotation shard. `thirdPartyAddress`
 * (declared in {ConfigDeclaration}) receives every forwarded
 * deposit, so redirecting it is the single most sensitive config
 * change. `proposedThirdPartyAddress` + `thirdPartyChangeQueuedAt`
 * back a 3-day propose/execute flow (same shape as the worker
 * rotation) so a compromised master cannot instantly reroute deposit
 * inflow. Appended last as a tail shard so it takes fresh slots and
 * moves no pre-existing slot.
 */
abstract contract ThirdPartyDeclaration {

    address public proposedThirdPartyAddress;

    uint256 public thirdPartyChangeQueuedAt;

    uint256 internal constant THIRD_PARTY_CHANGE_DELAY = 3 days;
}
