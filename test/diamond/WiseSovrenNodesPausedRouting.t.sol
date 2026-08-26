// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
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
 * @dev Covers buying into the vault while minting is shut, which is
 * the routing question a front end has to answer whenever deposits
 * are closed.
 *
 * Both deposit gates only ever stop the paths that mint fresh shares
 * against new underlying. Taking over a queued position mints
 * nothing: the buyer pays the leaver directly and the leaver's
 * escrowed shares move across, so supply and the deposit cap are
 * untouched and the fulfil path is deliberately left open. That
 * asymmetry is what makes the queue the secondary market, and it is
 * pinned here in both directions so neither gate can be tightened
 * onto the fulfil path by accident.
 *
 * The view surface is covered on a book holding only premium orders,
 * because that is the shape a Sovren book takes and because the
 * reverse quote used to enumerate discount lanes alone, which would
 * report that nothing is for sale while the fulfil path happily
 * bought it.
 */
contract WiseSovrenNodesPausedRoutingTest is DiamondTestHarness {

    int256 internal constant FIRST_PREMIUM = -2_000;
    int256 internal constant SECOND_PREMIUM = -4_000;

    address internal seller1 = address(0xA1);
    address internal seller2 = address(0xA2);
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

        AdminFacet(address(diamond)).mintSupply(
            seller1,
            10_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            seller2,
            10_000 * 1e6
        );

        usd.mint(
            buyer,
            10_000_000 * 1e6
        );

        vm.prank(buyer);
        usd.approve(
            address(diamond),
            type(uint256).max
        );

        _join(seller1, 300 * 1e6, FIRST_PREMIUM);
        _join(seller2, 200 * 1e6, FIRST_PREMIUM);
        _join(seller1, 150 * 1e6, SECOND_PREMIUM);
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

    function _shutAllDeposits()
        internal
    {
        AdminFacet(address(diamond)).pauseDeposits();
        AdminFacet(address(diamond)).setDepositsDisabled(true);
    }

    // ---- both gates really are shut ----

    function test_deposit_whenPausedAndDisabled_reverts()
        public
    {
        _shutAllDeposits();

        usd.mint(buyer, 100 * 1e6);

        vm.expectRevert();

        vm.prank(buyer);
        UserFacet(address(diamond)).deposit(
            100 * 1e6
        );
    }

    function test_joinQue_whenPaused_reverts()
        public
    {
        _shutAllDeposits();

        vm.expectRevert();

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            100 * 1e6,
            FIRST_PREMIUM
        );
    }

    function test_switchQueIncentive_whenPaused_reverts()
        public
    {
        _shutAllDeposits();

        vm.expectRevert();

        vm.prank(seller1);
        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            0,
            FIRST_PREMIUM,
            SECOND_PREMIUM
        );
    }

    function test_compoundInterestViaFulfillBulk_whenPaused_reverts()
        public
    {
        _shutAllDeposits();

        int256[] memory incentives = new int256[](1);
        incentives[0] = FIRST_PREMIUM;

        uint256[] memory orders = new uint256[](1);
        orders[0] = 0;

        vm.expectRevert();

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).compoundInterestViaFulfillBulk(
            incentives,
            orders,
            new uint256[](0),
            0,
            0,
            type(uint256).max
        );
    }

    // ---- the fulfil path stays open ----

    function test_fulfillOrder_whenPausedAndDisabled_succeeds()
        public
    {
        _shutAllDeposits();

        uint256 supplyBefore = diamond.totalSupply();

        vm.prank(buyer);
        (
            uint256 shares,
            uint256 paid
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            FIRST_PREMIUM
        );

        assertEq(shares, 300 * 1e6);
        assertEq(paid, 360 * 1e6);
        assertEq(diamond.balanceOf(buyer), 300 * 1e6);
        assertEq(diamond.totalSupply(), supplyBefore);
    }

    function test_partiallyFulfillOrder_whenPausedAndDisabled_succeeds()
        public
    {
        _shutAllDeposits();

        vm.prank(buyer);
        (
            uint256 shares,

        ) = QueueFulfillFacet(address(diamond)).partiallyFulfillOrder(
            0,
            FIRST_PREMIUM,
            100 * 1e6
        );

        assertEq(shares, 100 * 1e6);
        assertEq(diamond.balanceOf(buyer), 100 * 1e6);
    }

    function test_quoteThenFulfillBulk_whenPaused_endToEnd()
        public
    {
        _shutAllDeposits();

        uint256 wanted = 500 * 1e6;

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            wanted
        );

        (
            uint256 quotedCost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            wanted
        );

        assertEq(acquirable, wanted);

        uint256 buyerUsdBefore = usd.balanceOf(buyer);

        vm.prank(buyer);
        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            0,
            wanted,
            quotedCost
        );

        assertEq(received, wanted);
        assertEq(spent, quotedCost);
        assertEq(buyerUsdBefore - usd.balanceOf(buyer), quotedCost);
        assertEq(diamond.balanceOf(buyer), wanted);
    }

    function test_fulfillOrderBulk_withPartial_whenPaused_endToEnd()
        public
    {
        _shutAllDeposits();

        uint256 wanted = 400 * 1e6;

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            wanted
        );

        assertEq(partials.length, 1);

        uint256 fullTotal;

        for (uint256 i; i < orders.length; ++i) {
            fullTotal += QueueViewFacet(address(diamond)).predictDiscountedAmount(
                0,
                incentives[i]
            );
        }

        vm.prank(buyer);
        (
            uint256 received,

        ) = QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            wanted - 300 * 1e6,
            wanted,
            type(uint256).max
        );

        assertEq(received, wanted);
        assertEq(fullTotal, 0);
    }

    // ---- the view surface on a premium-only book ----

    function test_solveForAmount_premiumOnlyBook_returnsPremiumLanes()
        public
        view
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,

        ) = QueueViewFacet(address(diamond)).solveForAmount(
            500 * 1e6
        );

        assertEq(orders.length, 2);
        assertEq(incentives[0], FIRST_PREMIUM);
        assertEq(incentives[1], FIRST_PREMIUM);
    }

    function test_predictTokensForCost_premiumOnlyBook_seesTheBook()
        public
        view
    {
        assertEq(
            QueueViewFacet(address(diamond)).predictTokensForCost(
                360 * 1e6
            ),
            300 * 1e6
        );
    }

    function test_predictTokensForCost_wholePremiumBook()
        public
        view
    {
        uint256 wholeBook = 500 * 1e6 * 12_000 / 10_000
            + 150 * 1e6 * 14_000 / 10_000;

        assertEq(
            QueueViewFacet(address(diamond)).predictTokensForCost(
                wholeBook
            ),
            650 * 1e6
        );
    }

    function test_getAllOrdersOverallWithId_listsPremiumBook()
        public
        view
    {
        assertEq(
            QueueViewFacet(address(diamond)).getAllOrdersOverallWithId().length,
            3
        );
    }

    function test_solveForAmount_shallowBook_returnsShortPlan()
        public
        view
    {
        (
            ,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            10_000 * 1e6
        );

        assertEq(orders.length, 3);
        assertEq(partials.length, 0);
    }

    function test_fulfillOrderBulk_planAlreadyConsumed_reverts()
        public
    {
        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            500 * 1e6
        );

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            FIRST_PREMIUM
        );

        _shutAllDeposits();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ZeroAmount.selector
        );

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_fulfillOrder_behindTheCursor_reverts()
        public
    {
        _shutAllDeposits();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.OrderNotReady.selector
        );

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrder(
            1,
            FIRST_PREMIUM
        );
    }

    // ---- chained quotes ----

    function test_solveForAmountAfterFulfill_whenPaused_matchesReality()
        public
    {
        _shutAllDeposits();

        uint256 prior = 300 * 1e6;
        uint256 wanted = 200 * 1e6;

        (
            int256[] memory fIncentives,
            uint256[] memory fOrders,
            uint256[] memory fAmounts,
            ,

        ) = QueueForecastFacet(address(diamond)).solveForAmountAfterFulfill(
            prior,
            wanted
        );

        (
            int256[] memory pIncentives,
            uint256[] memory pOrders,
            uint256[] memory pPartials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            prior
        );

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            pIncentives,
            pOrders,
            pPartials,
            0,
            prior,
            type(uint256).max
        );

        (
            int256[] memory aIncentives,
            uint256[] memory aOrders,

        ) = QueueViewFacet(address(diamond)).solveForAmount(
            wanted
        );

        assertEq(fOrders.length, aOrders.length);

        for (uint256 i; i < aOrders.length; ++i) {
            assertEq(fOrders[i], aOrders[i]);
            assertEq(fIncentives[i], aIncentives[i]);
            assertGt(fAmounts[i], 0);
        }
    }
}
