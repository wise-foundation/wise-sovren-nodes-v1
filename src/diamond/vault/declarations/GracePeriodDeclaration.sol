// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Grace-period tail shard. A single call that grows a user's
 * share balance by `graceThresholdAmount` or more through a deposit
 * or compound path stamps `lastLargeDepositAt[user]`; until
 * `gracePeriodDuration` has elapsed the user cannot claim, compound
 * or reassign interest, nor relocate the position to another vault
 * (same-chain `moveBetweenVaults` or cross-chain `bridgeToVault`),
 * while plain deposits, withdrawals stay open and interest keeps
 * accruing. Queue fulfillment receipts, plain ERC20 transfers and
 * bridge or peer mints never stamp. `graceThresholdAmount == 0`
 * disables the trigger entirely,
 * so an already-deployed diamond that upgrades to the gated facets
 * with zeroed tail storage behaves exactly as before until master
 * calls the setters. A nonzero threshold must be at least one whole
 * share token (`10 ** decimalsSet`) so a dust-level threshold cannot
 * grace-stamp every ordinary deposit. `MAX_GRACE_PERIOD` bounds the
 * configurable duration so a misconfigured master cannot lock
 * extraction indefinitely. The swappable freeze hook (`GraceFreezeHookFacet`)
 * only enforces the transfer / queue freeze while the master-toggled
 * `graceFreezeEnabled` bool is `true` (default `false`, flipped
 * instantly with no timelock via `setGraceFreezeEnabled`), so the
 * freeze can be switched on or off at any time independently of the
 * always-on interest-extraction gate.
 *
 * Appended last in the declarations linearisation so it takes fresh
 * tail slots and moves no pre-existing slot.
 */
abstract contract GracePeriodDeclaration {

    uint256 public gracePeriodDuration;

    uint256 public graceThresholdAmount;

    mapping(address => uint256) public lastLargeDepositAt;

    bool public graceFreezeEnabled;

    uint256 internal constant MAX_GRACE_PERIOD = 365 days;
}
