// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Exercises every quote and best-option view on a MIXED book:
 * discount and premium lanes open and populated at the same time,
 * which is exactly the shape a finished deployment runs. The solver
 * drains the nine discount lanes in ladder order first and enters
 * the premium lanes cheapest-first only when the discount side is
 * fully consumed with amount left over; a partial fill on a discount
 * lane absorbs the remainder by definition and ends the plan with
 * the premium side untouched. Every plan a quote returns must
 * execute for exactly the quoted cost and token count, pinned here
 * end to end through `fulfillOrderBulk` and differentially against
 * the forecast facet.
 *
 * The suite also characterises the allowed-map split: no view reads
 * `incentiveAllowed`, so a lane closed while holding live orders
 * keeps appearing in every quote while execution and member exit
 * both revert on it until it is reopened. That divergence is pinned
 * as current behaviour, not endorsed as design.
 *
 * The fixture amounts divide evenly by every touched price factor,
 * so the exact-equality assertions carry no flooring tolerance. The
 * one place flooring is inherent, the reverse quote's final partial,
 * is bounded by the worst lane factor in the book: a token count
 * reconstructed from a floored cost can fall short of the planned
 * count by at most two token units at the 9500 factor.
 */
contract WiseSovrenNodesMixedBookQuotesTest is DiamondTestHarness {

    uint256 internal constant DISCOUNT_TOTAL = 770 * 1e6;
    uint256 internal constant BOOK_TOTAL = 1_520 * 1e6;
    uint256 internal constant CROSS_AMOUNT = 1_270 * 1e6;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant ROUND_TRIP_SLACK = 2;

    address internal seller1 = address(0xA1);
    address internal seller2 = address(0xA2);
    address internal seller3 = address(0xA3);
    address internal buyer = address(0xF1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _deployDiamondWithQueueAtRate(
            address(usd),
            0
        );

        QueueAdminFacet(address(diamond)).changeMinDepositAmount(
            1
        );

        _mintAndJoin(seller1, 300 * 1e6, 500);
        _mintAndJoin(seller2, 200 * 1e6, 500);
        _mintAndJoin(seller1, 150 * 1e6, 100);
        _mintAndJoin(seller2, 120 * 1e6, 0);
        _mintAndJoin(seller1, 400 * 1e6, -2_000);
        _mintAndJoin(seller2, 250 * 1e6, -4_000);
        _mintAndJoin(seller3, 100 * 1e6, -490_000);

        usd.mint(
            buyer,
            1_000_000_000 * 1e6
        );

        vm.prank(buyer);
        usd.approve(
            address(diamond),
            type(uint256).max
        );
    }

    function _mintAndJoin(
        address _seller,
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (uint256 id)
    {
        AdminFacet(address(diamond)).mintSupply(
            _seller,
            _amount
        );

        vm.prank(
            _seller
        );

        (
            ,
            id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _amount,
            _incentive
        );
    }

    function _charged(
        uint256 _amount,
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 factor = _incentive >= 0
            ? PRECISION_RATE - uint256(_incentive)
            : PRECISION_RATE + uint256(-_incentive);

        uint256 charged = _amount * factor / PRECISION_RATE;

        return charged == 0
            ? _amount
            : charged;
    }

    function _planWithTake(
        uint256 _amount
    )
        internal
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials,
            uint256 partialTake
        )
    {
        (
            incentives,
            orders,
            partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            _amount
        );

        uint256 covered;

        for (uint256 i; i < orders.length; i++) {
            (
                ,
                uint256 amt,
                ,
            ) = diamond.QueMemberByIdAndIncentive(
                orders[i],
                incentives[i]
            );

            covered += amt;
        }

        partialTake = partials.length > 0
            ? _amount - covered
            : 0;
    }

    function _fulfillPlan(
        uint256 _amount
    )
        internal
        returns (
            uint256 received,
            uint256 spent
        )
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials,
            uint256 partialTake
        ) = _planWithTake(
            _amount
        );

        if (orders.length == 0 && partials.length == 0) {
            return (
                0,
                0
            );
        }

        vm.prank(
            buyer
        );

        return QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            partialTake,
            0,
            type(uint256).max
        );
    }

    function _realSolveWithAmounts(
        uint256 _y
    )
        internal
        view
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory orderAmounts,
            uint256[] memory partials,
            uint256 partialAmount
        )
    {
        (
            incentives,
            orders,
            partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            _y
        );

        orderAmounts = new uint256[](orders.length);

        uint256 covered;

        for (uint256 i; i < orders.length; i++) {
            (
                ,
                uint256 amt,
                ,
            ) = diamond.QueMemberByIdAndIncentive(
                orders[i],
                incentives[i]
            );

            orderAmounts[i] = amt;
            covered += amt;
        }

        partialAmount = partials.length > 0
            ? _y - covered
            : 0;
    }

    function _assertForecastMatchesReality(
        uint256 _x,
        uint256 _y
    )
        internal
    {
        (
            int256[] memory fIncs,
            uint256[] memory fOrders,
            uint256[] memory fAmounts,
            uint256[] memory fPartials,
            uint256 fPartialAmount
        ) = QueueForecastFacet(address(diamond)).solveForAmountAfterFulfill(
            _x,
            _y
        );

        _fulfillPlan(
            _x
        );

        (
            int256[] memory rIncs,
            uint256[] memory rOrders,
            uint256[] memory rAmounts,
            uint256[] memory rPartials,
            uint256 rPartialAmount
        ) = _realSolveWithAmounts(
            _y
        );

        assertEq(
            abi.encode(fIncs),
            abi.encode(rIncs),
            "incentives diverge"
        );

        assertEq(
            abi.encode(fOrders),
            abi.encode(rOrders),
            "orders diverge"
        );

        assertEq(
            abi.encode(fAmounts),
            abi.encode(rAmounts),
            "order amounts diverge"
        );

        assertEq(
            abi.encode(fPartials),
            abi.encode(rPartials),
            "partials diverge"
        );

        assertEq(
            fPartialAmount,
            rPartialAmount,
            "partial amount diverges"
        );
    }

    function _setLaneAllowed(
        int256 _incentive,
        bool _allowed
    )
        internal
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = _incentive;

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            _allowed
        );
    }

    // ---- solve plans on a mixed book ----

    function test_solveForAmount_mixedBook_prefersDiscountLanesInLadderOrder()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            550 * 1e6
        );

        int256[] memory expIncs = new int256[](3);
        expIncs[0] = 500;
        expIncs[1] = 500;
        expIncs[2] = 100;

        uint256[] memory expOrders = new uint256[](2);
        expOrders[0] = 0;
        expOrders[1] = 1;

        uint256[] memory expPartials = new uint256[](1);
        expPartials[0] = 0;

        assertEq(
            abi.encode(incentives),
            abi.encode(expIncs)
        );

        assertEq(
            abi.encode(orders),
            abi.encode(expOrders)
        );

        assertEq(
            abi.encode(partials),
            abi.encode(expPartials)
        );
    }

    function test_solveForAmount_discountPartial_endsPlanBeforePremiums()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            100 * 1e6
        );

        assertEq(
            incentives.length,
            1
        );

        assertEq(
            incentives[0],
            500
        );

        assertEq(
            orders.length,
            0
        );

        assertEq(
            partials.length,
            1
        );

        assertEq(
            partials[0],
            0
        );
    }

    function test_solveForAmount_exactDiscountDrain_noPremiumEntry()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            DISCOUNT_TOTAL
        );

        int256[] memory expIncs = new int256[](4);
        expIncs[0] = 500;
        expIncs[1] = 500;
        expIncs[2] = 100;
        expIncs[3] = 0;

        assertEq(
            abi.encode(incentives),
            abi.encode(expIncs)
        );

        assertEq(
            orders.length,
            4
        );

        assertEq(
            partials.length,
            0
        );
    }

    function test_solveForAmount_crossesIntoPremiums_cheapestFirst()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            CROSS_AMOUNT
        );

        int256[] memory expIncs = new int256[](6);
        expIncs[0] = 500;
        expIncs[1] = 500;
        expIncs[2] = 100;
        expIncs[3] = 0;
        expIncs[4] = -2_000;
        expIncs[5] = -4_000;

        assertEq(
            abi.encode(incentives),
            abi.encode(expIncs)
        );

        assertEq(
            orders.length,
            5
        );

        assertEq(
            partials.length,
            1
        );

        assertEq(
            partials[0],
            0
        );
    }

    function test_solveForAmount_exceedsWholeBook_plansAllOrdersNoPartial()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            BOOK_TOTAL + 1
        );

        int256[] memory expIncs = new int256[](7);
        expIncs[0] = 500;
        expIncs[1] = 500;
        expIncs[2] = 100;
        expIncs[3] = 0;
        expIncs[4] = -2_000;
        expIncs[5] = -4_000;
        expIncs[6] = -490_000;

        assertEq(
            abi.encode(incentives),
            abi.encode(expIncs)
        );

        assertEq(
            orders.length,
            7
        );

        assertEq(
            partials.length,
            0
        );
    }

    // ---- quotes equal execution across the boundary ----

    function test_predictCostForTokens_mixedBookCrossing_matchesExecutedCost()
        public
    {
        (
            uint256 cost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            CROSS_AMOUNT
        );

        uint256 buyerUsdBefore = usd.balanceOf(
            buyer
        );

        (
            uint256 received,
            uint256 spent
        ) = _fulfillPlan(
            CROSS_AMOUNT
        );

        assertEq(
            received,
            acquirable
        );

        assertEq(
            spent,
            cost
        );

        assertEq(
            buyerUsdBefore - usd.balanceOf(buyer),
            cost
        );

        assertEq(
            diamond.balanceOf(buyer),
            received
        );
    }

    function test_predictCostForTokens_mixedBook_costComponentsSumExactly()
        public
        view
    {
        (
            uint256 cost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            CROSS_AMOUNT
        );

        uint256 expected = _charged(300 * 1e6, 500)
            + _charged(200 * 1e6, 500)
            + _charged(150 * 1e6, 100)
            + _charged(120 * 1e6, 0)
            + _charged(400 * 1e6, -2_000)
            + _charged(100 * 1e6, -4_000);

        assertEq(
            cost,
            expected
        );

        assertEq(
            acquirable,
            CROSS_AMOUNT
        );
    }

    function test_predictTokensForCost_mixedBudget_crossesLadder()
        public
        view
    {
        uint256 budget = _charged(300 * 1e6, 500)
            + _charged(200 * 1e6, 500)
            + _charged(150 * 1e6, 100)
            + _charged(120 * 1e6, 0)
            + _charged(400 * 1e6, -2_000);

        assertEq(
            QueueViewFacet(address(diamond)).predictTokensForCost(
                budget
            ),
            DISCOUNT_TOTAL + 400 * 1e6
        );
    }

    function test_predictTokensForCost_roundTripFromCostQuote_isExact()
        public
        view
    {
        (
            uint256 cost,
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            CROSS_AMOUNT
        );

        assertEq(
            QueueViewFacet(address(diamond)).predictTokensForCost(
                cost
            ),
            CROSS_AMOUNT
        );
    }

    // ---- forecast agrees with reality across the boundary ----

    function test_solveForAmountAfterFulfill_priorCrossesIntoPremiums_matchesReality()
        public
    {
        _assertForecastMatchesReality(
            DISCOUNT_TOTAL + 100 * 1e6,
            300 * 1e6
        );
    }

    function test_solveForAmountAfterFulfill_zeroPrior_matchesPlainSolve_onMixedBook()
        public
        view
    {
        (
            int256[] memory fIncs,
            uint256[] memory fOrders,
            ,
            uint256[] memory fPartials,
        ) = QueueForecastFacet(address(diamond)).solveForAmountAfterFulfill(
            0,
            CROSS_AMOUNT
        );

        (
            int256[] memory pIncs,
            uint256[] memory pOrders,
            uint256[] memory pPartials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            CROSS_AMOUNT
        );

        assertEq(
            abi.encode(fIncs),
            abi.encode(pIncs)
        );

        assertEq(
            abi.encode(fOrders),
            abi.encode(pOrders)
        );

        assertEq(
            abi.encode(fPartials),
            abi.encode(pPartials)
        );
    }

    // ---- single-lane planning at premium tiers ----

    function test_getFulfillmentPlanForIncentive_premiumTier_plansFullsAndPartial()
        public
    {
        _mintAndJoin(seller3, 100 * 1e6, -6_000);
        _mintAndJoin(seller3, 100 * 1e6, -6_000);
        _mintAndJoin(seller3, 100 * 1e6, -6_000);

        (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds,
            uint256 nextStartingId
        ) = QueueViewFacet(address(diamond)).getFulfillmentPlanForIncentive(
            250 * 1e6,
            -6_000,
            0
        );

        assertEq(
            fullOrderIds.length,
            2
        );

        assertEq(
            fullOrderIds[0],
            0
        );

        assertEq(
            fullOrderIds[1],
            1
        );

        assertEq(
            partialOrderIds.length,
            1
        );

        assertEq(
            partialOrderIds[0],
            2
        );

        assertEq(
            nextStartingId,
            2
        );
    }

    function test_solveForAmountWithIncentive_premiumTier_routedThroughDiamond()
        public
    {
        _mintAndJoin(seller3, 100 * 1e6, -2_000);

        (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds
        ) = QueueViewFacet(address(diamond))._solveForAmountWithIncentive(
            450 * 1e6,
            -2_000
        );

        assertEq(
            fullOrderIds.length,
            1
        );

        assertEq(
            fullOrderIds[0],
            0
        );

        assertEq(
            partialOrderIds.length,
            1
        );

        assertEq(
            partialOrderIds[0],
            1
        );
    }

    // ---- closed lanes: quotes stay blind, execution and exit revert ----

    function test_setIncentivesAllowed_closedPopulatedLane_quotedPlanRevertsOnExecution()
        public
    {
        _setLaneAllowed(
            -2_000,
            false
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials,
            uint256 partialTake
        ) = _planWithTake(
            DISCOUNT_TOTAL + 100 * 1e6
        );

        assertEq(
            incentives[incentives.length - 1],
            -2_000
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            partialTake,
            0,
            type(uint256).max
        );

        _setLaneAllowed(
            -2_000,
            true
        );

        (
            uint256 received,
        ) = _fulfillPlan(
            DISCOUNT_TOTAL + 100 * 1e6
        );

        assertEq(
            received,
            DISCOUNT_TOTAL + 100 * 1e6
        );
    }

    function test_setIncentivesAllowed_closedPopulatedLane_blocksMemberExit()
        public
    {
        _setLaneAllowed(
            -2_000,
            false
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            0,
            -2_000
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            0,
            -2_000,
            50 * 1e6
        );

        _setLaneAllowed(
            -2_000,
            true
        );

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            0,
            -2_000,
            50 * 1e6
        );

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            0,
            -2_000
        );

        (
            ,
            uint256 amt,
            ,
        ) = diamond.QueMemberByIdAndIncentive(
            0,
            -2_000
        );

        assertEq(
            amt,
            0
        );
    }

    // ---- fuzzed quote-equals-execution over the mixed book ----

    function testFuzz_solveForAmount_mixedBook_quoteMatchesExecution(
        uint256 _amountSeed
    )
        public
    {
        uint256 amount = bound(
            _amountSeed,
            1,
            BOOK_TOTAL + 50 * 1e6
        );

        (
            uint256 cost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            amount
        );

        (
            uint256 received,
            uint256 spent
        ) = _fulfillPlan(
            amount
        );

        assertEq(
            spent,
            cost
        );

        assertEq(
            received,
            acquirable
        );

        assertEq(
            acquirable,
            amount > BOOK_TOTAL
                ? BOOK_TOTAL
                : amount
        );
    }

    function testFuzz_predictTokensForCost_boundedBySolveAcquirable(
        uint256 _amountSeed
    )
        public
        view
    {
        uint256 amount = bound(
            _amountSeed,
            1,
            BOOK_TOTAL + 50 * 1e6
        );

        (
            uint256 cost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            amount
        );

        uint256 tokens = QueueViewFacet(address(diamond)).predictTokensForCost(
            cost
        );

        assertLe(
            tokens,
            acquirable
        );

        assertLe(
            acquirable - tokens,
            ROUND_TRIP_SLACK
        );
    }
}
