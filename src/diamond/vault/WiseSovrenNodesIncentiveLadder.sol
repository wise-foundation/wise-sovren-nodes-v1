// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The single source of truth for the queue incentive ladder.
 *
 * An incentive is a signed basis-point adjustment to the face value
 * of a queued order: a fulfiller pays
 * `amount * (10000 - incentive) / 10000`. Positive tiers are
 * discounts, where a leaver accepts less than face value to exit
 * sooner. Negative tiers are premiums, where a buyer pays more than
 * face value to take the position over.
 *
 * The discount side keeps the nine tiers of the original vault: zero
 * plus 1, 2, 3, 5, 10, 15, 25 and 50 percent. The premium side is a
 * flat ladder in twenty-percentage-point steps, so tier `i` charges
 * `1 + i/5` times face value, from 1.2x at the first rung up to 50x
 * at the two hundred and forty-fifth. Steps are flat rather than
 * compounding, so the rungs are evenly spaced in price.
 *
 * Every consumer reads the ladder from here. The seeding loop that
 * marks tiers allowed in the constructor, the solver's lane walk,
 * the forecast facet and the cost-prediction views all enumerate the
 * same arrays, which makes "allowed" and "reachable by the solver"
 * the same set by construction. A tier that were allowed but absent
 * from the traversal would accept orders that no quote could ever
 * see, and a tier traversed but not allowed would be planned against
 * and then revert on execution.
 *
 * Order matters as much as membership. Both arrays run best-price
 * first from the buyer's point of view, deepest discount down to
 * zero and then cheapest premium upward, because the solver consumes
 * lanes in array order and its plan is only optimal if the array is
 * sorted that way.
 *
 * The ladder is compiled in rather than passed at construction
 * precisely so that it cannot drift: a constructor argument could
 * seed a set that disagrees with the traversal arrays the solver was
 * compiled against.
 */
library WiseSovrenNodesIncentiveLadder {

    int256 internal constant PREMIUM_STEP = 2_000;

    uint256 internal constant POSITIVE_LANE_COUNT = 9;

    uint256 internal constant PREMIUM_LANE_COUNT = 245;

    function positiveIncentives()
        internal
        pure
        returns (int256[] memory lanes)
    {
        lanes = new int256[](POSITIVE_LANE_COUNT);

        lanes[0] = 5_000;
        lanes[1] = 2_500;
        lanes[2] = 1_500;
        lanes[3] = 1_000;
        lanes[4] = 500;
        lanes[5] = 300;
        lanes[6] = 200;
        lanes[7] = 100;
        lanes[8] = 0;
    }

    function negativeIncentives()
        internal
        pure
        returns (int256[] memory lanes)
    {
        lanes = new int256[](PREMIUM_LANE_COUNT);

        for (uint256 i; i < PREMIUM_LANE_COUNT; ++i) {
            lanes[i] = -PREMIUM_STEP * int256(i + 1);
        }
    }

    function allIncentives()
        internal
        pure
        returns (int256[] memory lanes)
    {
        int256[] memory positives = positiveIncentives();

        lanes = new int256[](POSITIVE_LANE_COUNT + PREMIUM_LANE_COUNT);

        for (uint256 i; i < POSITIVE_LANE_COUNT; ++i) {
            lanes[i] = positives[i];
        }

        for (uint256 j; j < PREMIUM_LANE_COUNT; ++j) {
            lanes[POSITIVE_LANE_COUNT + j] = -PREMIUM_STEP * int256(j + 1);
        }
    }
}
