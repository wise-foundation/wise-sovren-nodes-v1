// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

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
 * @dev Unit coverage for `switchQueIncentive` / `switchQueIncentivePartial`
 * — the fused "move an order to another incentive queue without the
 * leave-then-rejoin token round-trip" surface. Storage-equivalence vs the
 * two-call baselines lives in the sibling equivalence suite.
 */
contract WiseSovrenNodesSwitchQueIncentiveFacetTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond vault;

    address user1 = address(0xA1);
    address user2 = address(0xA2);

    uint256 constant MIN_DEPOSIT = 50 * 1e6;

    event SwitchQueIncentive(
        address indexed member,
        uint256 fromId,
        int256 fromIncentive,
        uint256 toId,
        int256 toIncentive,
        uint256 amount
    );

    event SwitchQueIncentivePartial(
        address indexed member,
        uint256 fromId,
        int256 fromIncentive,
        uint256 toId,
        int256 toIncentive,
        uint256 amount
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        vault = _deployDiamondWithQueue(
            address(usd)
        );

        AdminFacet(address(vault)).mintSupply(
            user1,
            1_000_000 * 1e6
        );

        AdminFacet(address(vault)).mintSupply(
            user2,
            1_000_000 * 1e6
        );
    }

    // ---- helpers ----

    function _join(
        address _user,
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (uint256 id)
    {
        vm.prank(
            _user
        );

        (
            ,
            id
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            _amount,
            _incentive
        );
    }

    function _switch(
        address _user,
        uint256 _id,
        int256 _old,
        int256 _new
    )
        internal
        returns (uint256 newId)
    {
        vm.prank(
            _user
        );

        (
            ,
            newId
        ) = QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            _id,
            _old,
            _new
        );
    }

    function _order(
        uint256 _id,
        int256 _incentive
    )
        internal
        view
        returns (
            address member,
            uint256 amount,
            uint256 tailPointer,
            uint256 headPointer
        )
    {
        return vault.QueMemberByIdAndIncentive(
            _id,
            _incentive
        );
    }

    function _seedSubMinResidualOrder(
        address _owner
    )
        internal
        returns (uint256 id)
    {
        id = _join(
            _owner,
            100 * 1e6,
            0
        );

        address fulfiller = address(0xF1);

        usd.mint(
            fulfiller,
            1_000_000 * 1e6
        );

        vm.prank(
            fulfiller
        );

        usd.approve(
            address(vault),
            type(uint256).max
        );

        vm.prank(
            fulfiller
        );

        QueueFulfillFacet(address(vault)).partiallyFulfillOrder(
            id,
            0,
            60 * 1e6
        );
    }

    // ---- happy paths: full switch ----

    function test_switchQueIncentive_soleOrderInQueue_emptiesSource()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 newId = _switch(
            user1,
            id,
            0,
            100
        );

        assertEq(
            newId,
            0,
            "new id lands at dest tail"
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = _order(
            newId,
            100
        );

        assertEq(
            m,
            user1
        );

        assertEq(
            a,
            100 * 1e6
        );

        assertEq(
            t,
            0
        );

        assertEq(
            h,
            1
        );

        (
            address m0,
            uint256 a0,
            uint256 t0,
            uint256 h0
        ) = _order(
            id,
            0
        );

        assertEq(
            m0,
            address(0),
            "source slot cleared"
        );

        assertEq(
            a0,
            0
        );

        assertEq(
            t0,
            0
        );

        assertEq(
            h0,
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );

        assertEq(
            vault.totalActiveOrders(),
            1
        );

        assertEq(
            vault.currentOrderIdByIncentive(0),
            1,
            "source cursor advanced past hole"
        );

        assertEq(
            vault.earliestValidQueMemberByIncentive(100),
            1
        );
    }

    function test_switchQueIncentive_headOrder_advancesSourceCursor()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _switch(
            user1,
            id0,
            0,
            100
        );

        assertEq(
            vault.currentOrderIdByIncentive(0),
            1,
            "cursor advanced to next order"
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            2
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );

        assertEq(
            vault.totalActiveOrders(),
            3
        );
    }

    function test_switchQueIncentive_middleOrder_patchesNeighborPointers()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 idMid = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _switch(
            user1,
            idMid,
            0,
            100
        );

        (
            ,
            ,
            ,
            uint256 h0
        ) = _order(
            0,
            0
        );

        assertEq(
            h0,
            2,
            "prev neighbor headPointer bridges the hole"
        );

        (
            ,
            ,
            uint256 t2,
        ) = _order(
            2,
            0
        );

        assertEq(
            t2,
            0,
            "next neighbor tailPointer bridges the hole"
        );

        (
            address mMid,
            ,
            ,
        ) = _order(
            idMid,
            0
        );

        assertEq(
            mMid,
            address(0),
            "middle slot cleared"
        );

        assertEq(
            vault.currentOrderIdByIncentive(0),
            0,
            "head cursor unchanged for a middle move"
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            2
        );
    }

    function test_switchQueIncentive_tailOrder_movesCleanly()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 idTail = _join(
            user1,
            100 * 1e6,
            0
        );

        _switch(
            user1,
            idTail,
            0,
            100
        );

        (
            address mt,
            ,
            ,
        ) = _order(
            idTail,
            0
        );

        assertEq(
            mt,
            address(0),
            "tail slot cleared"
        );

        (
            ,
            ,
            ,
            uint256 h1
        ) = _order(
            1,
            0
        );

        assertEq(
            h1,
            3,
            "prev neighbor headPointer now points to end sentinel"
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            2
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );
    }

    function test_switchQueIncentive_destinationNonEmpty_appendsAtTail()
        public
    {
        _join(
            user2,
            100 * 1e6,
            100
        );

        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 newId = _switch(
            user1,
            id,
            0,
            100
        );

        assertEq(
            newId,
            1,
            "appended after the pre-existing dest order"
        );

        (
            ,
            ,
            ,
            uint256 hPrev
        ) = _order(
            0,
            100
        );

        assertEq(
            hPrev,
            1,
            "previous dest tail links to the new order"
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = _order(
            newId,
            100
        );

        assertEq(
            m,
            user1
        );

        assertEq(
            a,
            100 * 1e6
        );

        assertEq(
            t,
            0
        );

        assertEq(
            h,
            2
        );

        assertEq(
            vault.currentOrderIdByIncentive(100),
            0,
            "dest cursor unaffected by append"
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            2
        );
    }

    function test_switchQueIncentive_destinationEmpty_initializesQueue()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 newId = _switch(
            user1,
            id,
            0,
            100
        );

        assertEq(
            newId,
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );

        assertEq(
            vault.currentOrderIdByIncentive(100),
            0
        );
    }

    function test_switchQueIncentive_positiveToNegative_whenFlagOff()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        _switch(
            user1,
            id,
            0,
            -2_000
        );

        assertEq(
            vault.activeOrderCountByIncentive(-2_000),
            1
        );

        (
            address m,
            uint256 a,
            ,
        ) = _order(
            0,
            -2_000
        );

        assertEq(
            m,
            user1
        );

        assertEq(
            a,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_negativeToPositive_whenFlagOn()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            -2_000
        );

        QueueAdminFacet(address(vault)).setNegativeIncentivesNotAllowed(
            true
        );

        _switch(
            user1,
            id,
            -2_000,
            100
        );

        assertEq(
            vault.activeOrderCountByIncentive(-2_000),
            0,
            "left the negative tier"
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1,
            "landed in the positive tier"
        );
    }

    function test_switchQueIncentive_countersConserved()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            500
        );

        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 totalBefore = vault.totalActiveOrders();

        _switch(
            user1,
            id,
            0,
            500
        );

        assertEq(
            vault.totalActiveOrders(),
            totalBefore,
            "total conserved by a move"
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            1
        );

        assertEq(
            vault.activeOrderCountByIncentive(500),
            2
        );
    }

    function test_switchQueIncentive_noTokenOrUsdMovement()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 userShares = vault.balanceOf(
            user1
        );

        uint256 vaultShares = vault.balanceOf(
            address(vault)
        );

        uint256 supply = vault.totalSupply();

        uint256 userUsd = usd.balanceOf(
            user1
        );

        uint256 vaultUsd = usd.balanceOf(
            address(vault)
        );

        uint256 tpUsd = usd.balanceOf(
            thirdPty
        );

        uint256 proxyBal = vault.proxyBalance(
            user1
        );

        _switch(
            user1,
            id,
            0,
            100
        );

        assertEq(
            vault.balanceOf(user1),
            userShares,
            "user shares unchanged"
        );

        assertEq(
            vault.balanceOf(address(vault)),
            vaultShares,
            "escrowed shares unchanged"
        );

        assertEq(
            vault.totalSupply(),
            supply,
            "supply unchanged"
        );

        assertEq(
            usd.balanceOf(user1),
            userUsd,
            "no USD to user"
        );

        assertEq(
            usd.balanceOf(address(vault)),
            vaultUsd,
            "no USD from vault"
        );

        assertEq(
            usd.balanceOf(thirdPty),
            tpUsd,
            "no USD to third party"
        );

        assertEq(
            vault.proxyBalance(user1),
            proxyBal,
            "proxy balance conserved"
        );
    }

    // ---- happy paths: partial switch ----

    function test_switchQueIncentivePartial_leavesRemainderMovesPart()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            200 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 newId
        ) = QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            80 * 1e6
        );

        (
            ,
            uint256 remaining,
            ,
        ) = _order(
            id,
            0
        );

        assertEq(
            remaining,
            120 * 1e6,
            "remainder stays in source order"
        );

        (
            address m,
            uint256 moved,
            ,
        ) = _order(
            newId,
            100
        );

        assertEq(
            m,
            user1
        );

        assertEq(
            moved,
            80 * 1e6,
            "moved part lands in dest"
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            1,
            "source order not removed"
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );

        assertEq(
            vault.totalActiveOrders(),
            2,
            "partial adds one order"
        );
    }

    function test_switchQueIncentivePartial_multipleSequential()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            300 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            100 * 1e6
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            100 * 1e6
        );

        (
            ,
            uint256 remaining,
            ,
        ) = _order(
            id,
            0
        );

        assertEq(
            remaining,
            100 * 1e6,
            "two peels leave a third"
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            2,
            "two new dest orders"
        );

        assertEq(
            vault.totalActiveOrders(),
            3
        );
    }

    // ---- reverts ----

    function test_switchQueIncentive_sameIncentive_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SameIncentive.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            0
        );
    }

    function test_switchQueIncentive_negativeDestinationWhenDisallowed_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        QueueAdminFacet(address(vault)).setNegativeIncentivesNotAllowed(
            true
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NegativeIncentiveNotAllowed.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            -2_000
        );
    }

    function test_switchQueIncentivePartial_sameIncentive_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SameIncentive.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            0,
            50 * 1e6
        );
    }

    function test_switchQueIncentivePartial_negativeDestinationWhenDisallowed_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        QueueAdminFacet(address(vault)).setNegativeIncentivesNotAllowed(
            true
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NegativeIncentiveNotAllowed.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            -2_000,
            50 * 1e6
        );
    }

    function test_switchQueIncentivePartial_negativeDisallowed_nonNegativeSucceeds()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        QueueAdminFacet(address(vault)).setNegativeIncentivesNotAllowed(
            true
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            50 * 1e6
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );
    }

    function test_switchQueIncentive_invalidMemberId_reverts()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.QueMemberIdTooHigh.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            99,
            0,
            100
        );
    }

    function test_switchQueIncentive_newIncentiveNotAllowed_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.IncentiveNotAllowed.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            1234
        );
    }

    function test_switchQueIncentive_notOrderOwner_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotMember.selector
        );

        vm.prank(
            user2
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );
    }

    function test_switchQueIncentive_amountBelowRaisedMinDeposit_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        QueueAdminFacet(address(vault)).changeMinDepositAmount(
            200 * 1e6
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooLow.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );
    }

    function test_switchQueIncentivePartial_zeroAmount_reverts()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ZeroAmount.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            0
        );
    }

    function test_switchQueIncentivePartial_amountTooHigh_reverts()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooHigh.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            200 * 1e6
        );
    }

    function test_switchQueIncentivePartial_movedBelowMinDeposit_reverts()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooLow.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            40 * 1e6
        );
    }

    function test_switchQueIncentivePartial_remainderBelowMinDeposit_reverts()
        public
    {
        uint256 id = _join(
            user1,
            90 * 1e6,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooLow.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            50 * 1e6
        );
    }

    // ---- partial-fulfill sub-minimum residual cannot be moved, only exited ----

    function test_switchQueIncentive_belowMinResidualAfterPartialFulfill_reverts()
        public
    {
        uint256 id = _seedSubMinResidualOrder(
            user1
        );

        (
            ,
            uint256 residual,
            ,
        ) = _order(
            id,
            0
        );

        assertEq(
            residual,
            40 * 1e6,
            "partial fulfill left a sub-minimum residual"
        );

        assertLt(
            residual,
            MIN_DEPOSIT
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooLow.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );
    }

    function test_switchQueIncentivePartial_belowMinResidualAfterPartialFulfill_reverts()
        public
    {
        uint256 id = _seedSubMinResidualOrder(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AmountTooLow.selector
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            30 * 1e6
        );
    }

    function test_leaveQue_belowMinResidual_stillExits()
        public
    {
        uint256 id = _seedSubMinResidualOrder(
            user1
        );

        uint256 sharesBefore = vault.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).leaveQue(
            id,
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            0,
            "sub-minimum residual is never trapped"
        );

        assertEq(
            vault.balanceOf(user1),
            sharesBefore + 40 * 1e6,
            "residual shares returned to owner"
        );
    }

    // ---- events ----

    function test_switchQueIncentive_emitsSwitchQueIncentive()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vault)
        );

        emit SwitchQueIncentive(
            user1,
            id,
            0,
            0,
            100,
            100 * 1e6
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );
    }

    function test_switchQueIncentivePartial_emitsSwitchQueIncentivePartial()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            200 * 1e6,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vault)
        );

        emit SwitchQueIncentivePartial(
            user1,
            id,
            0,
            0,
            100,
            80 * 1e6
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            80 * 1e6
        );
    }

    // ---- onlyDelegateCall ----

    function test_switchQueIncentive_directCallOnFacet_reverts()
        public
    {
        QueueJoinLeaveFacet facet = new QueueJoinLeaveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.switchQueIncentive(
            0,
            0,
            100
        );
    }

    function test_switchQueIncentivePartial_directCallOnFacet_reverts()
        public
    {
        QueueJoinLeaveFacet facet = new QueueJoinLeaveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.switchQueIncentivePartial(
            0,
            0,
            100,
            1
        );
    }

    // ---- pause: entry gated, exits stay open ----

    function test_switchQueIncentive_whenPaused_reverts()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        AdminFacet(address(vault)).pauseDeposits();

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );
    }

    function test_switchQueIncentivePartial_whenPaused_reverts()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            200 * 1e6,
            0
        );

        AdminFacet(address(vault)).pauseDeposits();

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            id,
            0,
            100,
            80 * 1e6
        );
    }

    function test_joinQue_whenPaused_reverts()
        public
    {
        AdminFacet(address(vault)).pauseDeposits();

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).joinQue(
            100 * 1e6,
            0
        );
    }

    function test_leaveQue_whenPaused_stillSucceeds()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        AdminFacet(address(vault)).pauseDeposits();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).leaveQue(
            id,
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            0,
            "user can always exit while paused"
        );
    }

    function test_reduceQueAmount_whenPaused_stillSucceeds()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        AdminFacet(address(vault)).pauseDeposits();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).reduceQueAmount(
            id,
            0,
            50 * 1e6
        );

        (
            ,
            uint256 remaining,
            ,
        ) = _order(
            id,
            0
        );

        assertEq(
            remaining,
            150 * 1e6,
            "user can always reduce while paused"
        );
    }

    // ---- multicall composition ----

    function test_multicall_batchesTwoSwitches()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            200
        );

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            QueueJoinLeaveFacet.switchQueIncentive.selector,
            id0,
            int256(0),
            int256(100)
        );

        calls[1] = abi.encodeWithSelector(
            QueueJoinLeaveFacet.switchQueIncentive.selector,
            id1,
            int256(200),
            int256(500)
        );

        vm.prank(
            user1
        );

        MulticallFacet(address(vault)).multicall(
            calls
        );

        assertEq(
            vault.activeOrderCountByIncentive(0),
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(200),
            0
        );

        assertEq(
            vault.activeOrderCountByIncentive(100),
            1
        );

        assertEq(
            vault.activeOrderCountByIncentive(500),
            1
        );
    }
}
