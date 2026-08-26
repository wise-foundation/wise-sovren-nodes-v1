// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";

import {QueueAdminFacet as QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet as QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet as QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";

import {WiseSovrenNodesIncentiveLadder} from "../../src/diamond/vault/WiseSovrenNodesIncentiveLadder.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {WiseSovrenNodesQueueStructs as QueContractDiamondStructs} from "../../src/diamond/vault/WiseSovrenNodesQueueStructs.sol";

import {
    FacetNotFound,
    AlreadyInitialized,
    NoSelectorChangeQueued,
    SelectorTimelockNotElapsed,
    OnlyDelegateCall
} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

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
 * @dev Full line/branch/function coverage suite for the QueContract
 * diamond sources. Mirrors the legacy functional + gaps blueprints
 * (translated to facet casts on the diamond) and the vault
 * selector-routing machinery suite (translated to the queue diamond).
 */
contract QueContractDiamondCoverageTest is Test {

    MockUSD usd;
    WiseSovrenNodesDiamond vault;
    QueueViewFacet que;

    QueueAdminFacet adminFacet;
    QueueJoinLeaveFacet joinLeaveFacet;
    QueueFulfillFacet fulfillFacet;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address nonMaster = address(0xBEEF);

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address user4 = address(0xA4);
    address fulf = address(0xF1);
    address comp = address(0xC0FFEE);

    uint256 constant MIN_DEPOSIT = 50 * 1e6;

    uint256 constant DELAY = 3 days;

    bytes4 constant SEL_FAKE = bytes4(keccak256("doesNotExist()"));

    event JoinQue(
        address indexed member,
        uint256 amount,
        int256 incentive,
        uint256 queMemberId
    );

    event SetupFinalized();

    event SelectorProposed(
        bytes4 indexed selector,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorUpdated(
        bytes4 indexed selector,
        address indexed facet
    );

    event SelectorProposalCancelled(
        bytes4 indexed selector
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        vault = _deployVault();

        que = QueueViewFacet(
            address(vault)
        );

        _fundUserWithVaultTokens(
            user1,
            10_000 * 1e6
        );

        _fundUserWithVaultTokens(
            user2,
            10_000 * 1e6
        );

        _fundUserWithVaultTokens(
            user3,
            10_000 * 1e6
        );

        _fundUserWithVaultTokens(
            user4,
            10_000 * 1e6
        );

        usd.mint(
            fulf,
            1_000_000 * 1e6
        );

        vm.prank(
            fulf
        );

        usd.approve(
            address(que),
            type(uint256).max
        );
    }

    function _deployVault()
        internal
        returns (WiseSovrenNodesDiamond v)
    {
        AdminFacet admin = new AdminFacet();

        ProxyFacet proxy = new ProxyFacet();

        UserFacet user = new UserFacet();

        adminFacet = new QueueAdminFacet();

        joinLeaveFacet = new QueueJoinLeaveFacet();

        fulfillFacet = new QueueFulfillFacet();

        QueueViewFacet viewFacet = new QueueViewFacet();

        v = new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: address(usd),
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 100_000_000 * 1e6,
                interestRate: 2000,
                decimalsValue: 6,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "wsnUSDC"
            })
        );

        bytes4[] memory adminS = WiseSovrenNodesDiamondSelectors.adminSelectors();

        bytes4[] memory proxyS = WiseSovrenNodesDiamondSelectors.proxySelectors();

        bytes4[] memory userS = WiseSovrenNodesDiamondSelectors.userSelectors();

        v.proposeSelectors(
            adminS,
            address(admin)
        );

        v.proposeSelectors(
            proxyS,
            address(proxy)
        );

        v.proposeSelectors(
            userS,
            address(user)
        );

        v.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors(),
            address(adminFacet)
        );

        v.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(joinLeaveFacet)
        );

        v.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors(),
            address(fulfillFacet)
        );

        v.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueViewSelectors(),
            address(viewFacet)
        );

        v.executeSelectorChanges(
            adminS
        );

        v.executeSelectorChanges(
            proxyS
        );

        v.executeSelectorChanges(
            userS
        );

        v.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors()
        );

        v.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        v.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors()
        );

        v.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueViewSelectors()
        );

        QueueAdminFacet(address(v)).setIncentivesAllowed(
            WiseSovrenNodesIncentiveLadder.negativeIncentives(),
            true
        );

        v.finalizeSetup();
    }

    function _fundUserWithVaultTokens(
        address _user,
        uint256 _amount
    )
        internal
    {
        AdminFacet(address(vault)).mintSupply(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        IERC20(address(vault)).approve(
            address(que),
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
        vm.prank(
            _user
        );

        (
            ,
            id
        ) = QueueJoinLeaveFacet(address(que)).joinQue(
            _amount,
            _incentive
        );
    }

    // ---- 1. joinQue / leaveQue / reduceQueAmount ----

    function test_joinQue_happyPath()
        public
    {
        uint256 amount = 100 * 1e6;

        vm.prank(
            user1
        );

        (
            ,
            uint256 newId
        ) = QueueJoinLeaveFacet(address(que)).joinQue(
            amount,
            500
        );

        assertEq(
            newId,
            0
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );

        assertEq(
            que.activeOrderCountByIncentive(500),
            1
        );

        assertEq(
            que.earliestValidQueMemberByIncentive(500),
            1
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(
            0,
            500
        );

        assertEq(
            m,
            user1
        );

        assertEq(
            a,
            amount
        );

        assertEq(
            t,
            0
        );

        assertEq(
            h,
            1
        );

        assertEq(
            IERC20(address(vault)).balanceOf(address(que)),
            amount
        );

        assertEq(
            vault.proxyBalance(user1),
            amount
        );
    }

    function test_joinQue_emitsEvent()
        public
    {
        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit JoinQue(
            user1,
            100 * 1e6,
            500,
            0
        );

        _join(
            user1,
            100 * 1e6,
            500
        );
    }

    function test_joinQue_belowMinDeposit_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).joinQue(
            1,
            500
        );
    }

    function test_joinQue_zeroAmount_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).joinQue(
            0,
            500
        );
    }

    function test_joinQue_disallowedIncentive_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).joinQue(
            MIN_DEPOSIT,
            999
        );
    }

    function test_joinQue_negativeIncentive_blockedByFlag()
        public
    {
        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            true
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).joinQue(
            MIN_DEPOSIT,
            -10_000
        );

        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            false
        );

        _join(
            user1,
            MIN_DEPOSIT,
            -10_000
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_joinQue_negativeIncentivesAllowedFlag_positiveStillWorks()
        public
    {
        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            true
        );

        _join(
            user1,
            MIN_DEPOSIT,
            500
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_joinQue_threeUsers_linkedListIntact()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            200 * 1e6,
            500
        );

        _join(
            user3,
            300 * 1e6,
            500
        );

        assertEq(
            que.totalActiveOrders(),
            3
        );

        assertEq(
            que.activeOrderCountByIncentive(500),
            3
        );

        assertEq(
            que.earliestValidQueMemberByIncentive(500),
            3
        );

        assertEq(
            que.currentOrderIdByIncentive(500),
            0
        );

        (
            address m0,
            ,
            uint256 t0,
            uint256 h0
        ) = que.QueMemberByIdAndIncentive(
            0,
            500
        );

        (
            address m1,
            ,
            uint256 t1,
            uint256 h1
        ) = que.QueMemberByIdAndIncentive(
            1,
            500
        );

        (
            address m2,
            ,
            uint256 t2,
            uint256 h2
        ) = que.QueMemberByIdAndIncentive(
            2,
            500
        );

        assertEq(
            m0,
            user1
        );

        assertEq(
            t0,
            0
        );

        assertEq(
            h0,
            1
        );

        assertEq(
            m1,
            user2
        );

        assertEq(
            t1,
            0
        );

        assertEq(
            h1,
            2
        );

        assertEq(
            m2,
            user3
        );

        assertEq(
            t2,
            1
        );

        assertEq(
            h2,
            3
        );

        (
            ,
            ,
            uint256 sentinelTail,
        ) = que.QueMemberByIdAndIncentive(
            3,
            500
        );

        assertEq(
            sentinelTail,
            2
        );
    }

    function test_leaveQue_happyPath()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            500
        );

        uint256 vaultBalBefore = IERC20(address(vault)).balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id,
            500
        );

        assertEq(
            que.totalActiveOrders(),
            0
        );

        assertEq(
            que.activeOrderCountByIncentive(500),
            0
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(
            id,
            500
        );

        assertEq(
            m,
            address(0)
        );

        assertEq(
            a,
            0
        );

        assertEq(
            t,
            0
        );

        assertEq(
            h,
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            vaultBalBefore + 100 * 1e6
        );

        assertEq(
            vault.proxyBalance(user1),
            0
        );
    }

    function test_leaveQue_notMember_reverts()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        vm.prank(
            user2
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).leaveQue(
            0,
            500
        );
    }

    function test_leaveQue_invalidId_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).leaveQue(
            99,
            500
        );
    }

    function test_leaveQue_middleOfList_patchesPointers()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        uint256 id2 = _join(
            user2,
            200 * 1e6,
            500
        );

        _join(
            user3,
            300 * 1e6,
            500
        );

        vm.prank(
            user2
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id2,
            500
        );

        assertEq(
            que.totalActiveOrders(),
            2
        );

        assertEq(
            que.currentOrderIdByIncentive(500),
            0
        );

        (
            ,
            ,
            ,
            uint256 h0
        ) = que.QueMemberByIdAndIncentive(
            0,
            500
        );

        (
            ,
            ,
            uint256 t2,
        ) = que.QueMemberByIdAndIncentive(
            2,
            500
        );

        assertEq(
            h0,
            2
        );

        assertEq(
            t2,
            0
        );
    }

    function test_reduceQueAmount_happyPath()
        public
    {
        _join(
            user1,
            200 * 1e6,
            500
        );

        uint256 balBefore = IERC20(address(vault)).balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            0,
            500,
            60 * 1e6
        );

        (
            ,
            uint256 a,
            ,
        ) = que.QueMemberByIdAndIncentive(
            0,
            500
        );

        assertEq(
            a,
            140 * 1e6
        );

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            balBefore + 60 * 1e6
        );

        assertEq(
            vault.proxyBalance(user1),
            140 * 1e6
        );
    }

    function test_reduceQueAmount_zeroReduceBy_reverts()
        public
    {
        _join(
            user1,
            200 * 1e6,
            500
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            0,
            500,
            0
        );
    }

    function test_reduceQueAmount_notMember_reverts()
        public
    {
        _join(
            user1,
            200 * 1e6,
            500
        );

        vm.prank(
            user2
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            0,
            500,
            10 * 1e6
        );
    }

    function test_reduceQueAmount_reduceByEqualsAmount_reverts()
        public
    {
        _join(
            user1,
            200 * 1e6,
            500
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            0,
            500,
            200 * 1e6
        );
    }

    function test_reduceQueAmount_belowMinDeposit_reverts()
        public
    {
        _join(
            user1,
            60 * 1e6,
            500
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            0,
            500,
            20 * 1e6
        );
    }

    function test_reduceQueAmount_belowOrEqualMin_reverts()
        public
    {
        uint256 id = _join(
            user1,
            60 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            id,
            0,
            50 * 1e6
        );
    }

    function test_reduceQueAmount_wrongIncentive_reverts()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).reduceQueAmount(
            id,
            500,
            50 * 1e6
        );
    }

    // ---- 2. fulfillOrder / partiallyFulfillOrder / fulfillOrderBulk ----

    function test_fulfillOrder_zeroIncentive_paysFull()
        public
    {
        uint256 amount = 100 * 1e6;

        _join(
            user1,
            amount,
            0
        );

        uint256 user1UsdBefore = usd.balanceOf(
            user1
        );

        uint256 fulfVaultBefore = IERC20(address(vault)).balanceOf(
            fulf
        );

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).fulfillOrder(
            0,
            0
        );

        assertEq(
            vt,
            amount
        );

        assertEq(
            sc,
            amount
        );

        assertEq(
            usd.balanceOf(user1),
            user1UsdBefore + amount
        );

        assertEq(
            IERC20(address(vault)).balanceOf(fulf),
            fulfVaultBefore + amount
        );

        (
            address m,
            uint256 a,
            ,
        ) = que.QueMemberByIdAndIncentive(
            0,
            0
        );

        assertEq(
            m,
            address(0)
        );

        assertEq(
            a,
            0
        );

        assertEq(
            que.totalActiveOrders(),
            0
        );
    }

    function test_fulfillOrder_positiveIncentive_givesDiscount()
        public
    {
        uint256 amount = 100 * 1e6;

        int256 inc = 500;

        _join(
            user1,
            amount,
            inc
        );

        uint256 user1UsdBefore = usd.balanceOf(
            user1
        );

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).fulfillOrder(
            0,
            inc
        );

        uint256 expectedUsd = amount * (10_000 - uint256(inc)) / 10_000;

        assertEq(
            vt,
            amount
        );

        assertEq(
            sc,
            expectedUsd
        );

        assertEq(
            usd.balanceOf(user1) - user1UsdBefore,
            expectedUsd
        );
    }

    function test_fulfillOrder_negativeIncentive_takesPremium()
        public
    {
        uint256 amount = 100 * 1e6;

        int256 inc = -6_000;

        _join(
            user1,
            amount,
            inc
        );

        uint256 user1UsdBefore = usd.balanceOf(
            user1
        );

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).fulfillOrder(
            0,
            inc
        );

        uint256 expectedUsd = amount * (10_000 + 6_000) / 10_000;

        assertEq(
            vt,
            amount
        );

        assertEq(
            sc,
            expectedUsd
        );

        assertEq(
            usd.balanceOf(user1) - user1UsdBefore,
            expectedUsd
        );
    }

    function test_fulfillOrder_notCurrentOrder_reverts()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            100 * 1e6,
            500
        );

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).fulfillOrder(
            1,
            500
        );
    }

    function test_fulfillOrder_invalidId_reverts()
        public
    {
        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).fulfillOrder(
            99,
            500
        );
    }

    function test_fulfillOrder_advancesPointerOnFull()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            100 * 1e6,
            0
        );

        vm.prank(
            fulf
        );

        QueueFulfillFacet(address(que)).fulfillOrder(
            id1,
            0
        );

        assertEq(
            que.currentOrderIdByIncentive(0),
            id2
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_partiallyFulfillOrder_happyPath()
        public
    {
        uint256 total = 200 * 1e6;

        int256 inc = 500;

        _join(
            user1,
            total,
            inc
        );

        uint256 partialAmt = 50 * 1e6;

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).partiallyFulfillOrder(
            0,
            inc,
            partialAmt
        );

        assertEq(
            vt,
            partialAmt
        );

        assertEq(
            sc,
            partialAmt * (10_000 - 500) / 10_000
        );

        (
            ,
            uint256 remaining,
            ,
        ) = que.QueMemberByIdAndIncentive(
            0,
            inc
        );

        assertEq(
            remaining,
            total - partialAmt
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_partiallyFulfillOrder_zeroAmount_reverts()
        public
    {
        _join(
            user1,
            200 * 1e6,
            500
        );

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).partiallyFulfillOrder(
            0,
            500,
            0
        );
    }

    function test_partiallyFulfillOrder_amountTooHigh_reverts()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).partiallyFulfillOrder(
            0,
            500,
            100 * 1e6
        );
    }

    function test_partiallyFulfillOrder_tinyAmount_discountRoundsToZero()
        public
    {
        _join(
            user1,
            200 * 1e6,
            5000
        );

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).partiallyFulfillOrder(
            0,
            5000,
            1
        );

        assertEq(
            vt,
            1
        );

        assertEq(
            sc,
            1
        );
    }

    function test_partiallyFulfillOrder_lastOrderRemainsActive()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        vm.prank(
            fulf
        );

        QueueFulfillFacet(address(que)).partiallyFulfillOrder(
            id,
            0,
            50 * 1e6
        );

        assertEq(
            que.currentOrderIdByIncentive(0),
            id
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_fulfillOrderBulk_happyPath()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            150 * 1e6,
            500
        );

        _join(
            user3,
            200 * 1e6,
            500
        );

        int256[] memory incs = new int256[](2);

        uint256[] memory ids = new uint256[](2);

        uint256[] memory partials = new uint256[](0);

        incs[0] = 500;
        incs[1] = 500;

        ids[0] = 0;
        ids[1] = 1;

        vm.prank(
            fulf
        );

        (
            uint256 vtTotal,
            uint256 sc
        ) = QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            ids,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            vtTotal,
            250 * 1e6
        );

        assertEq(
            sc,
            (100 * 1e6 + 150 * 1e6) * 9_500 / 10_000
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );

        assertEq(
            que.currentOrderIdByIncentive(500),
            2
        );
    }

    function test_fulfillOrderBulk_zeroPartialAmount_skipsPartial()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](2);

        incs[0] = 0;
        incs[1] = 0;

        uint256[] memory orders = new uint256[](2);

        orders[0] = id1;
        orders[1] = id2;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            fulf
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            200 * 1e6
        );

        assertEq(
            spent,
            200 * 1e6
        );
    }

    function test_fulfillOrderBulk_withPartial()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            200 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);

        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);

        orders[0] = id1;

        uint256[] memory partials = new uint256[](1);

        partials[0] = id2;

        vm.prank(
            fulf
        );

        (
            uint256 received,
        ) = QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            50 * 1e6,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            150 * 1e6
        );
    }

    function test_fulfillOrderBulk_partialPresentZeroAmount_skipsPartialBranch()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            200 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);

        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);

        orders[0] = id1;

        uint256[] memory partials = new uint256[](1);

        partials[0] = id2;

        vm.prank(
            fulf
        );

        (
            uint256 received,
        ) = QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            100 * 1e6
        );
    }

    function test_fulfillOrderBulk_emptyOrders_emptyPartials_reverts()
        public
    {
        int256[] memory incs = new int256[](0);

        uint256[] memory orders = new uint256[](0);

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_fulfillOrderBulk_minReceiveTooLow_reverts()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        int256[] memory incs = new int256[](1);

        uint256[] memory ids = new uint256[](1);

        uint256[] memory partials = new uint256[](0);

        incs[0] = 500;
        ids[0] = 0;

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            ids,
            partials,
            0,
            999 * 1e6,
            type(uint256).max
        );
    }

    function test_fulfillOrderBulk_maxUsdExceeded_reverts()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);

        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);

        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            fulf
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            50 * 1e6
        );
    }

    // ---- 3. View helpers ----

    function test_predictDiscountedAmount()
        public
        view
    {
        assertEq(
            que.predictDiscountedAmount(
                100 * 1e6,
                500
            ),
            95 * 1e6
        );

        assertEq(
            que.predictDiscountedAmount(
                100 * 1e6,
                0
            ),
            100 * 1e6
        );

        assertEq(
            que.predictDiscountedAmount(
                100 * 1e6,
                -10_000
            ),
            200 * 1e6
        );
    }

    function test_predictCostForTokens_andTokensForCost_roundTrip()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            100 * 1e6,
            500
        );

        (
            uint256 cost,
            uint256 acquirable
        ) = que.predictCostForTokens(
            150 * 1e6
        );

        assertEq(
            acquirable,
            150 * 1e6
        );

        assertEq(
            cost,
            150 * 1e6 * 9_500 / 10_000
        );

        uint256 tokens = que.predictTokensForCost(
            cost
        );

        assertEq(
            tokens,
            150 * 1e6
        );
    }

    function test_predictCostForTokens_zero_returnsZero()
        public
        view
    {
        (
            uint256 cost,
            uint256 tokens
        ) = que.predictCostForTokens(
            0
        );

        assertEq(
            cost,
            0
        );

        assertEq(
            tokens,
            0
        );
    }

    function test_predictCostForTokens_insufficientLiquidity_returnsPartial()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        (
            uint256 cost,
            uint256 tokens
        ) = que.predictCostForTokens(
            500 * 1e6
        );

        assertEq(
            tokens,
            100 * 1e6
        );

        assertGt(
            cost,
            0
        );
    }

    function test_predictCostForTokens_exactlyAvailable()
        public
    {
        _join(
            user1,
            100 * 1e6,
            1000
        );

        (
            uint256 cost,
            uint256 tokens
        ) = que.predictCostForTokens(
            100 * 1e6
        );

        assertEq(
            tokens,
            100 * 1e6
        );

        assertGt(
            cost,
            0
        );
    }

    function test_predictCostForTokens_partialOrderUsed()
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
            0
        );

        (
            uint256 cost,
            uint256 tokens
        ) = que.predictCostForTokens(
            150 * 1e6
        );

        assertEq(
            tokens,
            150 * 1e6
        );

        assertGt(
            cost,
            0
        );
    }

    function test_predictTokensForCost_zero_returnsZero()
        public
        view
    {
        uint256 t = que.predictTokensForCost(
            0
        );

        assertEq(
            t,
            0
        );
    }

    function test_predictTokensForCost_noOrders_returnsZero()
        public
        view
    {
        uint256 t = que.predictTokensForCost(
            1_000 * 1e6
        );

        assertEq(
            t,
            0
        );
    }

    function test_predictTokensForCost_singleOrderFullyAffordable()
        public
    {
        _join(
            user1,
            1_000 * 1e6,
            500
        );

        uint256 tokens = que.predictTokensForCost(
            1_000 * 1e6
        );

        assertGt(
            tokens,
            0
        );

        assertLe(
            tokens,
            1_000 * 1e6
        );
    }

    function test_predictTokensForCost_traversesMultipleIncentives()
        public
    {
        _join(
            user1,
            200 * 1e6,
            5000
        );

        _join(
            user2,
            200 * 1e6,
            1000
        );

        _join(
            user3,
            200 * 1e6,
            0
        );

        uint256 tokens = que.predictTokensForCost(
            500 * 1e6
        );

        assertGt(
            tokens,
            0
        );
    }

    function test_predictTokensForCost_skipsEmptyOrders()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        _join(
            user3,
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id1,
            0
        );

        uint256 tokens = que.predictTokensForCost(
            300 * 1e6
        );

        assertGt(
            tokens,
            0
        );
    }

    function test_solveForAmount_returnsExpectedShape()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            50 * 1e6,
            500
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(
            150 * 1e6
        );

        assertEq(
            incentives.length,
            2
        );

        assertEq(
            orders.length,
            2
        );

        assertEq(
            partials.length,
            0
        );

        assertEq(
            incentives[0],
            500
        );

        assertEq(
            incentives[1],
            500
        );

        assertEq(
            orders[0],
            0
        );

        assertEq(
            orders[1],
            1
        );
    }

    function test_solveForAmount_acrossTiers()
        public
    {
        _join(
            user1,
            100 * 1e6,
            5000
        );

        _join(
            user2,
            100 * 1e6,
            500
        );

        _join(
            user3,
            100 * 1e6,
            0
        );

        (
            int256[] memory incs,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(
            250 * 1e6
        );

        assertGt(
            orders.length,
            0
        );

        assertEq(
            incs.length,
            orders.length + partials.length
        );
    }

    function test_solveForAmount_partialFinishes()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            200 * 1e6,
            0
        );

        (
            ,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(
            150 * 1e6
        );

        assertEq(
            orders.length,
            1
        );

        assertEq(
            partials.length,
            1
        );
    }

    function test_solveForAmount_negativeTierPartial()
        public
    {
        _join(
            user1,
            100 * 1e6,
            -2_000
        );

        _join(
            user2,
            200 * 1e6,
            -2_000
        );

        (
            ,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(
            150 * 1e6
        );

        assertEq(
            orders.length,
            1
        );

        assertEq(
            partials.length,
            1
        );
    }

    function test_solveForAmount_negativeTierFullOrders()
        public
    {
        _join(
            user1,
            100 * 1e6,
            -10_000
        );

        _join(
            user2,
            100 * 1e6,
            -10_000
        );

        (
            ,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(
            200 * 1e6
        );

        assertEq(
            orders.length,
            2
        );

        assertEq(
            partials.length,
            0
        );
    }

    function test_solveForAmountWithIncentive_emptyLevel_returnsEmpty()
        public
        view
    {
        (
            uint256[] memory full,
            uint256[] memory partial_
        ) = que._solveForAmountWithIncentive(
            1_000 * 1e6,
            0
        );

        assertEq(
            full.length,
            0
        );

        assertEq(
            partial_.length,
            0
        );
    }

    function test_solveForAmountWithIncentive_oneFull_noPartial()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        (
            uint256[] memory full,
            uint256[] memory partial_
        ) = que._solveForAmountWithIncentive(
            100 * 1e6,
            0
        );

        assertEq(
            full.length,
            1
        );

        assertEq(
            partial_.length,
            0
        );
    }

    function test_solveForAmountWithIncentive_multipleFullAndPartial()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            150 * 1e6,
            0
        );

        _join(
            user3,
            300 * 1e6,
            0
        );

        (
            uint256[] memory full,
            uint256[] memory partial_
        ) = que._solveForAmountWithIncentive(
            200 * 1e6,
            0
        );

        assertEq(
            full.length,
            1
        );

        assertEq(
            partial_.length,
            1
        );
    }

    function test_solveForAmountWithIncentive_skipsEmptyOrders()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        _join(
            user3,
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id1,
            0
        );

        (
            uint256[] memory full,
        ) = que._solveForAmountWithIncentive(
            150 * 1e6,
            0
        );

        assertEq(
            full.length,
            1
        );
    }

    // ---- Defensive-branch coverage (states the queue invariant prevents) ----

    function _queMemberBaseSlot(
        uint256 _id,
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        return uint256(
            keccak256(
                abi.encode(
                    _incentive,
                    keccak256(
                        abi.encode(
                            _id,
                            uint256(27)
                        )
                    )
                )
            )
        );
    }

    function test_getFulfillmentPlan_emptyFrontOrder_hitsEmptyBranch()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id1 = _join(
            user2,
            100 * 1e6,
            0
        );

        vm.store(
            address(vault),
            bytes32(
                _queMemberBaseSlot(
                    id0,
                    0
                ) + 1
            ),
            bytes32(uint256(0))
        );

        (
            uint256[] memory full,
            ,
        ) = que.getFulfillmentPlanForIncentive(
            100 * 1e6,
            0,
            10
        );

        assertEq(
            full.length,
            1
        );

        assertEq(
            full[0],
            id1
        );
    }

    function test_solveForAmountWithIncentive_emptyFrontOrder_hitsEmptyBranch()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id1 = _join(
            user2,
            100 * 1e6,
            0
        );

        vm.store(
            address(vault),
            bytes32(
                _queMemberBaseSlot(
                    id0,
                    0
                ) + 1
            ),
            bytes32(uint256(0))
        );

        (
            uint256[] memory full,
        ) = que._solveForAmountWithIncentive(
            100 * 1e6,
            0
        );

        assertEq(
            full.length,
            1
        );

        assertEq(
            full[0],
            id1
        );
    }

    function test_predictTokensForCost_emptyFrontOrder_hitsEmptyBranch()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        vm.store(
            address(vault),
            bytes32(
                _queMemberBaseSlot(
                    id0,
                    0
                ) + 1
            ),
            bytes32(uint256(0))
        );

        uint256 tokens = que.predictTokensForCost(
            100 * 1e6
        );

        assertEq(
            tokens,
            100 * 1e6
        );
    }

    function test_leaveQue_selfPointingHead_hitsCurrentPointerBranch()
        public
    {
        uint256 id0 = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.store(
            address(vault),
            bytes32(
                _queMemberBaseSlot(
                    id0,
                    0
                ) + 3
            ),
            bytes32(id0)
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id0,
            0
        );

        assertEq(
            vault.totalActiveOrders(),
            0
        );
    }

    function test_getAllOrdersfromAddress_noOrders()
        public
        view
    {
        (
            QueContractDiamondStructs.QueMember[] memory ms,
            int256[] memory incs
        ) = que.getAllOrdersfromAddress(
            user1
        );

        assertEq(
            ms.length,
            0
        );

        assertEq(
            incs.length,
            0
        );
    }

    function test_getAllOrdersfromAddress_filtered()
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
            500
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        (
            QueContractDiamondStructs.QueMember[] memory ms,
            int256[] memory incs
        ) = que.getAllOrdersfromAddress(
            user1
        );

        assertEq(
            ms.length,
            2
        );

        assertEq(
            incs.length,
            2
        );

        for (uint256 i; i < ms.length; ++i) {
            assertEq(
                ms[i].member,
                user1
            );
        }
    }

    function test_getAllOrdersfromAddress_afterLeave()
        public
    {
        _join(
            user1,
            100 * 1e6,
            500
        );

        _join(
            user2,
            200 * 1e6,
            500
        );

        _join(
            user1,
            80 * 1e6,
            1000
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            0,
            500
        );

        (
            QueContractDiamondStructs.QueMember[] memory mine,
        ) = que.getAllOrdersfromAddress(
            user1
        );

        assertEq(
            mine.length,
            1
        );

        assertEq(
            mine[0].member,
            user1
        );

        assertEq(
            mine[0].amount,
            80 * 1e6
        );

        (
            QueContractDiamondStructs.QueMember[] memory all,
        ) = que.getAllOrdersOverall();

        assertEq(
            all.length,
            2
        );
    }

    function test_getAllOrdersOverall_includesAll()
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

        _join(
            user3,
            100 * 1e6,
            1000
        );

        (
            QueContractDiamondStructs.QueMember[] memory ms,
            int256[] memory incs
        ) = que.getAllOrdersOverall();

        assertEq(
            ms.length,
            3
        );

        assertEq(
            incs.length,
            3
        );
    }

    function test_getAllOrdersOverall_excludesEmpty()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id1,
            0
        );

        (
            QueContractDiamondStructs.QueMember[] memory ms,
        ) = que.getAllOrdersOverall();

        assertEq(
            ms.length,
            1
        );

        assertEq(
            ms[0].member,
            user2
        );
    }

    // ---- 4. getFulfillmentPlanForIncentive edge cases ----

    function test_getFulfillmentPlan_emptyLevel_returnsEmpty()
        public
        view
    {
        (
            uint256[] memory full,
            uint256[] memory partial_,
        ) = que.getFulfillmentPlanForIncentive(
            100,
            0,
            10
        );

        assertEq(
            full.length,
            0
        );

        assertEq(
            partial_.length,
            0
        );
    }

    function test_getFulfillmentPlan_maxOrdersZero_clampedToDefault()
        public
    {
        _join(
            user1,
            50 * 1e6,
            0
        );

        _join(
            user2,
            50 * 1e6,
            0
        );

        (
            uint256[] memory full,
            ,
        ) = que.getFulfillmentPlanForIncentive(
            50 * 1e6,
            0,
            0
        );

        assertEq(
            full.length,
            1
        );
    }

    function test_getFulfillmentPlan_maxOrdersAboveLimit_clamped()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        (
            uint256[] memory full,
            ,
        ) = que.getFulfillmentPlanForIncentive(
            100 * 1e6,
            0,
            500
        );

        assertEq(
            full.length,
            1
        );
    }

    function test_getFulfillmentPlan_traversesAndStopsAtLimit()
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
            0
        );

        _join(
            user3,
            100 * 1e6,
            0
        );

        (
            uint256[] memory full,
            uint256[] memory partial_,
        ) = que.getFulfillmentPlanForIncentive(
            250 * 1e6,
            0,
            2
        );

        assertEq(
            full.length,
            2
        );

        assertEq(
            partial_.length,
            0
        );
    }

    function test_getFulfillmentPlan_withPartial()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            200 * 1e6,
            0
        );

        (
            uint256[] memory full,
            uint256[] memory partial_,
        ) = que.getFulfillmentPlanForIncentive(
            150 * 1e6,
            0,
            10
        );

        assertEq(
            full.length,
            1
        );

        assertEq(
            partial_.length,
            1
        );
    }

    function test_getFulfillmentPlan_withEmptyOrders()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user2,
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id1,
            0
        );

        (
            uint256[] memory full,
            ,
        ) = que.getFulfillmentPlanForIncentive(
            100 * 1e6,
            0,
            10
        );

        assertEq(
            full.length,
            1
        );
    }

    function test_getFulfillmentPlan_emptyOrderHittingConsiderationLimit()
        public
    {
        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            100 * 1e6,
            0
        );

        _join(
            user3,
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id1,
            0
        );

        vm.prank(
            user2
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id2,
            0
        );

        (
            uint256[] memory full,
            ,
        ) = que.getFulfillmentPlanForIncentive(
            100 * 1e6,
            0,
            10
        );

        assertEq(
            full.length,
            1
        );
    }

    // ---- 5. Admin coverage ----

    function test_changeMinDepositAmount_master()
        public
    {
        QueueAdminFacet(address(que)).changeMinDepositAmount(
            1234
        );

        assertEq(
            que.minDepositAmount(),
            1234
        );
    }

    function test_changeMinDepositAmount_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueAdminFacet(address(que)).changeMinDepositAmount(
            1
        );
    }

    function test_changeMinDepositAmount_takesEffect()
        public
    {
        QueueAdminFacet(address(que)).changeMinDepositAmount(
            200 * 1e6
        );

        assertEq(
            que.minDepositAmount(),
            200 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueJoinLeaveFacet(address(que)).joinQue(
            100 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        (
            QueContractDiamondStructs.QueMember memory member,
        ) = QueueJoinLeaveFacet(address(que)).joinQue(
            200 * 1e6,
            0
        );

        assertEq(
            member.member,
            user1
        );

        assertEq(
            member.amount,
            200 * 1e6
        );
    }

    function test_setNegativeIncentivesNotAllowed_master()
        public
    {
        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            true
        );

        assertTrue(
            que.negativeIncentivesNotAllowed()
        );

        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            false
        );

        assertFalse(
            que.negativeIncentivesNotAllowed()
        );
    }

    function test_setNegativeIncentivesNotAllowed_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert();

        QueueAdminFacet(address(que)).setNegativeIncentivesNotAllowed(
            true
        );
    }

    function test_setProxyBenefactor_resetAfterCall()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        assertEq(
            vault.currentProxyBenefactor(),
            address(0)
        );
    }

    // ---- 6. Diamond machinery - selector routing ----

    function _bareQueue()
        internal
        returns (WiseSovrenNodesDiamond q)
    {
        q = new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: address(usd),
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 100_000_000 * 1e6,
                interestRate: 2000,
                decimalsValue: 6,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "wsnUSDC"
            })
        );
    }

    function test_finalizeSetup_twice_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.finalizeSetup();

        vm.expectRevert(
            AlreadyInitialized.selector
        );

        q.finalizeSetup();
    }

    function test_finalizeSetup_nonMaster_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        q.finalizeSetup();
    }

    function test_finalizeSetup_writesFlagAndEmits()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        assertFalse(
            q.initialized()
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SetupFinalized();

        q.finalizeSetup();

        assertTrue(
            q.initialized()
        );
    }

    function test_proposeSelector_writesStorageAndEmits()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorProposed(
            SEL_FAKE,
            address(adminFacet),
            block.timestamp + DELAY
        );

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        assertEq(
            q.proposedSelectorFacet(SEL_FAKE),
            address(adminFacet)
        );

        assertEq(
            q.selectorChangeQueuedAt(SEL_FAKE),
            block.timestamp
        );

        assertEq(
            q.selectorToFacet(SEL_FAKE),
            address(0)
        );
    }

    function test_proposeSelector_nonMaster_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );
    }

    function test_executeSelectorChange_preFinalize_appliesImmediately()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorUpdated(
            SEL_FAKE,
            address(adminFacet)
        );

        q.executeSelectorChange(
            SEL_FAKE
        );

        assertEq(
            q.selectorToFacet(SEL_FAKE),
            address(adminFacet)
        );

        assertEq(
            q.proposedSelectorFacet(SEL_FAKE),
            address(0)
        );

        assertEq(
            q.selectorChangeQueuedAt(SEL_FAKE),
            0
        );
    }

    function test_executeSelectorChange_noProposal_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        q.executeSelectorChange(
            SEL_FAKE
        );
    }

    function test_executeSelectorChange_nonMaster_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        q.executeSelectorChange(
            SEL_FAKE
        );
    }

    function test_executeSelectorChange_postFinalize_revertsJustBeforeDelay()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.finalizeSetup();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.warp(
            block.timestamp + DELAY - 1
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        q.executeSelectorChange(
            SEL_FAKE
        );
    }

    function test_executeSelectorChange_postFinalize_succeedsAtExactDelay()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.finalizeSetup();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.warp(
            block.timestamp + DELAY
        );

        q.executeSelectorChange(
            SEL_FAKE
        );

        assertEq(
            q.selectorToFacet(SEL_FAKE),
            address(adminFacet)
        );
    }

    function test_executeSelectorChange_postFinalize_succeedsAfterDelay()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.finalizeSetup();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.warp(
            block.timestamp + DELAY + 1
        );

        q.executeSelectorChange(
            SEL_FAKE
        );

        assertEq(
            q.selectorToFacet(SEL_FAKE),
            address(adminFacet)
        );
    }

    function test_executeSelectorChanges_batchPostDelay()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        bytes4[] memory sels = new bytes4[](2);

        sels[0] = SEL_FAKE;
        sels[1] = bytes4(keccak256("another()"));

        q.proposeSelectors(
            sels,
            address(adminFacet)
        );

        q.finalizeSetup();

        vm.warp(
            block.timestamp + DELAY
        );

        q.executeSelectorChanges(
            sels
        );

        assertEq(
            q.selectorToFacet(sels[0]),
            address(adminFacet)
        );

        assertEq(
            q.selectorToFacet(sels[1]),
            address(adminFacet)
        );
    }

    function test_cancelSelectorProposal_clearsAndEmits()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorProposalCancelled(
            SEL_FAKE
        );

        q.cancelSelectorProposal(
            SEL_FAKE
        );

        assertEq(
            q.proposedSelectorFacet(SEL_FAKE),
            address(0)
        );

        assertEq(
            q.selectorChangeQueuedAt(SEL_FAKE),
            0
        );
    }

    function test_cancelSelectorProposal_nonMaster_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        q.cancelSelectorProposal(
            SEL_FAKE
        );
    }

    function test_cancelSelectorProposal_thenExecute_reverts()
        public
    {
        WiseSovrenNodesDiamond q = _bareQueue();

        q.proposeSelector(
            SEL_FAKE,
            address(adminFacet)
        );

        q.cancelSelectorProposal(
            SEL_FAKE
        );

        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        q.executeSelectorChange(
            SEL_FAKE
        );
    }

    function test_fallback_facetNotFound_reverts()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(que).call(
            abi.encodeWithSignature(
                "doesNotExistAtAll()"
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );
    }

    function test_fallback_routesAndDelegateCalls()
        public
    {
        QueueAdminFacet(address(que)).changeMinDepositAmount(
            777
        );

        assertEq(
            que.minDepositAmount(),
            777
        );
    }

    function test_fallback_bubblesFacetRevert()
        public
    {
        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        QueueAdminFacet(address(que)).changeMinDepositAmount(
            1
        );
    }

    // ---- 7. onlyDelegateCall - direct facet calls revert ----

    function test_onlyDelegateCall_adminFacet_reverts()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        adminFacet.changeMinDepositAmount(
            1
        );
    }

    function test_onlyDelegateCall_joinLeaveFacet_reverts()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        joinLeaveFacet.joinQue(
            100 * 1e6,
            0
        );
    }

    function test_onlyDelegateCall_fulfillFacet_reverts()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        fulfillFacet.fulfillOrder(
            0,
            0
        );
    }

    // ---- 8. queue interest - member keeps earning and claiming while queued ----

    function _expectedInterest(
        uint256 _balance,
        uint256 _timeDelta
    )
        internal
        view
        returns (uint256)
    {
        uint256 yearFactor = _timeDelta
            * 1e18
            / 31_540_000;

        return _balance
            * vault.interestRate()
            * yearFactor
            / 10_000
            / 1e18;
    }

    function _assertContractSelfInterestZero()
        internal
        view
    {
        assertEq(
            vault.InterestRateProxy(),
            address(vault)
        );

        assertEq(
            vault.getPendingInterest(address(vault)),
            0
        );

        assertEq(
            vault.cashedInterest(address(vault)),
            0
        );

        assertEq(
            vault.proxyBalance(address(vault)),
            0
        );
    }

    function test_queue_memberEarnsAndClaimsWhileQueued_selfInterestZero()
        public
    {
        usd.mint(
            address(vault),
            1_000_000 * 1e6
        );

        uint256 stake = 10_000 * 1e6;

        uint256 id = _join(
            user1,
            stake,
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(address(vault)),
            stake
        );

        assertEq(
            vault.proxyBalance(user1),
            stake
        );

        assertEq(
            vault.getPendingInterest(user1),
            0
        );

        _assertContractSelfInterestZero();

        vm.warp(
            block.timestamp + 31_540_000
        );

        uint256 expected = _expectedInterest(
            stake,
            31_540_000
        );

        assertGt(
            expected,
            0
        );

        assertEq(
            vault.getPendingInterest(user1),
            expected
        );

        _assertContractSelfInterestZero();

        uint256 usdBefore = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 claimedFirst = UserFacet(address(vault)).claimInterest();

        assertEq(
            claimedFirst,
            expected
        );

        assertEq(
            usd.balanceOf(user1),
            usdBefore + expected
        );

        assertEq(
            vault.cashedInterest(user1),
            0
        );

        assertEq(
            vault.proxyBalance(user1),
            stake
        );

        _assertContractSelfInterestZero();

        vm.warp(
            block.timestamp + 31_540_000
        );

        assertEq(
            vault.getPendingInterest(user1),
            expected
        );

        vm.prank(
            user1
        );

        uint256 claimedSecond = UserFacet(address(vault)).claimInterest();

        assertEq(
            claimedSecond,
            expected
        );

        _assertContractSelfInterestZero();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(que)).leaveQue(
            id,
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            stake
        );

        assertEq(
            vault.proxyBalance(user1),
            0
        );

        assertEq(
            que.totalActiveOrders(),
            0
        );

        assertEq(
            usd.balanceOf(user1),
            usdBefore + expected + expected
        );

        _assertContractSelfInterestZero();
    }

    function test_queue_contractAddressNeverAccruesWhileHoldingQueuedFunds()
        public
    {
        _join(
            user1,
            10_000 * 1e6,
            0
        );

        _join(
            user2,
            5_000 * 1e6,
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(address(vault)),
            15_000 * 1e6
        );

        vm.warp(
            block.timestamp + 3 * 31_540_000
        );

        assertGt(
            vault.getPendingInterest(user1),
            0
        );

        assertGt(
            vault.getPendingInterest(user2),
            0
        );

        _assertContractSelfInterestZero();
    }

    // ---- 5. compoundInterestViaFulfillBulk ----

    function _compInterest(
        uint256 _principal
    )
        internal
        returns (uint256 interest)
    {
        AdminFacet(address(vault)).mintSupply(
            comp,
            _principal
        );

        vm.warp(
            block.timestamp + 31_540_000
        );

        usd.mint(
            address(vault),
            100_000_000 * 1e6
        );

        interest = _principal
            * 2000
            / 10_000;
    }

    struct PathMetrics {
        uint256 compVault;
        uint256 compUsd;
        uint256 user1Usd;
        uint256 user2Usd;
        uint256 thirdParty;
        uint256 contractUsd;
        uint256 supply;
        uint256 cashed;
    }

    function _capture()
        internal
        view
        returns (PathMetrics memory m)
    {
        m.compVault = IERC20(address(vault)).balanceOf(comp);
        m.compUsd = usd.balanceOf(comp);
        m.user1Usd = usd.balanceOf(user1);
        m.user2Usd = usd.balanceOf(user2);
        m.thirdParty = usd.balanceOf(thirdPty);
        m.contractUsd = usd.balanceOf(address(vault));
        m.supply = IERC20(address(vault)).totalSupply();
        m.cashed = vault.cashedInterest(comp);
    }

    function _assertSameMetrics(
        PathMetrics memory _a,
        PathMetrics memory _b
    )
        internal
        pure
    {
        assertEq(
            _a.compVault,
            _b.compVault
        );

        assertEq(
            _a.compUsd,
            _b.compUsd
        );

        assertEq(
            _a.user1Usd,
            _b.user1Usd
        );

        assertEq(
            _a.user2Usd,
            _b.user2Usd
        );

        assertEq(
            _a.thirdParty,
            _b.thirdParty
        );

        assertEq(
            _a.contractUsd,
            _b.contractUsd
        );

        assertEq(
            _a.supply,
            _b.supply
        );

        assertEq(
            _a.cashed,
            _b.cashed
        );
    }

    function test_compoundViaFulfill_partialRemainderCompounded()
        public
    {
        uint256 interest = _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            150 * 1e6,
            0
        );

        int256[] memory incs = new int256[](2);
        incs[0] = 0;
        incs[1] = 0;

        uint256[] memory orders = new uint256[](2);
        orders[0] = id1;
        orders[1] = id2;

        uint256[] memory partials = new uint256[](0);

        uint256 compVaultBefore = IERC20(address(vault)).balanceOf(comp);
        uint256 supplyBefore = IERC20(address(vault)).totalSupply();
        uint256 thirdPartyBefore = usd.balanceOf(thirdPty);
        uint256 contractUsdBefore = usd.balanceOf(address(vault));

        vm.prank(
            comp
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            250 * 1e6
        );

        assertEq(
            spent,
            250 * 1e6
        );

        uint256 remainder = interest - spent;

        assertEq(
            vault.cashedInterest(comp),
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(comp),
            compVaultBefore + received + remainder
        );

        assertEq(
            IERC20(address(vault)).totalSupply(),
            supplyBefore + remainder
        );

        assertEq(
            usd.balanceOf(thirdPty),
            thirdPartyBefore + remainder
        );

        assertEq(
            usd.balanceOf(user1),
            100 * 1e6
        );

        assertEq(
            usd.balanceOf(user2),
            150 * 1e6
        );

        assertEq(
            usd.balanceOf(address(vault)),
            contractUsdBefore - interest
        );

        _assertContractSelfInterestZero();
    }

    function test_compoundViaFulfill_exactNoRemainder()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            2_000 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        uint256 supplyBefore = IERC20(address(vault)).totalSupply();
        uint256 thirdPartyBefore = usd.balanceOf(thirdPty);

        vm.prank(
            comp
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            2_000 * 1e6
        );

        assertEq(
            spent,
            2_000 * 1e6
        );

        assertEq(
            vault.cashedInterest(comp),
            0
        );

        assertEq(
            IERC20(address(vault)).totalSupply(),
            supplyBefore
        );

        assertEq(
            usd.balanceOf(thirdPty),
            thirdPartyBefore
        );
    }

    function test_compoundViaFulfill_withPartialOrder()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            200 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](1);
        partials[0] = id2;

        vm.prank(
            comp
        );

        (
            uint256 received,
        ) = QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            50 * 1e6,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            150 * 1e6
        );

        assertEq(
            que.totalActiveOrders(),
            1
        );
    }

    function test_compoundViaFulfill_discountBenefit()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            500
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 500;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            100 * 1e6
        );

        assertEq(
            spent,
            95 * 1e6
        );

        assertGt(
            received,
            spent
        );
    }

    function test_compoundViaFulfill_ordersExceedInterest_reverts()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            3_000 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_compoundViaFulfill_noInterest_reverts()
        public
    {
        usd.mint(
            address(vault),
            100_000_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_compoundViaFulfill_whenPaused_reverts()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        AdminFacet(address(vault)).pauseDeposits();

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_compoundViaFulfill_noOrders_reverts()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        int256[] memory incs = new int256[](0);
        uint256[] memory orders = new uint256[](0);
        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_compoundViaFulfill_minReceiveTooHigh_reverts()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            999 * 1e6,
            type(uint256).max
        );
    }

    function test_compoundViaFulfill_maxUsdTooLow_reverts()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            50 * 1e6
        );
    }

    function test_compoundViaFulfill_equivalence_exact()
        public
    {
        uint256 interest = _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            2_000 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        uint256 snap = vm.snapshotState();

        vm.startPrank(
            comp
        );

        UserFacet(address(vault)).claimInterest();

        IERC20(address(usd)).approve(
            address(que),
            type(uint256).max
        );

        QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        vm.stopPrank();

        PathMetrics memory a = _capture();

        vm.revertToState(
            snap
        );

        vm.prank(
            comp
        );

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        _assertSameMetrics(
            a,
            _capture()
        );

        assertEq(
            interest,
            2_000 * 1e6
        );
    }

    function test_compoundViaFulfill_equivalence_partial()
        public
    {
        uint256 interest = _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            150 * 1e6,
            0
        );

        int256[] memory incs = new int256[](2);
        incs[0] = 0;
        incs[1] = 0;

        uint256[] memory orders = new uint256[](2);
        orders[0] = id1;
        orders[1] = id2;

        uint256[] memory partials = new uint256[](0);

        uint256 consumed = 250 * 1e6;

        uint256 snap = vm.snapshotState();

        vm.startPrank(
            comp
        );

        UserFacet(address(vault)).claimInterestExactAmount(
            consumed
        );

        IERC20(address(usd)).approve(
            address(que),
            type(uint256).max
        );

        QueueFulfillFacet(address(que)).fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        UserFacet(address(vault)).compoundInterest();

        vm.stopPrank();

        PathMetrics memory a = _capture();

        vm.revertToState(
            snap
        );

        vm.prank(
            comp
        );

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        _assertSameMetrics(
            a,
            _capture()
        );

        assertEq(
            interest,
            2_000 * 1e6
        );
    }

    // ---- adversarial: cannot spend more than your own interest ----

    function test_compoundViaFulfill_attack_overspendRevertsNoStateChange()
        public
    {
        address attacker = address(0xBAD);

        AdminFacet(address(vault)).mintSupply(
            attacker,
            500 * 1e6
        );

        vm.warp(
            block.timestamp + 31_540_000
        );

        usd.mint(
            address(vault),
            100_000_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            1_000 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        uint256 contractUsdBefore = usd.balanceOf(address(vault));
        uint256 attackerVaultBefore = IERC20(address(vault)).balanceOf(attacker);
        uint256 user1UsdBefore = usd.balanceOf(user1);
        uint256 supplyBefore = IERC20(address(vault)).totalSupply();

        vm.prank(
            attacker
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            usd.balanceOf(address(vault)),
            contractUsdBefore
        );

        assertEq(
            IERC20(address(vault)).balanceOf(attacker),
            attackerVaultBefore
        );

        assertEq(
            usd.balanceOf(user1),
            user1UsdBefore
        );

        assertEq(
            IERC20(address(vault)).totalSupply(),
            supplyBefore
        );

        assertEq(
            vault.getPendingInterest(attacker),
            100 * 1e6
        );

        assertEq(
            vault.cashedInterest(attacker),
            0
        );
    }

    function test_compoundViaFulfill_attack_zeroInterestCannotSpendContractBacking()
        public
    {
        address attacker = address(0xBAD);

        uint256 victimInterest = _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            1_000 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        uint256 contractUsdBefore = usd.balanceOf(address(vault));
        uint256 victimPendingBefore = vault.getPendingInterest(comp);

        vm.prank(
            attacker
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            IERC20(address(vault)).balanceOf(attacker),
            0
        );

        assertEq(
            usd.balanceOf(attacker),
            0
        );

        assertEq(
            usd.balanceOf(address(vault)),
            contractUsdBefore
        );

        assertEq(
            vault.getPendingInterest(comp),
            victimPendingBefore
        );

        assertEq(
            victimInterest,
            2_000 * 1e6
        );
    }

    function test_compoundViaFulfill_attack_cannotAggregateOrdersPastInterest()
        public
    {
        address attacker = address(0xBAD);

        AdminFacet(address(vault)).mintSupply(
            attacker,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + 31_540_000
        );

        usd.mint(
            address(vault),
            100_000_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 id2 = _join(
            user2,
            100 * 1e6,
            0
        );

        uint256 id3 = _join(
            user3,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](3);
        incs[0] = 0;
        incs[1] = 0;
        incs[2] = 0;

        uint256[] memory orders = new uint256[](3);
        orders[0] = id1;
        orders[1] = id2;
        orders[2] = id3;

        uint256[] memory partials = new uint256[](0);

        uint256 contractUsdBefore = usd.balanceOf(address(vault));
        uint256 attackerVaultBefore = IERC20(address(vault)).balanceOf(attacker);

        vm.prank(
            attacker
        );

        vm.expectRevert();

        QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            usd.balanceOf(address(vault)),
            contractUsdBefore
        );

        assertEq(
            usd.balanceOf(user1),
            0
        );

        assertEq(
            usd.balanceOf(user2),
            0
        );

        assertEq(
            usd.balanceOf(user3),
            0
        );

        assertEq(
            IERC20(address(vault)).balanceOf(attacker),
            attackerVaultBefore
        );
    }

    // ---- single tx: no approval / allowance / permit needed ----

    function test_compoundViaFulfill_requiresNoApprovalOrPermit()
        public
    {
        _compInterest(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            100 * 1e6,
            0
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;

        uint256[] memory partials = new uint256[](0);

        assertEq(
            usd.balanceOf(comp),
            0
        );

        assertEq(
            usd.allowance(comp, address(vault)),
            0
        );

        assertEq(
            IERC20(address(vault)).allowance(comp, address(vault)),
            0
        );

        vm.prank(
            comp
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(que)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            received,
            100 * 1e6
        );

        assertEq(
            spent,
            100 * 1e6
        );
    }

}
