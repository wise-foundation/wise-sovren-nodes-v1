// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";

/**
 * @dev Underlying whose transfers can be blocked per address, the way
 * a real regulated stablecoin blocks a sanctioned holder. Used to
 * jam a queue lane: a blocked member cannot be paid, so nobody can
 * fulfil past them.
 */
contract MockUSDBlocklist is ERC20 {

    mapping(address => bool) public blocked;

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

    function setBlocked(
        address _who,
        bool _isBlocked
    )
        external
    {
        blocked[_who] = _isBlocked;
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256
    )
        internal
        view
        override
    {
        require(
            blocked[_from] == false
                && blocked[_to] == false,
            "USD: blocked"
        );
    }
}

/**
 * @dev Exit liveness for queued positions. Joining is gated and
 * fulfilment can be jammed by circumstances outside the vault, so
 * the property that makes the queue safe to enter is that leaving
 * never depends on either.
 *
 * Two laws are pinned. A member can always withdraw their escrow in
 * one transaction, whatever the deposit gates, the minimum deposit
 * or the negative-incentive policy say, because none of those gate
 * the exit paths. And a lane that cannot be fulfilled still lets
 * every member out, including the member causing the jam: paying a
 * blocked leaver fails, but returning escrow to any member moves
 * shares from the vault rather than to the blocked address, so the
 * queue can never trap the people behind a stuck head.
 */
contract WiseSovrenNodesExitLivenessTest is DiamondTestHarness {

    int256 internal constant PREMIUM = -2_000;

    address internal member1 = address(0xA1);
    address internal member2 = address(0xA2);
    address internal member3 = address(0xA3);
    address internal buyer = address(0xF1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSDBlocklist internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSDBlocklist();

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

        AdminFacet(address(diamond)).mintSupply(
            member3,
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

    function _assertExitsWithFullEscrow(
        address _member,
        uint256 _id,
        uint256 _amount
    )
        internal
    {
        uint256 before = diamond.balanceOf(_member);

        vm.prank(_member);
        (
            ,
            uint256 returned
        ) = QueueJoinLeaveFacet(address(diamond)).leaveQue(
            _id,
            PREMIUM
        );

        assertEq(returned, _amount);
        assertEq(diamond.balanceOf(_member) - before, _amount);
    }

    // ---- exit is unconditional ----

    function test_leaveQue_whenPausedAndDepositsDisabled_succeeds()
        public
    {
        uint256 id = _join(
            member1,
            300 * 1e6,
            PREMIUM
        );

        AdminFacet(address(diamond)).pauseDeposits();
        AdminFacet(address(diamond)).setDepositsDisabled(true);

        _assertExitsWithFullEscrow(
            member1,
            id,
            300 * 1e6
        );
    }

    function test_leaveQue_afterMinDepositRaisedAboveOrder_succeeds()
        public
    {
        uint256 id = _join(
            member1,
            100 * 1e6,
            PREMIUM
        );

        QueueAdminFacet(address(diamond)).changeMinDepositAmount(
            5_000 * 1e6
        );

        _assertExitsWithFullEscrow(
            member1,
            id,
            100 * 1e6
        );
    }

    function test_leaveQue_afterNegativeIncentivesDisallowed_succeeds()
        public
    {
        uint256 id = _join(
            member1,
            100 * 1e6,
            PREMIUM
        );

        QueueAdminFacet(address(diamond)).setNegativeIncentivesNotAllowed(
            true
        );

        _assertExitsWithFullEscrow(
            member1,
            id,
            100 * 1e6
        );
    }

    function test_reduceQueAmount_whenPaused_succeeds()
        public
    {
        uint256 id = _join(
            member1,
            300 * 1e6,
            PREMIUM
        );

        AdminFacet(address(diamond)).pauseDeposits();

        uint256 before = diamond.balanceOf(member1);

        vm.prank(member1);
        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            id,
            PREMIUM,
            100 * 1e6
        );

        assertEq(diamond.balanceOf(member1) - before, 100 * 1e6);
    }

    // ---- exit survives a jammed lane ----

    function test_fulfillOrder_blockedHeadMember_reverts()
        public
    {
        _join(
            member1,
            300 * 1e6,
            PREMIUM
        );

        usd.setBlocked(
            member1,
            true
        );

        vm.expectRevert();

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrder(
            0,
            PREMIUM
        );
    }

    function test_leaveQue_blockedHeadJamsLane_everyoneStillExits()
        public
    {
        uint256 id1 = _join(member1, 300 * 1e6, PREMIUM);
        uint256 id2 = _join(member2, 200 * 1e6, PREMIUM);
        uint256 id3 = _join(member3, 100 * 1e6, PREMIUM);

        usd.setBlocked(
            member1,
            true
        );

        vm.expectRevert();

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrder(
            id1,
            PREMIUM
        );

        _assertExitsWithFullEscrow(
            member2,
            id2,
            200 * 1e6
        );

        _assertExitsWithFullEscrow(
            member3,
            id3,
            100 * 1e6
        );

        uint256 before = diamond.balanceOf(member1);

        vm.prank(member1);
        (
            ,
            uint256 returned
        ) = QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id1,
            PREMIUM
        );

        assertEq(returned, 300 * 1e6);
        assertEq(diamond.balanceOf(member1) - before, 300 * 1e6);
        assertEq(diamond.totalActiveOrders(), 0);
    }

    function test_fulfillOrderBulk_blockedHead_revertsWholeBatch()
        public
    {
        _join(member1, 300 * 1e6, PREMIUM);
        _join(member2, 200 * 1e6, PREMIUM);

        usd.setBlocked(
            member1,
            true
        );

        int256[] memory incentives = new int256[](2);
        incentives[0] = PREMIUM;
        incentives[1] = PREMIUM;

        uint256[] memory orders = new uint256[](2);
        orders[0] = 0;
        orders[1] = 1;

        vm.expectRevert();

        vm.prank(buyer);
        QueueFulfillFacet(address(diamond)).fulfillOrderBulk(
            incentives,
            orders,
            new uint256[](0),
            0,
            0,
            type(uint256).max
        );

        assertEq(diamond.totalActiveOrders(), 2);
    }

    function test_leaveQue_maxPremiumLane_blockedHead_succeeds()
        public
    {
        vm.prank(member1);
        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            100 * 1e6,
            -490_000
        );

        usd.setBlocked(
            member1,
            true
        );

        uint256 before = diamond.balanceOf(member1);

        vm.prank(member1);
        (
            ,
            uint256 returned
        ) = QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            -490_000
        );

        assertEq(returned, 100 * 1e6);
        assertEq(diamond.balanceOf(member1) - before, 100 * 1e6);
    }

    function testFuzz_leaveQue_alwaysReturnsFullEscrow(
        uint256 _amount,
        bool _paused,
        bool _disabled,
        bool _blocked
    )
        public
    {
        uint256 amount = bound(
            _amount,
            50 * 1e6,
            5_000 * 1e6
        );

        uint256 id = _join(
            member1,
            amount,
            PREMIUM
        );

        if (_paused == true) {
            AdminFacet(address(diamond)).pauseDeposits();
        }

        if (_disabled == true) {
            AdminFacet(address(diamond)).setDepositsDisabled(true);
        }

        if (_blocked == true) {
            usd.setBlocked(
                member1,
                true
            );
        }

        _assertExitsWithFullEscrow(
            member1,
            id,
            amount
        );
    }
}
