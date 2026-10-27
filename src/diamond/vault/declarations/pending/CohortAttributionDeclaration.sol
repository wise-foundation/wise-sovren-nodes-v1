// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 90: `attributedContribution`, the slice of an
 * account's tracked contribution that credited a referrer book. A clamp
 * charges a book at most min(deficit, attributed), so attributed never
 * exceeds tracked; zero by default.
 */
abstract contract CohortAttributionDeclaration {

    mapping(address => uint256) internal attributedContribution;
}
