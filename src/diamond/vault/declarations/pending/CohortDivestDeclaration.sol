// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 91: the deferred divest park, the one sender the
 * transfer hook could not clamp (only one holding tracked contribution)
 * and its park instant at byte offset 20. An occupied park is never
 * overwritten and both fields clear together; empty by default.
 */
abstract contract CohortDivestDeclaration {

    address internal pendingDivestSync;

    uint64 internal pendingDivestParkedAt;
}
