// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {InterestAdminFacet} from "../../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {WiseSovrenNodesQueueUIHelper} from "../../../src/diamond/vault/helpers/WiseSovrenNodesQueueUIHelper.sol";

/**
 * @dev Live-state rehearsal against the REAL mainnet deployment at the
 * canonical address. Forks mainnet at HEAD (live-state rehearsals always
 * fork HEAD so they see the state actually onchain), attaches to the
 * deployed diamond - nothing is deployed by this suite - and walks the
 * full user lifecycle on the production bytecode: activation, deposits,
 * interest accrual over time, claim and compound, both queue halves,
 * quote-equals-execution on single, partial and bulk fulfilment, lane
 * switching, full-escrow exit, and the scheduled rate cut semantics.
 *
 * The vault ships dormant, so `_activate` finalizes and opens the gate
 * as master ON THE FORK ONLY, skipping either step once the real chain
 * has performed it - the suite stays green before and after the real
 * activation. The dormant-gate test early-returns once real deposits
 * are open. Interest payouts are funded by dealing USD to the diamond,
 * standing in for operator treasury funding, and interest amounts are
 * asserted as bounds so the suite does not encode a second copy of the
 * accrual formula.
 */
contract WiseSovrenNodesMainnetLiveForkTest is Test {

    address internal constant DIAMOND = 0x50bae2675A6D7D9CADf9e2Ec96c7e45897Be8603;

    address internal constant MASTER = 0xAE2c0c6eAD34b8E9156b146BE8B724CDb80Ba7e1;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant YEAR = 365 days;

    WiseSovrenNodesDiamond internal diamond;

    address internal alice;
    address internal bob;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        diamond = WiseSovrenNodesDiamond(
            payable(DIAMOND)
        );

        alice = makeAddr(
            "alice"
        );

        bob = makeAddr(
            "bob"
        );

        assertEq(
            diamond.master(),
            MASTER,
            "attached to the live diamond with the expected master"
        );
    }

    function test_fork_live_depositRevertsWhileDormant()
        public
    {
        if (diamond.depositsDisabled() == false) {
            return;
        }

        _fund(
            alice,
            1_000 * 1e6
        );

        vm.prank(
            alice
        );

        vm.expectRevert();

        UserFacet(DIAMOND).deposit(
            1_000 * 1e6
        );
    }

    function test_fork_live_activationOpensDeposits()
        public
    {
        _activate();

        assertEq(
            diamond.initialized(),
            true,
            "finalizeSetup flipped initialized on the fork"
        );

        assertEq(
            diamond.depositsDisabled(),
            false,
            "deposit gate open on the fork"
        );

        _fund(
            alice,
            1_000 * 1e6
        );

        vm.prank(
            alice
        );

        UserFacet(DIAMOND).deposit(
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(alice),
            1_000 * 1e6,
            "live diamond mints shares one to one against real USDC"
        );
    }

    function test_fork_live_interestAccruesOverTimeAndClaims()
        public
    {
        _activate();

        _depositAs(
            alice,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + 180 days
        );

        uint256 usdBefore = IERC20(USDC).balanceOf(
            alice
        );

        vm.prank(
            alice
        );

        UserFacet(DIAMOND).claimInterest();

        uint256 claimed = IERC20(USDC).balanceOf(alice) - usdBefore;

        uint256 expected = 1_000 * 1e6 * 4_000 * 180 days / (10_000 * YEAR);

        assertGt(
            claimed,
            expected * 95 / 100,
            "180 days at the 40 percent launch rate accrued on the live vault"
        );

        assertLt(
            claimed,
            expected * 105 / 100,
            "claim does not exceed the launch rate accrual"
        );
    }

    function test_fork_live_compoundMintsInterestAsShares()
        public
    {
        _activate();

        _depositAs(
            alice,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + YEAR
        );

        vm.prank(
            alice
        );

        UserFacet(DIAMOND).compoundInterest();

        uint256 expected = 1_000 * 1e6 + (1_000 * 1e6 * 4_000 / 10_000);

        assertGt(
            diamond.balanceOf(alice),
            expected * 95 / 100,
            "one year compounded into shares at the launch rate"
        );

        assertLt(
            diamond.balanceOf(alice),
            expected * 105 / 100,
            "compound does not exceed the launch rate accrual"
        );
    }

    function test_fork_live_discountLaneQuoteEqualsExecution()
        public
    {
        _activate();

        _depositAs(
            alice,
            500 * 1e6
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            500 * 1e6,
            500
        );

        (
            uint256 quotedCost,
            uint256 quotedTokens
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).predictCostForTokens(
            500 * 1e6
        );

        assertEq(
            quotedCost,
            475 * 1e6,
            "the 500 bps lane quotes 95 percent of face"
        );

        assertEq(
            quotedTokens,
            500 * 1e6,
            "the full order is acquirable"
        );

        (
            ,
            uint256[] memory orders,
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).solveForAmount(
            500 * 1e6
        );

        _fund(
            bob,
            1_000 * 1e6
        );

        uint256 aliceUsdBefore = IERC20(USDC).balanceOf(
            alice
        );

        vm.prank(
            bob
        );

        (
            uint256 gotTokens,
            uint256 paidUsd
        ) = QueueFulfillFacet(DIAMOND).fulfillOrder(
            orders[0],
            500
        );

        assertEq(
            gotTokens,
            quotedTokens,
            "execution delivers exactly the quoted tokens"
        );

        assertEq(
            paidUsd,
            quotedCost,
            "execution costs exactly the quoted USD"
        );

        assertEq(
            diamond.balanceOf(bob),
            500 * 1e6,
            "buyer received the escrowed shares"
        );

        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceUsdBefore,
            475 * 1e6,
            "seller was paid the discounted proceeds directly"
        );
    }

    function test_fork_live_premiumLanePartialFillAndFullEscrowExit()
        public
    {
        _activate();

        _depositAs(
            alice,
            300 * 1e6
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            300 * 1e6,
            -2_000
        );

        _fund(
            bob,
            1_000 * 1e6
        );

        uint256 aliceUsdBefore = IERC20(USDC).balanceOf(
            alice
        );

        vm.prank(
            bob
        );

        (
            uint256 gotTokens,
            uint256 paidUsd
        ) = QueueFulfillFacet(DIAMOND).partiallyFulfillOrder(
            0,
            -2_000,
            100 * 1e6
        );

        assertEq(
            gotTokens,
            100 * 1e6,
            "partial fill delivers the requested tokens"
        );

        assertEq(
            paidUsd,
            120 * 1e6,
            "the first premium rung charges 1.2x face"
        );

        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceUsdBefore,
            120 * 1e6,
            "seller banks the premium proceeds"
        );

        uint256 sharesBefore = diamond.balanceOf(
            alice
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).leaveQue(
            0,
            -2_000
        );

        assertEq(
            diamond.balanceOf(alice) - sharesBefore,
            200 * 1e6,
            "leaveQue returns the full remaining escrow"
        );
    }

    function test_fork_live_mixedBookBulkQuoteEqualsExecution()
        public
    {
        _activate();

        _depositAs(
            alice,
            600 * 1e6
        );

        vm.startPrank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            300 * 1e6,
            500
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            300 * 1e6,
            -2_000
        );

        vm.stopPrank();

        (
            uint256 quotedCost,
            uint256 quotedTokens
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).predictCostForTokens(
            400 * 1e6
        );

        assertEq(
            quotedCost,
            405 * 1e6,
            "mixed book quote: 300 at 0.95 plus 100 at 1.2"
        );

        assertEq(
            quotedTokens,
            400 * 1e6,
            "mixed book plan covers the full amount"
        );

        assertEq(
            WiseSovrenNodesQueueUIHelper(DIAMOND).predictTokensForCost(
                405 * 1e6
            ),
            400 * 1e6,
            "inverse quote agrees with the forward quote"
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).solveForAmount(
            400 * 1e6
        );

        _fund(
            bob,
            1_000 * 1e6
        );

        vm.prank(
            bob
        );

        (
            uint256 gotTokens,
            uint256 paidUsd
        ) = QueueFulfillFacet(DIAMOND).fulfillOrderBulk(
            incentives,
            orders,
            partials,
            100 * 1e6,
            400 * 1e6,
            quotedCost
        );

        assertEq(
            gotTokens,
            quotedTokens,
            "bulk execution delivers exactly the quoted tokens"
        );

        assertEq(
            paidUsd,
            quotedCost,
            "bulk execution costs exactly the quoted USD"
        );
    }

    function test_fork_live_switchQueIncentiveMovesTheOrder()
        public
    {
        _activate();

        _depositAs(
            alice,
            200 * 1e6
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            200 * 1e6,
            500
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).switchQueIncentive(
            0,
            500,
            -2_000
        );

        (
            uint256 quotedCost,
            uint256 quotedTokens
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).predictCostForTokens(
            200 * 1e6
        );

        assertEq(
            quotedTokens,
            200 * 1e6,
            "the switched order is quotable in the premium lane"
        );

        assertEq(
            quotedCost,
            240 * 1e6,
            "the switched order prices at 1.2x face"
        );
    }

    function test_fork_live_rateCutRepricesUnbankedWindow()
        public
    {
        _activate();

        _depositAs(
            alice,
            1_000 * 1e6
        );

        _depositAs(
            bob,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + 90 days
        );

        uint256 bobUsdBefore = IERC20(USDC).balanceOf(
            bob
        );

        vm.prank(
            bob
        );

        UserFacet(DIAMOND).claimInterest();

        uint256 bobClaim = IERC20(USDC).balanceOf(bob) - bobUsdBefore;

        vm.prank(
            MASTER
        );

        AdminFacet(DIAMOND).setInterestRate(
            2_000
        );

        uint256 aliceUsdBefore = IERC20(USDC).balanceOf(
            alice
        );

        vm.prank(
            alice
        );

        UserFacet(DIAMOND).claimInterest();

        uint256 aliceClaim = IERC20(USDC).balanceOf(alice) - aliceUsdBefore;

        assertGt(
            bobClaim,
            0,
            "banking before the cut pays the outgoing rate"
        );

        assertGt(
            aliceClaim * 100 / bobClaim,
            45,
            "the idle window reprices near half after the cut to 2000"
        );

        assertLt(
            aliceClaim * 100 / bobClaim,
            55,
            "the idle window does not keep the outgoing rate"
        );
    }

    function test_fork_live_syncBulkBanksTheOutgoingRate()
        public
    {
        _activate();

        _depositAs(
            alice,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + 90 days
        );

        address[] memory holders = new address[](1);
        holders[0] = alice;

        vm.prank(
            MASTER
        );

        InterestAdminFacet(DIAMOND).syncInterestBulk(
            holders
        );

        vm.prank(
            MASTER
        );

        AdminFacet(DIAMOND).setInterestRate(
            2_000
        );

        uint256 usdBefore = IERC20(USDC).balanceOf(
            alice
        );

        vm.prank(
            alice
        );

        UserFacet(DIAMOND).claimInterest();

        uint256 claimed = IERC20(USDC).balanceOf(alice) - usdBefore;

        uint256 outgoingRateWindow = 1_000 * 1e6 * 4_000 * 90 days / (10_000 * YEAR);

        assertGt(
            claimed,
            outgoingRateWindow * 95 / 100,
            "syncInterestBulk banked the 90 day window at the outgoing rate"
        );
    }

    function test_fork_live_compoundViaFulfillBulkSpendsInterestNotWallet()
        public
    {
        _activate();

        _depositAs(
            bob,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + YEAR
        );

        _depositAs(
            alice,
            200 * 1e6
        );

        vm.prank(
            alice
        );

        QueueJoinLeaveFacet(DIAMOND).joinQue(
            200 * 1e6,
            500
        );

        (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = WiseSovrenNodesQueueUIHelper(DIAMOND).solveForAmount(
            200 * 1e6
        );

        uint256 bobUsdBefore = IERC20(USDC).balanceOf(
            bob
        );

        uint256 bobSharesBefore = diamond.balanceOf(
            bob
        );

        vm.prank(
            bob
        );

        (
            uint256 gotTokens,
            uint256 paidUsd
        ) = QueueFulfillFacet(DIAMOND).compoundInterestViaFulfillBulk(
            incentives,
            orders,
            partials,
            0,
            200 * 1e6,
            190 * 1e6
        );

        assertEq(
            gotTokens,
            200 * 1e6,
            "the compound leg bought the full order from the queue"
        );

        assertEq(
            paidUsd,
            190 * 1e6,
            "the queue purchase cost the discounted price"
        );

        assertEq(
            IERC20(USDC).balanceOf(bob),
            bobUsdBefore,
            "the purchase was funded from interest, not the wallet"
        );

        assertGt(
            diamond.balanceOf(bob) - bobSharesBefore,
            200 * 1e6,
            "shares grew by the purchase plus the compounded remainder"
        );
    }

    function test_fork_live_premiumLadderFullyArmedAndPriced()
        public
    {
        int256[9] memory discountTiers = [
            int256(5_000),
            2_500,
            1_500,
            1_000,
            500,
            300,
            200,
            100,
            0
        ];

        for (uint256 i; i < discountTiers.length; ++i) {
            assertTrue(
                _laneAllowed(discountTiers[i]),
                "every kept discount tier is open on the live vault"
            );
        }

        for (int256 i = 1; i <= 245; ++i) {
            int256 lane = -2_000 * i;

            assertTrue(
                _laneAllowed(lane),
                "every premium rung of the compiled ladder is open"
            );

            assertEq(
                WiseSovrenNodesQueueUIHelper(DIAMOND).predictDiscountedAmount(
                    100 * 1e6,
                    lane
                ),
                uint256(100 * 1e6 * (10_000 + 2_000 * i)) / 10_000,
                "rung i prices at exactly 1 + i/5 times face"
            );
        }

        assertFalse(
            _laneAllowed(-492_000),
            "one step past the 50x end of the ladder is closed"
        );

        assertFalse(
            _laneAllowed(-2_001),
            "off-step premium values are closed"
        );

        assertFalse(
            _laneAllowed(-1_999),
            "off-step premium values are closed on both sides"
        );

        int256[8] memory retiredTiers = [
            int256(-100),
            -200,
            -300,
            -500,
            -1_000,
            -1_500,
            -2_500,
            -5_000
        ];

        for (uint256 i; i < retiredTiers.length; ++i) {
            assertFalse(
                _laneAllowed(retiredTiers[i]),
                "the retired telecom premium tiers stay closed"
            );
        }
    }

    function _laneAllowed(
        int256 _lane
    )
        internal
        view
        returns (bool allowed)
    {
        (
            bool ok,
            bytes memory data
        ) = DIAMOND.staticcall(
            abi.encodeWithSignature(
                "incentiveAllowed(int256)",
                _lane
            )
        );

        assertTrue(
            ok,
            "incentiveAllowed is routed on the live diamond"
        );

        allowed = abi.decode(
            data,
            (bool)
        );
    }

    function _activate()
        internal
    {
        vm.startPrank(
            MASTER
        );

        if (diamond.initialized() == false) {
            diamond.finalizeSetup();
        }

        if (diamond.depositsDisabled()) {
            AdminFacet(DIAMOND).setDepositsDisabled(
                false
            );
        }

        vm.stopPrank();

        deal(
            USDC,
            DIAMOND,
            10_000_000 * 1e6
        );
    }

    function _fund(
        address _user,
        uint256 _amount
    )
        internal
    {
        deal(
            USDC,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        IERC20(USDC).approve(
            DIAMOND,
            type(uint256).max
        );
    }

    function _depositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        _fund(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(DIAMOND).deposit(
            _amount
        );
    }
}
