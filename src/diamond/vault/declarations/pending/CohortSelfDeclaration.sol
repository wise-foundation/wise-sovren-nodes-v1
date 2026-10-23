// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 92: `cohortSelfCrumb`, one word per account,
 * `currentWeekSeconds(80) | previousWeekSeconds(80) | settledAt(64)` with
 * bits 224 and up zero, settled before every change of the account's
 * tracked contribution. A never-written word belongs to an account whose
 * tracked contribution is zero, so it reads as no presence. The routed
 * getter is `getCohortSelfCrumb`.
 */
abstract contract CohortSelfDeclaration {

    mapping(address => uint256) internal cohortSelfCrumb;
}
