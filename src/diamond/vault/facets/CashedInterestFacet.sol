// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Read surface for the global cashed-interest ledger.
 * `getTotalCashedInterest()` returns the running
 * `totalCashedInterest` accumulator — the sum of every user's
 * `cashedInterest` bucket — which `_calculateNeededBuffer` reserves
 * so the sweeper-gated `sweepOverhang` cannot strand settled,
 * already-claimable interest. The backing slot lives in
 * `CashedInterestTotalDeclaration` and this routed view is its
 * single external surface.
 */
contract CashedInterestFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function getTotalCashedInterest()
        external
        view
        returns (uint256)
    {
        return totalCashedInterest;
    }
}
