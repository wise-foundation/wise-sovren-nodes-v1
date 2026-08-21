// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {QueueFacetBase} from "./QueueFacetBase.sol";

/**
 * @dev Master-only queue setters: minimum deposit, the
 * negative-incentive feature flag, and opening or closing incentive
 * lanes.
 *
 * Lane opening exists because the premium half of the ladder is too
 * large to seed in the diamond's constructor: those writes would
 * push the genesis transaction past the ceiling a single
 * transaction may not exceed. The master opens them in a following
 * transaction instead, feeding the same ladder library the solver
 * traverses, so the lanes that accept orders and the lanes that get
 * quoted stay the same set.
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

    function setIncentivesAllowed(
        int256[] calldata _incentives,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        require(
            _incentives.length > 0,
            InvalidValue()
        );

        for (uint256 i; i < _incentives.length; ++i) {

            int256 incentive = _incentives[i];

            if (incentiveAllowed[incentive] == _allowed) {
                continue;
            }

            incentiveAllowed[incentive] = _allowed;

            emit IncentiveAllowedSet(
                incentive,
                _allowed
            );
        }
    }
}
