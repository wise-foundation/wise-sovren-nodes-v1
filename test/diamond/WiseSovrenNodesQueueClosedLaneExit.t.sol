// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {TestUSD} from "./utils/mocks/TestUSD.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";

/**
 * @dev Pins that closing a lane with `setIncentivesAllowed` never traps the escrow of the
 * orders already standing in it: `leaveQue` and `reduceQueAmount` keep working on a closed
 * lane and return the escrow in full, while `joinQue` on that lane stays refused. The exit
 * of a queue member is unconditional by design (the same rule the pause and the deposit
 * gate follow); the lane switch only closes the entrance.
 */
contract WiseSovrenNodesQueueClosedLaneExitTest is DiamondTestHarness {

    int256 internal constant PREMIUM = -2_000;

    address internal member1 = address(0xA1);

    address internal member2 = address(0xA2);

    WiseSovrenNodesDiamond internal diamond;

    TestUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new TestUSD(
            "Test USD",
            "TUSD",
            6
        );

        diamond = _deployDiamondWithQueueAtRate(
            address(usd),
            0
        );

        AdminFacet(address(diamond)).mintSupply(
            member1,
            10_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            member2,
            10_000 * 1e6
        );
    }

    function _join(
        address _user,
        uint256 _amount
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
            PREMIUM
        );
    }

    function _closeLane()
        internal
    {
        int256[] memory lanes = new int256[](1);
        lanes[0] = PREMIUM;

        QueueAdminFacet(address(diamond)).setIncentivesAllowed(
            lanes,
            false
        );
    }

    function test_leaveQue_onClosedLane_returnsFullEscrow()
        public
    {
        uint256 id = _join(
            member1,
            300 * 1e6
        );

        _closeLane();

        uint256 before = diamond.balanceOf(member1);

        vm.prank(member1);
        (
            ,
            uint256 returned
        ) = QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            PREMIUM
        );

        assertEq(returned, 300 * 1e6);
        assertEq(diamond.balanceOf(member1) - before, 300 * 1e6);
    }

    function test_reduceQueAmount_onClosedLane_returnsReducedEscrow()
        public
    {
        uint256 id = _join(
            member2,
            500 * 1e6
        );

        _closeLane();

        uint256 before = diamond.balanceOf(member2);

        vm.prank(member2);
        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            id,
            PREMIUM,
            200 * 1e6
        );

        assertEq(diamond.balanceOf(member2) - before, 200 * 1e6);
    }

    function test_switchQueIncentive_outOfClosedLane_succeeds()
        public
    {
        uint256 id = _join(
            member1,
            300 * 1e6
        );

        _closeLane();

        vm.prank(member1);
        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            id,
            PREMIUM,
            500
        );
    }

    function test_switchQueIncentive_intoClosedLane_reverts()
        public
    {
        vm.prank(member1);
        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            300 * 1e6,
            500
        );

        _closeLane();

        vm.prank(member1);
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );
        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            id,
            500,
            PREMIUM
        );
    }

    function test_joinQue_onClosedLane_reverts()
        public
    {
        _closeLane();

        vm.prank(member1);
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            300 * 1e6,
            PREMIUM
        );
    }
}
