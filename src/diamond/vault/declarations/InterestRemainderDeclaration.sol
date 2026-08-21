// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Per-user interest-remainder shard. `interestRemainder` carries
 * the sub-unit fraction of accrued interest that the floored
 * `_calculateInterest` would otherwise discard on every sync. On each
 * `_assignInterest` the scaled pending interest (the `_calculateInterest`
 * numerator before the final `/ PRECISION_FACTOR_E18`) is added to the
 * carried remainder, only the whole units are banked into
 * `cashedInterest`, and the leftover (always `< PRECISION_FACTOR_E18`,
 * i.e. less than one base unit of interest) is stored back here. This
 * makes accrual lossless across an arbitrary number of syncs: banking N
 * tiny intervals now equals banking one interval of the summed duration,
 * so a hostile force-sync (a 1-wei transfer or `moveMyInterestTo`
 * targeting the victim every block) can no longer floor a small holder's
 * interest to zero. Written only by `_assignInterest`; never counted in
 * `totalCashedInterest` until it crosses a whole unit and banks, so the
 * INT-7 accumulator identity and the BUF-3 sweep reserve are unaffected.
 * Appended last as a tail shard so it takes fresh slot 63 and moves no
 * pre-existing slot.
 */
abstract contract InterestRemainderDeclaration {

    mapping(address => uint256) public interestRemainder;
}
