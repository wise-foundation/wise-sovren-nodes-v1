// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Sweeper-gated overhang sweep. Any address master has
 * granted via `setSweeper` can trigger `sweepOverhang()`; the
 * excess `USD_TOKEN` above two weeks of interest at the configured
 * rate plus the settled `totalCashedInterest` liability is
 * transferred to the registered `workerAddress`. `getOverhang()`
 * is the corresponding open view.
 */
contract SweepFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function sweepOverhang()
        external
        onlyDelegateCall
        nonReentrant
        returns (uint256 amount)
    {
        amount = _executeSweepOverhang();
    }

    function getOverhang()
        external
        view
        returns (uint256)
    {
        return _calculateOverhang();
    }
}
