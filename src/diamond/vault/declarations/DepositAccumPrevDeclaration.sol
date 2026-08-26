// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Previous-bucket extension of the deposit-accumulator shard
 * (`DepositAccumDeclaration`), split out so the earlier tail
 * shards keep their slots. `depositWindowPrevTotal` carries a user's
 * full previous accumulation bucket forward; `applyDepositAccumHook`
 * always tests it together with the current `depositWindowTotal`, so
 * deposits within one `depositAccumWindow` of each other can never
 * dodge the `graceThresholdAmount` sum by straddling a bucket
 * boundary, while co-counting never reaches back two full windows.
 * Cleared alongside the other window records on every stamp and on a
 * two-window skip. Appended as a tail shard so it takes a fresh
 * tail slot and moves no pre-existing slot.
 */
abstract contract DepositAccumPrevDeclaration {

    mapping(address => uint256) public depositWindowPrevTotal;
}
