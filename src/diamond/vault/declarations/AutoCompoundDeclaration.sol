// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Auto-compound tail shard. `isAutoCompoundBot` is the
 * master-set keeper allowlist, `autoCompoundAllowed` the per-user
 * opt-in and `autoCompoundFeeBps` the keeper reward in basis points
 * of the compounded interest (100 = 1%), capped at
 * `MAX_AUTO_COMPOUND_FEE_BPS`. All three default to zero, so a
 * diamond routing the facet with zeroed tail storage compounds
 * nothing until configured. Appended as a tail shard so it takes
 * fresh slots 64-66 and moves no pre-existing slot; first shard
 * activated onto live diamonds post-genesis, whose frozen
 * dispatchers cannot serve the getters, so their selectors are
 * routed alongside the functions.
 */
abstract contract AutoCompoundDeclaration {

    mapping(address => bool) public isAutoCompoundBot;

    mapping(address => bool) public autoCompoundAllowed;

    uint256 public autoCompoundFeeBps;

    uint256 internal constant MAX_AUTO_COMPOUND_FEE_BPS = 500;
}
