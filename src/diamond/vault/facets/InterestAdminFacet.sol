// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Master-only setter for a wallet's settled interest bucket,
 * for positions whose owner can no longer sign (lost keys) and for
 * deliberate grants or write-offs. Writes `cashedInterest[user]`
 * directly and keeps the `totalCashedInterest` accumulator in
 * lockstep with the delta, exactly like every organic write site,
 * so the INT-7 sum law and the sweep-buffer reservation hold in
 * both directions.
 *
 * The setter touches ONLY the settled bucket: pending accrual is
 * not banked first and keeps accruing on top for a wallet that
 * still holds shares. A wallet-to-wallet rescue is two calls, read
 * the source bucket, set it to zero, set the destination to the
 * read value; the accumulator nets out unchanged.
 *
 * Gated by the same one-way `supplyChangeByOwnerNotAllowed` latch
 * as `mintSupply`/`burnSupply`: throwing the latch renounces every
 * master balance-surgery power, this one included. No reentrancy
 * guard: the function makes no external calls.
 */
contract InterestAdminFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function setCashedInterest(
        address _user,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        supplyChangeAllowed
    {
        require(
            _user != address(0)
                && _user != address(this),
            InvalidValue()
        );

        uint256 previous = cashedInterest[_user];

        cashedInterest[_user] = _amount;

        totalCashedInterest = totalCashedInterest
            + _amount
            - previous;

        emit CashedInterestSet(
            _user,
            previous,
            _amount
        );

        emit TotalCashedInterestChanged(
            totalCashedInterest
        );
    }
}
