// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortMoveHookFacet: the same-chain move slice of the cohort
 * engine, routed by the dispatcher but reached only through the move
 * forwarders of CohortHookFacet, so it always runs under the
 * `hookExecuting` bracket. Both entrypoints drain a parked sender first
 * and are payable for the same reason as the hook slice.
 */
contract CohortMoveHookFacet is CohortRecorderBase {

    function applyCohortMoveOut(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        _drainPendingDivestCohort();

        _captureMoveOutCohort(
            _user,
            _dstVault,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function applyCohortMoveIn(
        address _user,
        address _srcVault
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        _drainPendingDivestCohort();

        _applyMoveInCohort(
            _user,
            _srcVault
        );
    }
}
