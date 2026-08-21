// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {QueueFacetBase} from "./QueueFacetBase.sol";

struct ForecastVars {
    uint256 priorLeft;
    uint256 amountLeft;
    uint256 orderIndex;
    bool hasPartial;
    uint256 partialId;
    int256 partialIncentive;
    uint256 partialAmount;
    int256[] tempIncentives;
    uint256[] tempOrders;
    uint256[] tempAmounts;
}

/**
 * @dev Read-only queue forecasting on its own facet. Quotes a solve
 * against the queue state as it WOULD look after a solver-optimal
 * fill of a prior amount, so a UI can price a second fill while a
 * first is still pending (or its own earlier leg in a batch).
 *
 * A solver-optimal fill always consumes a best-tier-first prefix of
 * the queue and stops inside at most one order, so the simulated
 * post-fill state is the current state with the walk cursor advanced
 * past that prefix and possibly one order reduced in place. The
 * forecast therefore runs one combined traversal per lane, in the
 * exact tier and list order `_solveForAmount` uses: the prior amount
 * is consumed silently first, then the quoted amount is recorded
 * from wherever the prior fill stopped, against the reduced
 * remainder where they meet inside one order.
 *
 * Unlike `solveForAmount`, the full-order amounts and the partial
 * take are returned as well: the UI cannot read them from chain
 * state because the state being quoted does not exist yet.
 *
 * The lane order is the inherited tier generator shared with the
 * solver, so a forecast can never enumerate a different ladder than
 * the fill it is predicting.
 */
contract QueueForecastFacet is QueueFacetBase {

    constructor()
        QueueFacetBase()
    {}

    function solveForAmountAfterFulfill(
        uint256 _priorAmount,
        uint256 _amount
    )
        public
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory orderAmounts,
            uint256[] memory partials,
            uint256 partialAmount
        )
    {
        ForecastVars memory v = _initializeForecastVars(
            _priorAmount,
            _amount
        );

        int16[9] memory pos = _initializePositiveIncentivesArray();

        for (uint256 i; i < pos.length && v.amountLeft > 0; ++i) {
            _forecastLane(
                v,
                pos[i]
            );
        }

        if (v.amountLeft > 0) {
            int16[8] memory neg = _initializeNegativeIncentivesArray();

            for (uint256 j; j < neg.length && v.amountLeft > 0; ++j) {
                _forecastLane(
                    v,
                    neg[j]
                );
            }
        }

        return _buildForecastResults(
            v
        );
    }

    function _initializeForecastVars(
        uint256 _priorAmount,
        uint256 _amount
    )
        internal
        view
        returns (ForecastVars memory v)
    {
        v.priorLeft = _priorAmount;
        v.amountLeft = _amount;
        v.tempIncentives = new int256[](totalActiveOrders);
        v.tempOrders = new uint256[](totalActiveOrders);
        v.tempAmounts = new uint256[](totalActiveOrders);
    }

    function _forecastLane(
        ForecastVars memory _v,
        int256 _incentive
    )
        internal
        view
    {
        uint256 cursor = currentOrderIdByIncentive[_incentive];
        uint256 laneEnd = earliestValidQueMemberByIncentive[_incentive];

        while (cursor < laneEnd && _v.amountLeft > 0) {

            QueMember storage entry = QueMemberByIdAndIncentive[cursor][_incentive];
            uint256 available = entry.amount;

            if (available == 0) {
                cursor = entry.headPointer;
                continue;
            }

            if (_v.priorLeft >= available) {
                _v.priorLeft -= available;
                cursor = entry.headPointer;
                continue;
            }

            available -= _v.priorLeft;
            _v.priorLeft = 0;

            if (_v.amountLeft >= available) {
                _v.tempIncentives[_v.orderIndex] = _incentive;
                _v.tempOrders[_v.orderIndex] = cursor;
                _v.tempAmounts[_v.orderIndex] = available;
                _v.orderIndex++;
                _v.amountLeft -= available;
                cursor = entry.headPointer;
                continue;
            }

            _v.hasPartial = true;
            _v.partialId = cursor;
            _v.partialIncentive = _incentive;
            _v.partialAmount = _v.amountLeft;
            _v.amountLeft = 0;
        }
    }

    function _buildForecastResults(
        ForecastVars memory _v
    )
        internal
        pure
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory orderAmounts,
            uint256[] memory partials,
            uint256 partialAmount
        )
    {
        uint256 partialCount = _v.hasPartial
            ? 1
            : 0;

        incentives = new int256[](_v.orderIndex + partialCount);
        orders = new uint256[](_v.orderIndex);
        orderAmounts = new uint256[](_v.orderIndex);
        partials = new uint256[](partialCount);

        for (uint256 k; k < _v.orderIndex; k++) {
            incentives[k] = _v.tempIncentives[k];
            orders[k] = _v.tempOrders[k];
            orderAmounts[k] = _v.tempAmounts[k];
        }

        if (_v.hasPartial) {
            incentives[_v.orderIndex] = _v.partialIncentive;
            partials[0] = _v.partialId;
            partialAmount = _v.partialAmount;
        }
    }
}
