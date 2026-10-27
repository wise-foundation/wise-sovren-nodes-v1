// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {CohortPinnedBase} from "../../../src/diamond/vault/facets/pending/CohortPinnedBase.sol";

struct PinnedPrefixView {
    address master;
    address proposedMaster;
    bool paused;
    uint256 balance;
    address routedFacet;
    address router;
    address hookFacet;
    uint256 graceDuration;
    uint256 largeDepositAt;
    bool graceFreeze;
}

/**
 * @dev Test-only facet over {CohortPinnedBase}, routed into a harness
 * diamond so its reads and writes of every hand-pinned prefix variable
 * execute against the diamond's real storage under DELEGATECALL. The
 * slim cohort facets inherit the same base, so these pins cover them.
 */
contract CohortPinnedProbeFacet is CohortPinnedBase {

    function probeReadPinned(
        address _user,
        bytes4 _selector
    )
        external
        view
        returns (PinnedPrefixView memory)
    {
        return PinnedPrefixView({
            master: master,
            proposedMaster: proposedMaster,
            paused: paused(),
            balance: balanceOf(
                _user
            ),
            routedFacet: selectorToFacet[_selector],
            router: ccipRouter,
            hookFacet: transferHookFacet,
            graceDuration: gracePeriodDuration,
            largeDepositAt: lastLargeDepositAt[_user],
            graceFreeze: graceFreezeEnabled
        });
    }

    function probeWritePinned(
        PinnedPrefixView calldata _view,
        address _user,
        bytes4 _selector
    )
        external
    {
        proposedMaster = _view.proposedMaster;

        if (_view.paused == true && paused() == false) {
            _pause();
        }

        if (_view.paused == false && paused() == true) {
            _unpause();
        }

        _balances[_user] = _view.balance;

        selectorToFacet[_selector] = _view.routedFacet;

        ccipRouter = _view.router;

        transferHookFacet = _view.hookFacet;

        gracePeriodDuration = _view.graceDuration;

        lastLargeDepositAt[_user] = _view.largeDepositAt;

        graceFreezeEnabled = _view.graceFreeze;
    }

    function probeLockedCall(
        bytes calldata _data
    )
        external
        nonReentrant
        returns (bytes memory)
    {
        (
            bool success,
            bytes memory returnData
        ) = address(this).call(
            _data
        );

        require(
            success == false,
            InvalidValue()
        );

        return returnData;
    }

    function probeLockOpen()
        external
        nonReentrant
        returns (bool)
    {
        return true;
    }
}
