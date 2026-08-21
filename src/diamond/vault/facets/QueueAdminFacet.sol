// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {QueueFacetBase} from "./QueueFacetBase.sol";

/**
 * @dev Master-only queue setters: minimum deposit and the
 * negative-incentive feature flag.
 */
contract QueueAdminFacet is QueueFacetBase {

    constructor()
        QueueFacetBase()
    {}

    function changeMinDepositAmount(
        uint256 _minDepositAmount
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        minDepositAmount = _minDepositAmount;

        emit MinDepositAmountChanged(
            _minDepositAmount
        );
    }

    function setNegativeIncentivesNotAllowed(
        bool _negativeIncentivesNotAllowed
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        negativeIncentivesNotAllowed = _negativeIncentivesNotAllowed;

        emit NegativeIncentivesNotAllowedSet(
            _negativeIncentivesNotAllowed
        );
    }
}
