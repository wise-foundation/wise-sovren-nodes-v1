// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Master-only surgery on settled interest buckets, plus the
 * accrual-restamp primitive the interest kickoff depends on.
 *
 * `setCashedInterest` serves positions whose owner can no longer
 * sign (lost keys) and deliberate grants or write-offs. It writes
 * `cashedInterest[user]` directly and keeps the
 * `totalCashedInterest` accumulator in lockstep with the delta,
 * exactly like every organic write site, so the INT-7 sum law and
 * the sweep-buffer reservation hold in both directions.
 *
 * The setters touch ONLY the settled bucket: pending accrual is not
 * banked first and keeps accruing on top for a wallet that still
 * holds shares. A wallet-to-wallet rescue is two calls, read the
 * source bucket, set it to zero, set the destination to the read
 * value; the accumulator nets out unchanged. `setCashedInterestBulk`
 * is the same operation over many wallets, accumulating per entry so
 * a repeated address settles to its last value without
 * double-counting.
 *
 * `syncInterestBulk` exists because accrual is measured from each
 * holder's own `lastSyncTimeStamp` and `setInterestRate` writes no
 * checkpoint. Turning the rate on would otherwise pay the new rate
 * back to whenever each holder was last touched. Restamping holders
 * in the same transaction as the rate change is what makes accrual
 * start at the flip, so the launch runbook batches
 * `syncInterestBulk` over every holder and `setInterestRate`
 * through the multicall facet. The sync is correct in either
 * regime: at a zero rate it banks nothing and only restamps, and at
 * a live rate it banks what is genuinely owed before restamping, so
 * it can never silently discard accrual.
 *
 * Bucket surgery is gated by the same one-way
 * `supplyChangeByOwnerNotAllowed` latch as `mintSupply`/
 * `burnSupply`: throwing the latch renounces every master
 * balance-surgery power, those included. The sync deliberately sits
 * outside the latch, because it grants nothing and only banks
 * accrual the holder has already earned. No reentrancy guard: none
 * of these functions makes an external call.
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

    function setCashedInterestBulk(
        address[] calldata _users,
        uint256[] calldata _amounts
    )
        external
        onlyDelegateCall
        onlyMaster
        supplyChangeAllowed
    {
        require(
            _users.length == _amounts.length
                && _users.length > 0,
            InvalidValue()
        );

        uint256 runningTotal = totalCashedInterest;

        for (uint256 i; i < _users.length; ++i) {

            address user = _users[i];

            require(
                user != address(0)
                    && user != address(this),
                InvalidValue()
            );

            uint256 previous = cashedInterest[user];

            cashedInterest[user] = _amounts[i];

            runningTotal = runningTotal
                + _amounts[i]
                - previous;

            emit CashedInterestSet(
                user,
                previous,
                _amounts[i]
            );
        }

        totalCashedInterest = runningTotal;

        emit TotalCashedInterestChanged(
            runningTotal
        );
    }

    function syncInterestBulk(
        address[] calldata _users
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        require(
            _users.length > 0,
            InvalidValue()
        );

        for (uint256 i; i < _users.length; ++i) {

            address user = _users[i];

            require(
                user != address(0)
                    && user != address(this),
                InvalidValue()
            );

            _assignInterest(
                user
            );

            emit InterestSynced(
                user,
                block.timestamp
            );
        }
    }
}
