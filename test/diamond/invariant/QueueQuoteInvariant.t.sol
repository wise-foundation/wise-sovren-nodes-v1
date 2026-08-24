// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../../src/diamond/vault/facets/QueueViewFacet.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";
import {QueueInvariantHandler, MockUSD} from "./QueueConservationInvariant.t.sol";
import {QueueCursorHandler} from "./QueueCursorInvariant.t.sol";

/**
 * @dev Extends the cursor handler with a quote-then-execute action:
 * inside one call it asks `solveForAmount` for a plan, prices it
 * with `predictCostForTokens`, executes the plan verbatim through
 * `fulfillOrderBulk`, and records a ghost violation if the executed
 * cost or token count differs from the quote or if the freshly
 * quoted plan reverts. Nothing can change the book between the
 * quote and the execution inside a single action, so any drift or
 * revert is a real divergence between the view surface and the
 * fulfillment path. The inherited join / leave / reduce / switch /
 * partial-fulfill actions churn a book that mixes discount and
 * premium lanes, so the quotes are exercised across the ladder
 * boundary in every state the fuzzer can reach.
 */
contract QueueQuoteHandler is QueueCursorHandler {

    uint256 public quoteDriftCount;
    uint256 public quoteRevertCount;

    constructor(
        WiseSovrenNodesDiamond _diamond,
        MockUSD _usd,
        address[3] memory _actors
    )
        QueueCursorHandler(
            _diamond,
            _usd,
            _actors
        )
    {}

    function quoteThenFulfill(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
    {
        address actor = _actor(_actorSeed);

        uint256 amount = bound(
            _amountSeed,
            1,
            1_000_000 * 1e6
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = QueueViewFacet(address(diamond)).solveForAmount(
            amount
        );

        if (orders.length == 0 && partials.length == 0) {
            return;
        }

        (
            uint256 cost,
            uint256 acquirable
        ) = QueueViewFacet(address(diamond)).predictCostForTokens(
            amount
        );

        if (usd.balanceOf(actor) < cost) {
            return;
        }

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

        uint256 partialTake = partials.length > 0
            ? amount - covered
            : 0;

        vm.prank(
            actor
        );

        try QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            partialTake,
            0,
            type(uint256).max
        ) returns (
            uint256 received,
            uint256 spent
        ) {
            if (spent != cost || received != acquirable) {
                quoteDriftCount++;
            }
        } catch {
            quoteRevertCount++;
        }
    }
}

/**
 * @title QueueQuoteInvariantTest
 * @dev Stateful-fuzz form of the quote-equals-execution law on a
 * mixed book: every plan `solveForAmount` returns must execute
 * through `fulfillOrderBulk` for exactly the cost and token count
 * `predictCostForTokens` quoted, and a plan quoted in the same
 * transaction must never revert. The unit and fuzz coverage of the
 * same law on a fixed mixed book lives in
 * `WiseSovrenNodesMixedBookQuotes.t.sol`; this suite drives it
 * through arbitrary interleavings of queue traffic instead.
 */
contract QueueQuoteInvariantTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;
    QueueQuoteHandler handler;

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployDiamondWithQueueAtRate(
            address(usd),
            0
        );

        address[3] memory actors = [
            user1,
            user2,
            user3
        ];

        for (uint256 i = 0; i < actors.length; i++) {
            AdminFacet(address(diamond)).mintSupply(
                actors[i],
                10_000_000 * 1e6
            );

            usd.mint(
                actors[i],
                1_000_000_000 * 1e6
            );

            vm.prank(
                actors[i]
            );

            IERC20(address(usd)).approve(
                address(diamond),
                type(uint256).max
            );
        }

        handler = new QueueQuoteHandler(
            diamond,
            usd,
            actors
        );

        targetContract(
            address(handler)
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_LAD5_quoteMatchesExecutionOnMixedBook()
        public
        view
    {
        assertEq(
            handler.quoteDriftCount(),
            0,
            "a quoted plan executed at a different cost or token count"
        );

        assertEq(
            handler.quoteRevertCount(),
            0,
            "a same-transaction quoted plan reverted on execution"
        );
    }
}
