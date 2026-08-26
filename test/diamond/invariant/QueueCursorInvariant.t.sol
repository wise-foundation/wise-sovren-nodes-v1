// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";
import {QueueInvariantHandler, MockUSD} from "./QueueConservationInvariant.t.sol";

/**
 * @dev Extends the conservation handler with actions that target
 * ARBITRARY member ids - not just the lane head - so mid-list
 * removals, below-cursor attempts and partial fulfillments are all
 * exercised. This is exactly the traffic that would desync the
 * cursor from the lowest live order if the pointer splicing in
 * `_finalizeMemberRemoval` or the cursor advance in
 * `_updateCurrentOrderIfNeeded` were wrong.
 */
contract QueueCursorHandler is QueueInvariantHandler {

    constructor(
        WiseSovrenNodesDiamond _diamond,
        MockUSD _usd,
        address[3] memory _actors
    )
        QueueInvariantHandler(
            _diamond,
            _usd,
            _actors
        )
    {}

    function leaveAnyQue(
        uint256 _actorSeed,
        uint256 _tierSeed,
        uint256 _idSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 earliest = diamond.earliestValidQueMemberByIncentive(incentive);

        if (earliest == 0) {
            return;
        }

        uint256 id = _idSeed % earliest;

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).leaveQue(id, incentive) {} catch {}
    }

    function reduceAnyQue(
        uint256 _actorSeed,
        uint256 _tierSeed,
        uint256 _idSeed,
        uint256 _reduceSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 earliest = diamond.earliestValidQueMemberByIncentive(incentive);

        if (earliest == 0) {
            return;
        }

        uint256 id = _idSeed % earliest;

        uint256 reduceBy = bound(
            _reduceSeed,
            1,
            1_000_000 * 1e6
        );

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(id, incentive, reduceBy) {} catch {}
    }

    function switchAnyQue(
        uint256 _actorSeed,
        uint256 _tierSeedA,
        uint256 _tierSeedB,
        uint256 _idSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentiveA = _tier(_tierSeedA);
        int256 incentiveB = _tier(_tierSeedB);

        if (incentiveA == incentiveB) {
            return;
        }

        uint256 earliest = diamond.earliestValidQueMemberByIncentive(incentiveA);

        if (earliest == 0) {
            return;
        }

        uint256 id = _idSeed % earliest;

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(id, incentiveA, incentiveB) {} catch {}
    }

    function partialFulfill(
        uint256 _actorSeed,
        uint256 _tierSeed,
        uint256 _amountSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 id = diamond.currentOrderIdByIncentive(incentive);

        uint256 amount = bound(
            _amountSeed,
            1,
            1_000_000 * 1e6
        );

        vm.prank(
            actor
        );

        try QueueFulfillFacet(address(diamond)).partiallyFulfillOrder(id, incentive, amount) {} catch {}
    }
}

/**
 * @title QueueCursorInvariantTest
 * @dev Stateful-fuzz form of QUE-10: for every incentive lane, the
 * fulfillment cursor `currentOrderIdByIncentive` always points at the
 * LOWEST live order id (strict FIFO - the oldest unfulfilled order is
 * always next), and when a lane is empty the cursor is parked exactly
 * at the lane's allocation edge `earliestValidQueMemberByIncentive`.
 * The Kontrol per-operation lemmas in
 * `test/diamond/kontrol/CursorProperties.t.sol` prove the same
 * predicate is preserved by each queue mutation over all amounts.
 */
contract QueueCursorInvariantTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;
    QueueCursorHandler handler;

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

        diamond = _deployDiamondWithQueue(
            address(usd)
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

        handler = new QueueCursorHandler(
            diamond,
            usd,
            actors
        );

        targetContract(
            address(handler)
        );
    }

    function _tiers()
        internal
        pure
        returns (int256[17] memory)
    {
        return [
            int256(0),
            int256(100),
            int256(200),
            int256(300),
            int256(500),
            int256(1000),
            int256(1500),
            int256(2500),
            int256(5000),
            int256(-2_000),
            int256(-4_000),
            int256(-6_000),
            int256(-10_000),
            int256(-20_000),
            int256(-50_000),
            int256(-100_000),
            int256(-490_000)
        ];
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_QUE10_cursorIsLowestActiveId()
        public
        view
    {
        int256[17] memory tiers = _tiers();

        for (uint256 i = 0; i < tiers.length; i++) {
            int256 incentive = tiers[i];

            uint256 earliest = diamond.earliestValidQueMemberByIncentive(incentive);
            uint256 cursor = diamond.currentOrderIdByIncentive(incentive);

            bool found;
            uint256 lowest;

            for (uint256 id = 0; id < earliest; id++) {
                (
                    ,
                    uint256 amount,
                    ,
                ) = diamond.QueMemberByIdAndIncentive(
                    id,
                    incentive
                );

                if (amount > 0) {
                    found = true;
                    lowest = id;
                    break;
                }
            }

            if (found) {
                assertEq(
                    cursor,
                    lowest,
                    "cursor desynced from lowest active order id"
                );
            } else {
                assertEq(
                    cursor,
                    earliest,
                    "empty-lane cursor not parked at allocation edge"
                );
            }
        }
    }
}
