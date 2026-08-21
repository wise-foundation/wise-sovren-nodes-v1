// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesIncentiveLadder} from "../../src/diamond/vault/WiseSovrenNodesIncentiveLadder.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";

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
 * @dev Exercises the premium half of the incentive ladder, with the
 * emphasis on its extremes. The ladder runs in flat
 * twenty-percentage-point steps from 1.2x face value up to 50x, so
 * the properties worth pinning are that exactly those tiers are
 * accepted and nothing between or beyond them, that the price a
 * fulfiller pays is the tier's multiple of face value with no
 * overflow at the largest amounts the deposit cap permits and no
 * rounding drift at the smallest, and that a book spread across the
 * whole ladder is planned and executed in the same order.
 *
 * The top rung is deliberately checked for exactness rather than
 * tolerance: a 50x premium is a factor of 500000 over a denominator
 * of 10000, which divides evenly, so a fulfiller pays precisely
 * fifty times face and any drift there would be a real defect
 * rather than flooring.
 */
contract WiseSovrenNodesPremiumLadderTest is DiamondTestHarness {

    int256 internal constant FIRST_PREMIUM = -2_000;
    int256 internal constant LAST_PREMIUM = -490_000;
    uint256 internal constant PRECISION_RATE = 10_000;

    address internal seller = address(0xA1);
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

        AdminFacet(address(diamond)).mintSupply(
            seller,
            500_000_000 * 1e6
        );

        usd.mint(
            buyer,
            500_000_000_000 * 1e6
        );

        vm.prank(buyer);
        usd.approve(
            address(diamond),
            type(uint256).max
        );
    }

    function _join(
        address _user,
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (uint256 id)
    {
        vm.prank(_user);

        (
            ,
            id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _amount,
            _incentive
        );
    }

    function _expectedPrice(
        uint256 _amount,
        int256 _premium
    )
        internal
        pure
        returns (uint256)
    {
        return _amount
            * (PRECISION_RATE + uint256(-_premium))
            / PRECISION_RATE;
    }

    // ---- membership: exactly the ladder, nothing else ----

    function test_constructor_seedsEveryLadderTier()
        public
        view
    {
        int256[] memory ladder = WiseSovrenNodesIncentiveLadder.allIncentives();

        assertEq(ladder.length, 254);

        for (uint256 i; i < ladder.length; ++i) {
            assertTrue(diamond.incentiveAllowed(ladder[i]));
        }
    }

    function test_constructor_premiumLadderSpansOnePointTwoToFiftyTimes()
        public
        view
    {
        assertTrue(diamond.incentiveAllowed(FIRST_PREMIUM));
        assertTrue(diamond.incentiveAllowed(LAST_PREMIUM));

        assertEq(
            _expectedPrice(100 * 1e6, FIRST_PREMIUM),
            120 * 1e6
        );

        assertEq(
            _expectedPrice(100 * 1e6, LAST_PREMIUM),
            5_000 * 1e6
        );
    }

    function test_constructor_retiredNegativeTiers_notAllowed()
        public
        view
    {
        assertFalse(diamond.incentiveAllowed(-100));
        assertFalse(diamond.incentiveAllowed(-200));
        assertFalse(diamond.incentiveAllowed(-300));
        assertFalse(diamond.incentiveAllowed(-500));
        assertFalse(diamond.incentiveAllowed(-1_000));
        assertFalse(diamond.incentiveAllowed(-1_500));
        assertFalse(diamond.incentiveAllowed(-2_500));
        assertFalse(diamond.incentiveAllowed(-5_000));
    }

    function test_constructor_offStepAndBeyondLadder_notAllowed()
        public
        view
    {
        assertFalse(diamond.incentiveAllowed(-1_999));
        assertFalse(diamond.incentiveAllowed(-2_001));
        assertFalse(diamond.incentiveAllowed(-489_999));
        assertFalse(diamond.incentiveAllowed(-490_001));
        assertFalse(diamond.incentiveAllowed(-492_000));
        assertFalse(diamond.incentiveAllowed(type(int256).min));
    }

    function test_joinQue_offStepPremium_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(seller);
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            100 * 1e6,
            -2_001
        );
    }

    function test_joinQue_beyondLastPremium_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(seller);
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            100 * 1e6,
            -492_000
        );
    }

    // ---- the premium half is opened after genesis, not in it ----

    function test_constructor_seedsDiscountLanesOnly()
        public
    {
        WiseSovrenNodesDiamond fresh = _newDiamondWithRate(
            address(usd),
            0
        );

        assertTrue(fresh.incentiveAllowed(0));
        assertTrue(fresh.incentiveAllowed(5_000));
        assertFalse(fresh.incentiveAllowed(FIRST_PREMIUM));
        assertFalse(fresh.incentiveAllowed(LAST_PREMIUM));
    }

    function test_setIncentivesAllowed_opensAndClosesLanes()
        public
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = LAST_PREMIUM;

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            false
        );

        assertFalse(diamond.incentiveAllowed(LAST_PREMIUM));

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            true
        );

        assertTrue(diamond.incentiveAllowed(LAST_PREMIUM));
    }

    function test_setIncentivesAllowed_emitsOnlyOnActualChange()
        public
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = LAST_PREMIUM;

        vm.recordLogs();

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            true
        );

        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            false
        );

        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_setIncentivesAllowed_closedLane_rejectsJoin()
        public
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = LAST_PREMIUM;

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            false
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(seller);
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            100 * 1e6,
            LAST_PREMIUM
        );
    }

    function test_setIncentivesAllowed_emptyArray_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            new int256[](0),
            true
        );
    }

    function test_setIncentivesAllowed_nonMaster_reverts()
        public
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = LAST_PREMIUM;

        vm.expectRevert();

        vm.prank(seller);
        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            false
        );
    }

    function test_setIncentivesAllowed_directFacetCall_reverts()
        public
    {
        QueueAdminFacet facet = new QueueAdminFacet();

        int256[] memory lanes = new int256[](1);
        lanes[0] = LAST_PREMIUM;

        vm.expectRevert();

        facet.setIncentivesAllowed(
            lanes,
            true
        );
    }

    // ---- price at the extremes ----

    function test_fulfillOrder_maxPremium_paysExactlyFiftyTimesFace()
        public
    {
        uint256 amount = 1_234_567;

        _join(
            seller,
            amount,
            LAST_PREMIUM
        );

        uint256 sellerBefore = usd.balanceOf(seller);

        vm.prank(buyer);
        (
            uint256 shares,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            LAST_PREMIUM
        );

        assertEq(shares, amount);
        assertEq(paid, amount * 50);
        assertEq(usd.balanceOf(seller) - sellerBefore, amount * 50);
        assertEq(diamond.balanceOf(buyer), amount);
    }

    function test_fulfillOrder_firstPremium_paysOnePointTwoTimesFace()
        public
    {
        uint256 amount = 100 * 1e6;

        _join(
            seller,
            amount,
            FIRST_PREMIUM
        );

        vm.prank(buyer);
        (
            ,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            FIRST_PREMIUM
        );

        assertEq(paid, 120 * 1e6);
    }

    function test_fulfillOrder_maxPremium_nearCapAmount_noOverflow()
        public
    {
        uint256 amount = 100_000_000 * 1e6;

        _join(
            seller,
            amount,
            LAST_PREMIUM
        );

        vm.prank(buyer);
        (
            ,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            LAST_PREMIUM
        );

        assertEq(paid, amount * 50);
    }

    function test_fulfillOrder_maxPremium_singleUnit_paysFifty()
        public
    {
        _join(
            seller,
            1,
            LAST_PREMIUM
        );

        vm.prank(buyer);
        (
            ,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            LAST_PREMIUM
        );

        assertEq(paid, 50);
    }

    function test_predictDiscountedAmount_premiumNeverFallsBelowFace()
        public
        view
    {
        int256[] memory premiums = WiseSovrenNodesIncentiveLadder.negativeIncentives();

        for (uint256 i; i < premiums.length; ++i) {
            assertGe(
                QueueViewFacet(address(diamond)).predictDiscountedAmount(
                    1,
                    premiums[i]
                ),
                1
            );
        }
    }

    function test_partiallyFulfillOrder_maxPremium_splitsExactly()
        public
    {
        uint256 amount = 100 * 1e6;

        _join(
            seller,
            amount,
            LAST_PREMIUM
        );

        vm.prank(buyer);
        (
            uint256 shares,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).partiallyFulfillOrder(
            0,
            LAST_PREMIUM,
            40 * 1e6
        );

        assertEq(shares, 40 * 1e6);
        assertEq(paid, 40 * 1e6 * 50);
    }

    function test_switchQueIncentive_discountToMaxPremium()
        public
    {
        uint256 id = _join(
            seller,
            100 * 1e6,
            5_000
        );

        vm.prank(seller);
        (
            ,
            uint256 newId
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            id,
            5_000,
            LAST_PREMIUM
        );

        assertEq(diamond.activeOrderCountByIncentive(5_000), 0);
        assertEq(diamond.activeOrderCountByIncentive(LAST_PREMIUM), 1);

        vm.prank(buyer);
        (
            ,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            newId,
            LAST_PREMIUM
        );

        assertEq(paid, 100 * 1e6 * 50);
    }

    // ---- a book spread across the whole ladder ----

    function test_solveForAmount_walksCheapestPremiumFirst()
        public
    {
        _join(seller, 100 * 1e6, LAST_PREMIUM);
        _join(seller, 100 * 1e6, FIRST_PREMIUM);
        _join(seller, 100 * 1e6, -4_000);

        (
            int256[] memory incentives,
            uint256[] memory orders,

        ) = QueueViewFacet(address(diamond)).solveForAmount(
            300 * 1e6
        );

        assertEq(orders.length, 3);
        assertEq(incentives[0], FIRST_PREMIUM);
        assertEq(incentives[1], -4_000);
        assertEq(incentives[2], LAST_PREMIUM);
    }

    function test_predictTokensForCost_premiumOnlyBook_seesPremiumLanes()
        public
    {
        _join(
            seller,
            100 * 1e6,
            FIRST_PREMIUM
        );

        assertEq(
            QueueViewFacet(address(diamond)).predictTokensForCost(
                120 * 1e6
            ),
            100 * 1e6
        );
    }

    function test_predictCostForTokens_premiumBook_matchesExecutedCost()
        public
    {
        _join(seller, 100 * 1e6, FIRST_PREMIUM);
        _join(seller, 100 * 1e6, -4_000);

        (
            uint256 quoted,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            200 * 1e6
        );

        assertEq(acquirable, 200 * 1e6);

        uint256 buyerBefore = usd.balanceOf(buyer);

        int256[] memory incentives = new int256[](2);
        incentives[0] = FIRST_PREMIUM;
        incentives[1] = -4_000;

        uint256[] memory orders = new uint256[](2);
        orders[0] = 0;
        orders[1] = 0;

        vm.prank(buyer);
        (
            ,
            uint256 spent
        ) = QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            new uint256[](0),
            0,
            200 * 1e6,
            type(uint256).max
        );

        assertEq(spent, quoted);
        assertEq(buyerBefore - usd.balanceOf(buyer), quoted);
    }

    function test_fulfillOrderBulk_acrossManyLadderTiers()
        public
    {
        int256[] memory incentives = new int256[](20);
        uint256[] memory orders = new uint256[](20);

        uint256 expected;

        for (uint256 i; i < 20; ++i) {
            int256 tier = -2_000 * int256(i + 1);

            _join(
                seller,
                10 * 1e6,
                tier
            );

            incentives[i] = tier;
            orders[i] = 0;
            expected += _expectedPrice(10 * 1e6, tier);
        }

        vm.prank(buyer);
        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            new uint256[](0),
            0,
            200 * 1e6,
            type(uint256).max
        );

        assertEq(received, 200 * 1e6);
        assertEq(spent, expected);
    }

    // ---- fuzz over the ladder ----

    function testFuzz_fulfillOrder_anyPremiumTier_paysTierMultiple(
        uint256 _rung,
        uint256 _amount
    )
        public
    {
        uint256 rung = bound(_rung, 1, 245);
        uint256 amount = bound(_amount, 50 * 1e6, 1_000_000 * 1e6);

        int256 tier = -2_000 * int256(rung);

        _join(
            seller,
            amount,
            tier
        );

        uint256 sellerBefore = usd.balanceOf(seller);

        vm.prank(buyer);
        (
            uint256 shares,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            tier
        );

        assertEq(shares, amount);
        assertEq(paid, _expectedPrice(amount, tier));
        assertGe(paid, amount);
        assertEq(usd.balanceOf(seller) - sellerBefore, paid);
    }

    function testFuzz_predictDiscountedAmount_matchesFulfilledPrice(
        uint256 _rung,
        uint256 _amount
    )
        public
    {
        uint256 rung = bound(_rung, 1, 245);
        uint256 amount = bound(_amount, 50 * 1e6, 100_000 * 1e6);

        int256 tier = -2_000 * int256(rung);

        uint256 quoted = QueueViewFacet(address(diamond)).predictDiscountedAmount(
            amount,
            tier
        );

        _join(
            seller,
            amount,
            tier
        );

        vm.prank(buyer);
        (
            ,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            tier
        );

        assertEq(paid, quoted);
    }
}
