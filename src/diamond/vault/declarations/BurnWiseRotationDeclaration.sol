// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Rotating WISE-burn shard. `burnWise` no longer burns the whole
 * accumulated balance in one call; instead each successful burn takes
 * a rotating slice of the current balance from a fixed looping
 * basis-point sequence and advances `burnWiseIndex` by one (wrapping).
 * `lastBurnWiseAt` records the last successful burn timestamp per
 * caller so a single address cannot spam the permissionless surface
 * more than once per `BURN_WISE_COOLDOWN`. The percentage sequence
 * itself lives in a `pure` helper on {BurnWiseFacet} because
 * Solidity has no constant arrays. Appended last as a tail shard so it
 * takes fresh slots and moves no pre-existing slot.
 */
abstract contract BurnWiseRotationDeclaration {

    uint256 public burnWiseIndex;

    mapping(address => uint256) public lastBurnWiseAt;

    uint256 internal constant BURN_WISE_COOLDOWN = 1 days;
}
