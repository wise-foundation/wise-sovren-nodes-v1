// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesQueueHelper} from "./WiseSovrenNodesQueueHelper.sol";

/**
 * @dev UI/view layer for the queue surface: fulfillment planning,
 * cost/token prediction, and order listing for off-chain consumption.
 */
abstract contract WiseSovrenNodesQueueUIHelper is WiseSovrenNodesQueueHelper {

    function getFulfillmentPlanForIncentive(
        uint256 _amount,
        int256 _incentive,
        uint256 _maxOrdersToConsider
    )
        public
        view
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds,
            uint256 nextStartingId
        )
    {
        uint256 considerationLimit = _maxOrdersToConsider;

        if (considerationLimit == 0 || considerationLimit > MAX_ORDERS_TO_CONSIDER_LIMIT) {
            considerationLimit = MAX_ORDERS_TO_CONSIDER_LIMIT;
        }

        uint256 activeCount = activeOrderCountByIncentive[_incentive];

        if (activeCount == 0) {
            fullOrderIds = new uint256[](0);
            partialOrderIds = new uint256[](0);
            nextStartingId = currentOrderIdByIncentive[_incentive];

            return (
                fullOrderIds,
                partialOrderIds,
                nextStartingId
            );
        }

        PlanVars memory v = _initializePlanVars(
            activeCount,
            _maxOrdersToConsider
        );

        uint256[] memory tempFull = new uint256[](v.arraySize);
        v.current = currentOrderIdByIncentive[_incentive];
        nextStartingId = v.current;
        uint256 amountLeft = _amount;

        while (
            _shouldContinuePlanTraversal(
                amountLeft,
                v,
                _incentive,
                _maxOrdersToConsider,
                considerationLimit
            )
        ) {
            (
                amountLeft,
                nextStartingId
            ) = _processOrderInPlan(
                v,
                tempFull,
                amountLeft,
                _incentive
            );
        }

        (
            fullOrderIds,
            partialOrderIds
        ) = _buildFinalOrderArrays(
            v,
            tempFull
        );
    }

    function solveForAmount(
        uint256 _amount
    )
        public
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        return _solveForAmount(
            _amount,
            true
        );
    }

    function predictDiscountedAmount(
        uint256 _amount,
        int256 _incentive
    )
        public
        pure
        returns (uint256 discountedAmount)
    {
        return _predictChargedAmount(
            _amount,
            _incentive
        );
    }

    function predictCostForTokens(
        uint256 _tokensToReceive
    )
        public
        view
        returns (
            uint256 costInUsd,
            uint256 tokensAcquirable
        )
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = solveForAmount(
            _tokensToReceive
        );

        uint256 totalTokensPlanned;

        (
            costInUsd,
            totalTokensPlanned
        ) = _calculateFullOrdersCost(
            orders,
            incentives
        );

        (
            uint256 partialCost,
            uint256 partialTokens
        ) = _calculatePartialOrderCost(
            partials,
            incentives,
            orders.length,
            _tokensToReceive,
            totalTokensPlanned
        );

        costInUsd += partialCost;
        tokensAcquirable = totalTokensPlanned + partialTokens;
    }

    function predictTokensForCost(
        uint256 _costInUsd
    )
        public
        view
        returns (uint256 tokensReceived)
    {
        uint256 remainingUsd = _costInUsd;
        int256[] memory incs = _initializeAllIncentivesArray();

        for (uint256 i = 0; i < incs.length; i++) {
            if (remainingUsd == 0) {
                break;
            }

            (
                uint256 tokens,
                uint256 spent
            ) = _processIncentiveForCost(
                incs[i],
                remainingUsd
            );

            tokensReceived += tokens;
            remainingUsd -= spent;
        }

        return tokensReceived;
    }

    function getAllOrdersfromAddress(
        address _user
    )
        public
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        return _collectAllOrders(
            _user,
            true
        );
    }

    function getAllOrdersOverall()
        public
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        return _collectAllOrders(
            address(0),
            false
        );
    }

    function getAllOrdersOverallWithId()
        public
        view
        returns (QueMemberWithId[] memory)
    {
        return _collectAllOrdersWithId(
            address(0),
            false
        );
    }

    function getAllOrdersfromAddressWithId(
        address _user
    )
        public
        view
        returns (QueMemberWithId[] memory)
    {
        return _collectAllOrdersWithId(
            _user,
            true
        );
    }
}
