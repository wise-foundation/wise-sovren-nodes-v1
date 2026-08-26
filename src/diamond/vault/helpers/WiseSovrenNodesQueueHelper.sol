// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesQueueLowLevelHelper} from "./WiseSovrenNodesQueueLowLevelHelper.sol";

/**
 * @dev Order-processing layer for the queue surface. Owns the
 * `setProxyBenefactor` post-action modifier, `_processOrder`, and
 * the plan/solve traversal.
 */
abstract contract WiseSovrenNodesQueueHelper is WiseSovrenNodesQueueLowLevelHelper {

    modifier setProxyBenefactor() {
        _;
        _setProxyBenefactor(
            ZERO_ADDRESS
        );
    }

    function _processOrder(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        internal
        returns (
            uint256 wiseSovrenNodesTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        _validateOrderProcessing(
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        uint256 discountedAmount = _predictChargedAmount(
            _amount,
            _incentive
        );

        address cashedMember = member.member;

        _changeProxyAccounting(
            _decreaseProxyBalance,
            cashedMember,
            _amount
        );

        _setProxyBenefactor(
            cashedMember
        );

        _executeTransfers(
            cashedMember,
            _amount,
            discountedAmount
        );

        if (_isFullFulfill) {
            currentOrderIdByIncentive[_incentive] = member.headPointer;

            _finalizeMemberRemoval(
                _queMemberId,
                member,
                _incentive,
                false
            );
        } else {
            member.amount -= _amount;
        }

        emit OrderProcessed(
            msg.sender,
            cashedMember,
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        return (
            _amount,
            discountedAmount
        );
    }

    function _fulfillOrderBulk(
        FulfillOrderBulkVars memory vars
    )
        internal
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        require(
            _hasNoOrdersToProcess(
                vars.orders,
                vars.partials
            ) == false,
            NoOrdersPresent()
        );

        for (uint256 i; i < vars.orders.length; ++i) {
            (
                uint256 vt,
                uint256 usd
            ) = _processOrder({
                _queMemberId: vars.orders[i],
                _incentive: vars.incentives[i],
                _amount: QueMemberByIdAndIncentive[vars.orders[i]][vars.incentives[i]].amount,
                _isFullFulfill: true
            });

            vaultTokensReceived += vt;
            usdSpent += usd;
        }

        if (vars.partials.length > 0 && vars.partialAmount > 0) {
            (
                uint256 vt,
                uint256 usd
            ) = _processOrder({
                _queMemberId: vars.partials[0],
                _incentive: vars.incentives[vars.incentives.length - 1],
                _amount: vars.partialAmount,
                _isFullFulfill: false
            });

            vaultTokensReceived += vt;
            usdSpent += usd;
        }

        require(
            vaultTokensReceived >= vars.minReceiveAmount,
            AmountReceivedTooLow()
        );

        require(
            usdSpent <= vars.maxUsdToSpend,
            AmountSpentTooHigh()
        );
    }

    function _processOrderFromContract(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        internal
        returns (
            uint256 wiseSovrenNodesTokenAmount,
            uint256 stableCoinTokenAmount
        )
    {
        _validateOrderProcessing(
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        uint256 discountedAmount = _predictChargedAmount(
            _amount,
            _incentive
        );

        address cashedMember = member.member;

        _changeProxyAccounting(
            _decreaseProxyBalance,
            cashedMember,
            _amount
        );

        _setProxyBenefactor(
            cashedMember
        );

        _executeTransfersFromContract(
            cashedMember,
            _amount,
            discountedAmount
        );

        if (_isFullFulfill) {
            currentOrderIdByIncentive[_incentive] = member.headPointer;

            _finalizeMemberRemoval(
                _queMemberId,
                member,
                _incentive,
                false
            );
        } else {
            member.amount -= _amount;
        }

        emit OrderProcessed(
            msg.sender,
            cashedMember,
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );

        return (
            _amount,
            discountedAmount
        );
    }

    function _fulfillOrderBulkFromContract(
        FulfillOrderBulkVars memory vars
    )
        internal
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        require(
            _hasNoOrdersToProcess(
                vars.orders,
                vars.partials
            ) == false,
            NoOrdersPresent()
        );

        for (uint256 i; i < vars.orders.length; ++i) {
            (
                uint256 vt,
                uint256 usd
            ) = _processOrderFromContract({
                _queMemberId: vars.orders[i],
                _incentive: vars.incentives[i],
                _amount: QueMemberByIdAndIncentive[vars.orders[i]][vars.incentives[i]].amount,
                _isFullFulfill: true
            });

            vaultTokensReceived += vt;
            usdSpent += usd;
        }

        if (vars.partials.length > 0 && vars.partialAmount > 0) {
            (
                uint256 vt,
                uint256 usd
            ) = _processOrderFromContract({
                _queMemberId: vars.partials[0],
                _incentive: vars.incentives[vars.incentives.length - 1],
                _amount: vars.partialAmount,
                _isFullFulfill: false
            });

            vaultTokensReceived += vt;
            usdSpent += usd;
        }

        require(
            vaultTokensReceived >= vars.minReceiveAmount,
            AmountReceivedTooLow()
        );

        require(
            usdSpent <= vars.maxUsdToSpend,
            AmountSpentTooHigh()
        );
    }

    function _executeCompoundViaFulfillBulk(
        FulfillOrderBulkVars memory vars
    )
        internal
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (
            uint256 vaultTokensReceived,
            uint256 usdSpent
        )
    {
        (
            vaultTokensReceived,
            usdSpent
        ) = _fulfillOrderBulkFromContract(
            vars
        );

        _prepareExactAmountClaim(
            msg.sender,
            usdSpent
        );

        uint256 remainder = cashedInterest[msg.sender];

        if (remainder > 0) {
            _handleCompoundInterest(
                msg.sender
            );
        }

        emit CompoundViaQueue(
            msg.sender,
            usdSpent,
            vaultTokensReceived,
            remainder
        );
    }

    function _processOrderInPlan(
        PlanVars memory _v,
        uint256[] memory _tempFull,
        uint256 _amountLeft,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256 newAmountLeft,
            uint256 nextStartingId
        )
    {
        QueMember storage entry = QueMemberByIdAndIncentive[_v.current][_incentive];
        uint256 amt = entry.amount;
        _v.ordersConsidered++;

        if (_isEmptyOrder(entry)) {
            (
                _v.current,
                nextStartingId
            ) = _moveToNextOrder(
                entry,
                _incentive
            );

            return (
                _amountLeft,
                nextStartingId
            );
        }

        if (_amountLeft >= amt) {
            _tempFull[_v.fullIndex] = _v.current;
            _v.fullIndex++;
            newAmountLeft = _amountLeft - amt;

            (
                _v.current,
                nextStartingId
            ) = _moveToNextOrder(
                entry,
                _incentive
            );
        } else {
            _v.partialId = _v.current;
            _v.hasPartial = true;
            newAmountLeft = 0;
            nextStartingId = _v.current;
        }
    }

    function _traverseOrdersForAmount(
        uint256 _amount,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256[] memory tempFull,
            uint256 partialId,
            bool hasPartial,
            uint256 fullIndex
        )
    {
        uint256 total = activeOrderCountByIncentive[_incentive];
        tempFull = new uint256[](total);
        uint256 current = currentOrderIdByIncentive[_incentive];
        uint256 amountLeft = _amount;

        while (
            amountLeft > 0
                && current < earliestValidQueMemberByIncentive[_incentive]
                && fullIndex < total
        ) {
            QueMember storage entry = QueMemberByIdAndIncentive[current][_incentive];

            if (_isEmptyOrder(entry)) {
                current = entry.headPointer;
                continue;
            }

            if (amountLeft >= entry.amount) {
                tempFull[fullIndex] = current;
                fullIndex++;
                amountLeft -= entry.amount;
                current = entry.headPointer;
            } else {
                partialId = current;
                hasPartial = true;
                break;
            }
        }
    }

    function _processIncentiveForCost(
        int256 _incentive,
        uint256 _remainingUsd
    )
        internal
        view
        returns (
            uint256 tokensReceived,
            uint256 usdSpent
        )
    {
        uint256 currentOrderId = currentOrderIdByIncentive[_incentive];
        uint256 earliestId = earliestValidQueMemberByIncentive[_incentive];
        uint256 remainingBudget = _remainingUsd;

        while (currentOrderId < earliestId && remainingBudget > 0) {
            QueMember storage entry = QueMemberByIdAndIncentive[currentOrderId][_incentive];

            if (_isEmptyOrder(entry)) {
                currentOrderId = entry.headPointer;
                continue;
            }

            (
                uint256 tokens,
                uint256 spent
            ) = _processOrderForCost(
                entry,
                _incentive,
                remainingBudget
            );

            tokensReceived += tokens;
            remainingBudget -= spent;

            if (
                spent < _predictChargedAmount(
                    entry.amount,
                    _incentive
                )
            ) {
                break;
            }

            currentOrderId = entry.headPointer;
        }

        usdSpent = _remainingUsd - remainingBudget;
    }

    function _solveForAmountWithIncentive(
        uint256 _amount,
        int256 _incentive
    )
        public
        view
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds
        )
    {
        (
            uint256[] memory tempFull,
            uint256 partialId,
            bool hasPartial,
            uint256 fullIndex
        ) = _traverseOrdersForAmount(
            _amount,
            _incentive
        );

        fullOrderIds = new uint256[](fullIndex);

        for (uint256 i; i < fullIndex; i++) {
            fullOrderIds[i] = tempFull[i];
        }

        if (hasPartial) {
            partialOrderIds = new uint256[](1);
            partialOrderIds[0] = partialId;
        } else {
            partialOrderIds = new uint256[](0);
        }
    }

    function _solveForAmount(
        uint256 _amount,
        bool _allowNegativeIncentives
    )
        internal
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        SolveForAmountVars memory v = _initializeSolveVars();
        uint256 remainingAmount = _amount;

        int256[] memory pos = _initializePositiveIncentivesArray();

        for (uint256 i; i < pos.length && remainingAmount > 0; ++i) {
            (
                uint256[] memory fullIds,
                uint256[] memory partialIds
            ) = _solveForAmountWithIncentive(
                remainingAmount,
                pos[i]
            );

            remainingAmount = _processFullOrdersForIncentive(
                v,
                fullIds,
                pos[i],
                remainingAmount
            );

            if (remainingAmount > 0 && partialIds.length != 0) {
                _processPartialOrderForIncentive(
                    v,
                    partialIds,
                    pos[i]
                );

                remainingAmount = 0;
                break;
            }
        }

        if (_allowNegativeIncentives && remainingAmount > 0) {
            int256[] memory neg = _initializeNegativeIncentivesArray();

            for (uint256 j; j < neg.length && remainingAmount > 0; ++j) {
                (
                    uint256[] memory fullIds,
                    uint256[] memory partialIds
                ) = _solveForAmountWithIncentive(
                    remainingAmount,
                    neg[j]
                );

                remainingAmount = _processFullOrdersForIncentive(
                    v,
                    fullIds,
                    neg[j],
                    remainingAmount
                );

                if (remainingAmount > 0 && partialIds.length != 0) {
                    _processPartialOrderForIncentive(
                        v,
                        partialIds,
                        neg[j]
                    );

                    remainingAmount = 0;
                    break;
                }
            }
        }

        return _buildSolveResults(
            v
        );
    }
}
