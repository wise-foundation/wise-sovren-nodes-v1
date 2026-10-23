// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {CohortPinnedBase} from "../../../src/diamond/vault/facets/pending/CohortPinnedBase.sol";

/**
 * @dev Test-only facet over {CohortPinnedBase}, routed into a harness
 * diamond so a mirror can read the per-user self log the flush planner
 * reads (`cohortSelfLog`, slot 95), which has no production getter,
 * through contract code under DELEGATECALL instead of a raw slot read.
 */
contract CohortSelfLogProbeFacet is CohortPinnedBase {

    function probeSelfLog(
        address _user
    )
        external
        view
        returns (uint256[] memory)
    {
        return cohortSelfLog[_user];
    }
}
