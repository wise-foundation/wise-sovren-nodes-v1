// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slot 67: the diamond's own `referrerOf` mapping,
 * superseded by the per-chain ReferralRegistry. It stays declared and
 * forever virgin only so every later slot keeps its number; internal, so
 * it has no getter.
 */
abstract contract ReferralRegistryDeclaration {

    mapping(address => address) internal referrerOf;
}
