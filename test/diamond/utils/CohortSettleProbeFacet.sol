// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {FacetBase} from "../../../src/diamond/vault/facets/FacetBase.sol";

/**
 * @dev Test only facet over the full declaration chain, routed into a harness diamond so
 * the full chain copy of the settle touchpoint (`_cohortSettle` of the base helper, whose
 * production caller is the slim flush transport through its own copy) executes against the
 * diamond's real storage under DELEGATECALL: disarmed it returns, armed it dispatches the
 * settle into the transfer hook facet.
 */
contract CohortSettleProbeFacet is FacetBase {

    function probeSettle(
        address _referrer
    )
        external
    {
        _cohortSettle(
            _referrer
        );
    }
}
