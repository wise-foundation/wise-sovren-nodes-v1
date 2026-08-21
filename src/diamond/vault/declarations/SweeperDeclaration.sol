// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Sweeper allowlist shard. `isSweeper` gates who may trigger
 * `sweepOverhang`: only allowlisted addresses can move the
 * overhang. The constructor seeds the worker, the third party and
 * the deployer (`_seedSweepers`); on the deterministic CREATE3
 * path the bootstrap shim additionally grants the pending master
 * and revokes its own constructor-seeded grant before handing off
 * ownership. Master can grant or revoke further sweepers via
 * `setSweeper`. The grant is instant (no timelock) because the
 * trigger is the only thing gated — swept funds can only ever
 * reach the 3-day-timelocked `workerAddress`, and the sweep can
 * never take the balance below the reserved buffer plus the
 * `totalCashedInterest` liability. Appended as a tail shard so it
 * takes a fresh tail slot and moves no pre-existing slot.
 */
abstract contract SweeperDeclaration {

    mapping(address => bool) public isSweeper;
}
