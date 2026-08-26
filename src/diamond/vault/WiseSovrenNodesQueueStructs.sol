// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Shared structs for the queue surface of the merged
 * WiseSovrenNodes diamond — held on a separate abstract so shards and
 * helpers can reference them without circular imports.
 */
abstract contract WiseSovrenNodesQueueStructs {

    struct QueMember {
        address member;
        uint256 amount;
        uint256 tailPointer;
        uint256 headPointer;
    }

    struct QueMemberWithId {
        uint256 memberId;
        int256 incentive;
        address member;
        uint256 amount;
        uint256 tailPointer;
        uint256 headPointer;
    }

    struct SolveForAmountVars {
        int256[] incs;
        int256[] tempIncentives;
        uint256[] tempOrders;
        uint256[] tempPartials;
        uint256 orderIndex;
        uint256 partialIndex;
    }

    struct PlanVars {
        uint256 arraySize;
        uint256 partialId;
        uint256 fullIndex;
        uint256 current;
        uint256 ordersConsidered;
        bool hasPartial;
    }

    struct FulfillOrderBulkVars {
        int256[] incentives;
        uint256[] orders;
        uint256[] partials;
        uint256 partialAmount;
        uint256 minReceiveAmount;
        uint256 maxUsdToSpend;
    }
}
