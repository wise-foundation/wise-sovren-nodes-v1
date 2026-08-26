// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";

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
 * @dev Inherit-harness that writes queue entries straight into
 * storage, so the lane walk can be pointed at an order with a zero
 * amount. That state is unreachable through the public surface (a
 * full fulfill unlinks the order, a partial fulfill cannot take the
 * whole remainder, and a reduction must leave the minimum deposit),
 * so the skip inside the lane walk is a defensive guard and this is
 * the only way to exercise it.
 */
contract ForecastHarness is QueueForecastFacet {

    function harnessSeedOrder(
        uint256 _id,
        int256 _incentive,
        uint256 _amount,
        uint256 _headPointer
    )
        external
    {
        QueMemberByIdAndIncentive[_id][_incentive].member = address(0xA1);
        QueMemberByIdAndIncentive[_id][_incentive].amount = _amount;
        QueMemberByIdAndIncentive[_id][_incentive].headPointer = _headPointer;
    }

    function harnessSeedLane(
        int256 _incentive,
        uint256 _cursor,
        uint256 _laneEnd,
        uint256 _activeOrders
    )
        external
    {
        currentOrderIdByIncentive[_incentive] = _cursor;
        earliestValidQueMemberByIncentive[_incentive] = _laneEnd;
        totalActiveOrders = _activeOrders;
    }
}

/**
 * @dev Exercises {QueueForecastFacet}. The load-bearing property is
 * differential: `solveForAmountAfterFulfill(x, y)` quoted BEFORE any
 * fill must equal `solveForAmount(y)` quoted AFTER a real
 * solver-optimal fill of x has executed, including the full-order
 * amounts and the partial take the plain solver does not report.
 * Fuzzed across fill sizes that land on order boundaries, inside
 * orders, across lanes, and beyond the whole book.
 */
contract WiseSovrenNodesQueueForecastFacetTest is DiamondTestHarness {

    address internal seller1 = address(0xA1);
    address internal seller2 = address(0xA2);
    address internal seller3 = address(0xA3);
    address internal filler = address(0xF1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    uint256 internal totalQueued;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireQueueFacets(
            diamond
        );

        diamond.finalizeSetup();

        _seedOrder(seller1, 300 * 1e6, 500);
        _seedOrder(seller2, 200 * 1e6, 500);
        _seedOrder(seller1, 150 * 1e6, 100);
        _seedOrder(seller3, 450 * 1e6, 100);
        _seedOrder(seller2, 120 * 1e6, 0);
        _seedOrder(seller3, 80 * 1e6, 0);

        totalQueued = 1_300 * 1e6;
    }

    function _seedOrder(
        address _seller,
        uint256 _amount,
        int256 _incentive
    )
        internal
    {
        AdminFacet(address(diamond)).mintSupply(
            _seller,
            _amount
        );

        vm.prank(
            _seller
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            _amount,
            _incentive
        );
    }

    function _forecast(
        uint256 _x,
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
        return QueueForecastFacet(address(diamond)).solveForAmountAfterFulfill(
            _x,
            _y
        );
    }

    function _executeRealFill(
        uint256 _x
    )
        internal
    {
        (
            int256[] memory incs,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            _x
        );

        uint256 covered;

        for (uint256 i; i < orders.length; i++) {
            (
                ,
                uint256 amt,
                ,
            ) = diamond.QueMemberByIdAndIncentive(
                orders[i],
                incs[i]
            );

            covered += amt;
        }

        uint256 partialTake = partials.length > 0
            ? _x - covered
            : 0;

        if (orders.length == 0 && partialTake == 0) {
            return;
        }

        usd.mint(
            filler,
            _x
        );

        vm.prank(
            filler
        );

        usd.approve(
            address(diamond),
            _x
        );

        vm.prank(
            filler
        );

        QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incs,
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
        ) = _forecast(
            _x,
            _y
        );

        _executeRealFill(
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

    function test_zeroPrior_equalsPlainSolve()
        public
        view
    {
        (
            int256[] memory fIncs,
            uint256[] memory fOrders,
            ,
            uint256[] memory fPartials,
        ) = _forecast(
            0,
            333 * 1e6
        );

        (
            int256[] memory pIncs,
            uint256[] memory pOrders,
            uint256[] memory pPartials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            333 * 1e6
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

    function test_priorStopsInsideOrder_secondContinuesThere()
        public
    {
        _assertForecastMatchesReality(
            250 * 1e6,
            400 * 1e6
        );
    }

    function test_priorEndsOnExactBoundary()
        public
    {
        _assertForecastMatchesReality(
            300 * 1e6,
            200 * 1e6
        );
    }

    function test_priorSpansLanes()
        public
    {
        _assertForecastMatchesReality(
            550 * 1e6,
            300 * 1e6
        );
    }

    function test_priorExceedsWholeBook()
        public
    {
        (
            ,
            uint256[] memory fOrders,
            ,
            uint256[] memory fPartials,
            uint256 fPartialAmount
        ) = _forecast(
            totalQueued + 1,
            100 * 1e6
        );

        assertEq(
            fOrders.length,
            0
        );

        assertEq(
            fPartials.length,
            0
        );

        assertEq(
            fPartialAmount,
            0
        );
    }

    function test_secondExceedsRemainder()
        public
    {
        _assertForecastMatchesReality(
            1_000 * 1e6,
            totalQueued
        );
    }

    function test_emptyQueue_returnsEmpty()
        public
    {
        _executeRealFill(
            totalQueued
        );

        (
            int256[] memory fIncs,
            uint256[] memory fOrders,
            ,
            uint256[] memory fPartials,
            uint256 fPartialAmount
        ) = _forecast(
            5 * 1e6,
            5 * 1e6
        );

        assertEq(
            fIncs.length,
            0
        );

        assertEq(
            fOrders.length,
            0
        );

        assertEq(
            fPartials.length,
            0
        );

        assertEq(
            fPartialAmount,
            0
        );
    }

    function testFuzz_forecastMatchesReality(
        uint256 _x,
        uint256 _y
    )
        public
    {
        _x = bound(
            _x,
            0,
            totalQueued + 50 * 1e6
        );

        _y = bound(
            _y,
            1,
            totalQueued + 50 * 1e6
        );

        _assertForecastMatchesReality(
            _x,
            _y
        );
    }

    function test_forecastLane_zeroAmountOrder_isSkipped()
        public
    {
        ForecastHarness harness = new ForecastHarness();

        harness.harnessSeedOrder(
            0,
            0,
            0,
            1
        );

        harness.harnessSeedOrder(
            1,
            0,
            100 * 1e6,
            2
        );

        harness.harnessSeedLane(
            0,
            0,
            2,
            1
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory orderAmounts,
            ,
        ) = harness.solveForAmountAfterFulfill(
            0,
            100 * 1e6
        );

        assertEq(incentives.length, 1);
        assertEq(orders.length, 1);
        assertEq(orders[0], 1);
        assertEq(orderAmounts[0], 100 * 1e6);
    }
}
