// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {QueueFacetBase} from "./QueueFacetBase.sol";

/**
 * @dev Fulfillment surface: single, partial, and bulk. The bulk
 * variant packs args into `FulfillOrderBulkVars` to dodge the
 * stack-too-deep limit.
 */
contract QueueFulfillFacet is QueueFacetBase {

    constructor()
        QueueFacetBase()
    {}

    function fulfillOrder(
        uint256 _queMemberId,
        int256 _incentive
    )
        external
        onlyDelegateCall
        nonReentrant
        setProxyBenefactor
        returns (
            uint256 forwardVaultTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        return _processOrder(
            _queMemberId,
            _incentive,
            QueMemberByIdAndIncentive[_queMemberId][_incentive].amount,
            true
        );
    }

    function partiallyFulfillOrder(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount
    )
        external
        onlyDelegateCall
        nonReentrant
        setProxyBenefactor
        returns (
            uint256 forwardVaultTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        return _processOrder({
            _queMemberId: _queMemberId,
            _incentive: _incentive,
            _amount: _amount,
            _isFullFulfill: false
        });
    }

    function fulfillOrderBulk(
        int256[] calldata _incentives,
        uint256[] calldata _memberIds,
        uint256[] calldata _partialId,
        uint256 _partialAmount,
        uint256 _minReceiveAmount,
        uint256 _maxUsdToSpend
    )
        external
        onlyDelegateCall
        nonReentrant
        setProxyBenefactor
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        FulfillOrderBulkVars memory vars = FulfillOrderBulkVars({
            incentives: _incentives,
            orders: _memberIds,
            partials: _partialId,
            partialAmount: _partialAmount,
            minReceiveAmount: _minReceiveAmount,
            maxUsdToSpend: _maxUsdToSpend
        });

        return _fulfillOrderBulk(
            vars
        );
    }

    function compoundInterestViaFulfillBulk(
        int256[] calldata _incentives,
        uint256[] calldata _memberIds,
        uint256[] calldata _partialId,
        uint256 _partialAmount,
        uint256 _minReceiveAmount,
        uint256 _maxUsdToSpend
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        setProxyBenefactor
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        FulfillOrderBulkVars memory vars = FulfillOrderBulkVars({
            incentives: _incentives,
            orders: _memberIds,
            partials: _partialId,
            partialAmount: _partialAmount,
            minReceiveAmount: _minReceiveAmount,
            maxUsdToSpend: _maxUsdToSpend
        });

        (
            vaultTokensReceived,
            usdSpent
        ) = _executeCompoundViaFulfillBulk(
            vars
        );
    }
}
