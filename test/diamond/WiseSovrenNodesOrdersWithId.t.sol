// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesQueueStructs} from "../../src/diamond/vault/WiseSovrenNodesQueueStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";

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
 * @dev Unit + fuzz coverage for the additive `getAllOrdersOverallWithId` /
 * `getAllOrdersfromAddressWithId` views. Every returned entry must round-trip
 * to `QueMemberByIdAndIncentive[memberId][incentive]` and match the id-less
 * views position for position, across every order-lifecycle state.
 */
contract WiseSovrenNodesOrdersWithIdTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond vault;

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address filler = address(0xF1);

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
            10_000_000 * 1e6
        );

        AdminFacet(address(vault)).mintSupply(
            user2,
            10_000_000 * 1e6
        );

        AdminFacet(address(vault)).mintSupply(
            user3,
            10_000_000 * 1e6
        );

        usd.mint(
            filler,
            1_000_000_000 * 1e6
        );

        vm.prank(
            filler
        );

        usd.approve(
            address(vault),
            type(uint256).max
        );
    }

    // ---- Helpers ----

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

    function _leave(
        address _user,
        uint256 _id,
        int256 _incentive
    )
        internal
    {
        vm.prank(
            _user
        );

        QueueJoinLeaveFacet(address(vault)).leaveQue(
            _id,
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

    function _partialFulfill(
        uint256 _id,
        int256 _incentive,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            filler
        );

        QueueFulfillFacet(address(vault)).partiallyFulfillOrder(
            _id,
            _incentive,
            _amount
        );
    }

    function _fulfill(
        uint256 _id,
        int256 _incentive
    )
        internal
    {
        vm.prank(
            filler
        );

        QueueFulfillFacet(address(vault)).fulfillOrder(
            _id,
            _incentive
        );
    }

    function _tier(
        uint256 _seed
    )
        internal
        pure
        returns (int256)
    {
        int256[17] memory tiers = [
            int256(0),
            int256(100),
            int256(200),
            int256(300),
            int256(500),
            int256(1000),
            int256(1500),
            int256(2500),
            int256(5000),
            int256(-100),
            int256(-200),
            int256(-300),
            int256(-500),
            int256(-1000),
            int256(-1500),
            int256(-2500),
            int256(-5000)
        ];

        return tiers[_seed % 17];
    }

    function _views(
        address _user,
        bool _fromAddress
    )
        internal
        view
        returns (
            WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId,
            WiseSovrenNodesQueueStructs.QueMember[] memory plain,
            int256[] memory incs
        )
    {
        if (_fromAddress) {
            withId = QueueViewFacet(address(vault)).getAllOrdersfromAddressWithId(
                _user
            );

            (
                plain,
                incs
            ) = QueueViewFacet(address(vault)).getAllOrdersfromAddress(
                _user
            );
        } else {
            withId = QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

            (
                plain,
                incs
            ) = QueueViewFacet(address(vault)).getAllOrdersOverall();
        }
    }

    function _assertConsistent(
        address _user,
        bool _fromAddress
    )
        internal
        view
    {
        (
            WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId,
            WiseSovrenNodesQueueStructs.QueMember[] memory plain,
            int256[] memory incs
        ) = _views(
            _user,
            _fromAddress
        );

        assertEq(
            withId.length,
            plain.length,
            "withId vs plain length"
        );

        for (uint256 i = 0; i < withId.length; i++) {
            (
                address sMember,
                uint256 sAmount,
                uint256 sTail,
                uint256 sHead
            ) = vault.QueMemberByIdAndIncentive(
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

            if (_fromAddress) {
                assertEq(
                    withId[i].member,
                    _user,
                    "fromAddress filter"
                );
            }

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

    function _assertAll()
        internal
        view
    {
        _assertConsistent(
            address(0),
            false
        );

        _assertConsistent(
            user1,
            true
        );

        _assertConsistent(
            user2,
            true
        );

        _assertConsistent(
            user3,
            true
        );
    }

    // ---- Unit Tests ----

    function test_emptyQueue_returnsEmpty()
        public
        view
    {
        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            0
        );

        _assertConsistent(
            address(0),
            false
        );
    }

    function test_singleOrder_reportsId()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            1
        );

        assertEq(
            withId[0].memberId,
            id
        );

        assertEq(
            withId[0].incentive,
            int256(100)
        );

        assertEq(
            withId[0].member,
            user1
        );

        assertEq(
            withId[0].amount,
            100 * 1e6
        );

        _assertAll();
    }

    function test_multipleOrders_sameIncentive()
        public
    {
        _join(
            user1,
            100 * 1e6,
            100
        );

        _join(
            user2,
            200 * 1e6,
            100
        );

        _join(
            user3,
            300 * 1e6,
            100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            3
        );

        _assertAll();
    }

    function test_multipleIncentives()
        public
    {
        _join(
            user1,
            100 * 1e6,
            100
        );

        _join(
            user2,
            200 * 1e6,
            0
        );

        _join(
            user3,
            300 * 1e6,
            -100
        );

        _assertAll();
    }

    function test_sameAddress_multipleTiers_disambiguatesId()
        public
    {
        _join(
            user1,
            100 * 1e6,
            100
        );

        _join(
            user1,
            150 * 1e6,
            -100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory mine =
            QueueViewFacet(address(vault)).getAllOrdersfromAddressWithId(user1);

        assertEq(
            mine.length,
            2
        );

        assertEq(
            mine[0].member,
            user1
        );

        assertEq(
            mine[1].member,
            user1
        );

        assertTrue(
            mine[0].incentive != mine[1].incentive
        );

        _assertAll();
    }

    function test_afterLeave_excludesRemoved()
        public
    {
        uint256 idA = _join(
            user1,
            100 * 1e6,
            100
        );

        _join(
            user2,
            200 * 1e6,
            100
        );

        _leave(
            user1,
            idA,
            100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            1
        );

        assertEq(
            withId[0].member,
            user2
        );

        _assertAll();
    }

    function test_afterPartialFulfill_idStable_amountReduced()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            100
        );

        _partialFulfill(
            id,
            100,
            50 * 1e6
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            1
        );

        assertEq(
            withId[0].memberId,
            id
        );

        assertEq(
            withId[0].incentive,
            int256(100)
        );

        assertEq(
            withId[0].amount,
            150 * 1e6
        );

        _assertAll();
    }

    function test_afterSwitchIncentive_reportsNewTier()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            100
        );

        uint256 newId = _switch(
            user1,
            id,
            100,
            -100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            1
        );

        assertEq(
            withId[0].memberId,
            newId
        );

        assertEq(
            withId[0].incentive,
            int256(-100)
        );

        assertEq(
            withId[0].member,
            user1
        );

        _assertAll();
    }

    function test_afterFullFulfill_excluded()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            100
        );

        _fulfill(
            id,
            100
        );

        WiseSovrenNodesQueueStructs.QueMemberWithId[] memory withId =
            QueueViewFacet(address(vault)).getAllOrdersOverallWithId();

        assertEq(
            withId.length,
            0
        );

        _assertAll();
    }

    // ---- Fuzz ----

    function testFuzz_roundTripAfterJoins(
        uint256 _tierSeedA,
        uint256 _tierSeedB,
        uint256 _amtA,
        uint256 _amtB
    )
        public
    {
        uint256 amtA = bound(
            _amtA,
            50 * 1e6,
            1_000_000 * 1e6
        );

        uint256 amtB = bound(
            _amtB,
            50 * 1e6,
            1_000_000 * 1e6
        );

        _join(
            user1,
            amtA,
            _tier(_tierSeedA)
        );

        _join(
            user2,
            amtB,
            _tier(_tierSeedB)
        );

        _assertAll();
    }
}
