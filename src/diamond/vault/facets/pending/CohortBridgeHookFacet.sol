// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortBridgeHookFacet: the bridge carry and referrer flip slice of
 * the cohort engine, reached by the helper chain stubs through the
 * dispatcher under the `hookExecuting` bracket. An unrouted selector
 * degrades like an uninstalled hook: the capture returns an empty payload,
 * the apply reports failure and the flip reverts so the registry defers
 * it. The flip drains a parked third party first; a parked flipping user
 * is resolved by the migration itself against the old referrer. The
 * entrypoints are payable for the same reason as the hook slice, and the
 * apply never reverts inside `ccipReceive`.
 */
contract CohortBridgeHookFacet is CohortRecorderBase {

    function applyCohortFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        if (pendingDivestSync != _user) {
            _drainPendingDivestCohort();
        }

        _migrateReferrerCohort(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    function applyCohortBridgeOut(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
        returns (bytes memory)
    {
        return _captureBridgeOutCohort(
            _user,
            _dstChainSelector,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function applyCohortBridgeIn(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes calldata _payload
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
        returns (bool)
    {
        return _applyBridgeInCohort(
            _user,
            _srcChainSelector,
            _mintedAmount,
            _payload
        );
    }
}
