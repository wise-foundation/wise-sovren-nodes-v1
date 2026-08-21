// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Global cashed-interest ledger shard. `totalCashedInterest`
 * mirrors the sum of the per-user `cashedInterest` mapping at all
 * times: accrual (`_assignInterest`) adds the banked pending
 * interest, `_prepareClaim` subtracts the zeroed bucket,
 * `_prepareExactAmountClaim` subtracts the debited amount, and the
 * constructor migration seed (`_migrateInterest`) applies the
 * per-address delta so duplicate distribution addresses cannot
 * double-count. `_executeMoveInterestTo` shifts interest between
 * users and is net-zero for the sum, so it deliberately leaves the
 * accumulator untouched. Every mutation emits
 * `TotalCashedInterestChanged` with the new running total. The
 * accumulator feeds `_calculateNeededBuffer` so the sweeper-gated
 * `sweepOverhang` reserves the settled, already-claimable interest
 * liability on top of the two-week forward buffer and can no longer
 * strand pending claims. Declared `internal` rather than `public`:
 * the single external surface is
 * `CashedInterestFacet.getTotalCashedInterest()`. Appended
 * as a tail shard so it takes a fresh tail slot and moves no
 * pre-existing slot.
 */
abstract contract CashedInterestTotalDeclaration {

    uint256 internal totalCashedInterest;
}
