// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesQueueStructs} from "../../../src/diamond/vault/WiseSovrenNodesQueueStructs.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueViewFacet} from "../../../src/diamond/vault/facets/QueueViewFacet.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";
import {QueueInvariantHandler, MockUSD} from "./QueueConservationInvariant.t.sol";

/**
 * @dev Stateful-fuzz invariant for the additive memberId views. Reuses the
 * queue conservation handler (bounded random join / leave / reduce / fulfill /
 * switch across the 17 tiers). After any action sequence, every order returned
 * by `getAllOrdersOverallWithId` must round-trip to
 * `QueMemberByIdAndIncentive[memberId][incentive]` and match the id-less
 * `getAllOrdersOverall` position for position.
 */
contract OrdersWithIdInvariantTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;
    QueueInvariantHandler handler;

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

        handler = new QueueInvariantHandler(
            diamond,
            usd,
            actors
        );

        targetContract(
            address(handler)
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_memberIdRoundTrips()
        public
        view
    {
        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(diamond)).getAllOrdersOverallWithId();

        for (uint256 i = 0; i < withId.length; i++) {
            (
                address sMember,
                uint256 sAmount,
                uint256 sTail,
                uint256 sHead
            ) = diamond.QueMemberByIdAndIncentive(
                withId[i].memberId,
                withId[i].incentive
            );

            assertEq(
                withId[i].member,
                sMember,
                "member roundtrip"
            );

            assertEq(
                withId[i].amount,
                sAmount,
                "amount roundtrip"
            );

            assertEq(
                withId[i].tailPointer,
                sTail,
                "tail roundtrip"
            );

            assertEq(
                withId[i].headPointer,
                sHead,
                "head roundtrip"
            );

            assertGt(
                withId[i].amount,
                0,
                "active only"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_withIdMatchesPlain()
        public
        view
    {
        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(diamond)).getAllOrdersOverallWithId();

        (
            WiseSovrenNodesQueueStructs.QueMember[] memory plain,
            int256[] memory incs
        ) = QueueViewFacet(address(diamond)).getAllOrdersOverall();

        assertEq(
            withId.length,
            plain.length,
            "length mismatch vs plain"
        );

        for (uint256 i = 0; i < withId.length; i++) {
            assertEq(
                withId[i].member,
                plain[i].member,
                "member vs plain"
            );

            assertEq(
                withId[i].amount,
                plain[i].amount,
                "amount vs plain"
            );

            assertEq(
                withId[i].tailPointer,
                plain[i].tailPointer,
                "tail vs plain"
            );

            assertEq(
                withId[i].headPointer,
                plain[i].headPointer,
                "head vs plain"
            );

            assertEq(
                withId[i].incentive,
                incs[i],
                "incentive vs plain"
            );
        }
    }
}
