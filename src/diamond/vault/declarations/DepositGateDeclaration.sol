// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Deposit-gate tail shard. `depositsDisabled` lets master switch
 * off new capital inflow — the direct and Permit2 deposit paths, the
 * only entrypoints that mint fresh shares from underlying — on a chain
 * while everything else keeps working: withdrawals, queue joins and
 * leaves, incentive switches, ERC20 transfers, outbound bridging and
 * inbound `ccipReceive` mints are all unaffected. Queue operations
 * only move already-minted shares between holders and the escrow, so
 * they bring in no new capital and are never gated. This is the
 * dormant-chain mechanism for the multichain rollout — a vault deploys
 * fully wired into the bridge mesh but closed for deposits, and
 * activation later is a single `setDepositsDisabled(false)`. It
 * defaults to `false`, so an untouched vault behaves exactly as before.
 *
 * Packs into the free bytes of the `referralEnabled` / `bridgeGasLimit`
 * slot, so it moves no pre-existing slot.
 */
abstract contract DepositGateDeclaration {

    bool public depositsDisabled;
}
