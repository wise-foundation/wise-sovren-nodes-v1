// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

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
 * @dev Covers the zero-rate capability and the transition out of
 * it: a vault deployed at a zero rate pays nothing until master
 * turns accrual on with `setInterestRate`.
 *
 * Two properties carry the suite. First, while `interestRate` is
 * zero, pending interest is identically zero for every holder and
 * every elapsed time, so no claim or compound path can succeed on
 * accrual alone. Second, `setInterestRate` writes no accrual
 * checkpoint: accrual is measured from each holder's own
 * `lastSyncTimeStamp`, so flipping the rate on a holder who has not
 * been touched since the zero-rate phase pays the new rate all the
 * way back to that stamp. That hazard is pinned here deliberately,
 * next to the runbook test proving the fix, because whether accrual
 * starts at the flip or reaches back depends on whether the operator
 * restamps holders, not on any property of the rate setter
 * itself.
 */
contract WiseSovrenNodesZeroRateLaunchTest is DiamondTestHarness {

    event BufferInterestRateRaised(
        uint256 newBufferInterestRate
    );

    uint256 internal constant PRINCIPAL = 10_000 * 1e6;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant FLIP_RATE = 2000;

    address internal alice = address(0xA1);
    address internal bob = address(0xA2);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _deployDiamondWithQueueAtRate(
            address(usd),
            0
        );

        AdminFacet(address(diamond)).mintSupply(
            alice,
            PRINCIPAL
        );

        AdminFacet(address(diamond)).mintSupply(
            bob,
            PRINCIPAL
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );
    }

    // ---- the zero-rate phase accrues nothing ----

    function test_genesis_zeroRate_ratesAreZero()
        public
        view
    {
        assertEq(diamond.interestRate(), 0);
        assertEq(diamond.bufferInterestRate(), 0);
    }

    function test_getPendingInterest_zeroRate_staysZeroAcrossYears()
        public
    {
        vm.warp(
            block.timestamp + 5 * SECONDS_IN_YEAR
        );

        assertEq(diamond.getPendingInterest(alice), 0);
        assertEq(diamond.getPendingInterest(bob), 0);
        assertEq(diamond.getTotalInterestUser(alice), 0);
    }

    function test_transfer_zeroRate_banksNothingAndRestamps()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(alice);
        diamond.transfer(
            bob,
            1
        );

        assertEq(diamond.cashedInterest(alice), 0);
        assertEq(diamond.lastSyncTimeStamp(alice), block.timestamp);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 0);
    }

    function test_claimInterest_zeroRate_reverts()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        vm.prank(alice);
        UserFacet(address(diamond)).claimInterest();
    }

    function test_compoundInterest_zeroRate_reverts()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        vm.prank(alice);
        UserFacet(address(diamond)).compoundInterest();
    }

    function test_joinQue_zeroRate_works()
        public
    {
        vm.prank(alice);
        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        assertEq(diamond.totalActiveOrders(), 1);
    }

    // ---- the sweep reserve during the zero-rate phase ----

    function test_getOverhang_zeroRate_reservesOnlySettledInterest()
        public
    {
        uint256 vaultBalance = usd.balanceOf(
            address(diamond)
        );

        InterestAdminFacet(address(diamond)).setCashedInterest(
            alice,
            500 * 1e6
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            vaultBalance - 500 * 1e6
        );
    }

    // ---- turning accrual on ----

    function test_setInterestRate_flip_raisesBufferRate()
        public
    {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit BufferInterestRateRaised(
            FLIP_RATE
        );

        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        assertEq(diamond.interestRate(), FLIP_RATE);
        assertEq(diamond.bufferInterestRate(), FLIP_RATE);
    }

    function test_setInterestRate_flipWithoutSync_accruesRetroactively()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_setInterestRate_flipAfterSync_accruesFromFlip()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        AdminFacet(address(diamond)).mintSupply(
            alice,
            0
        );

        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        assertEq(diamond.getPendingInterest(alice), 0);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_claimInterest_afterFlip_paysAccrual()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expected = PRINCIPAL * FLIP_RATE / 10_000;

        vm.prank(alice);
        UserFacet(address(diamond)).claimInterest();

        assertEq(usd.balanceOf(alice), expected);
        assertEq(diamond.cashedInterest(alice), 0);
    }

    function testFuzz_zeroRate_pendingAlwaysZero(
        uint256 _elapsed,
        uint256 _amount
    )
        public
    {
        uint256 elapsed = bound(
            _elapsed,
            0,
            50 * SECONDS_IN_YEAR
        );

        uint256 amount = bound(
            _amount,
            1,
            1_000_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            address(0xB0B),
            amount
        );

        vm.warp(
            block.timestamp + elapsed
        );

        assertEq(diamond.getPendingInterest(address(0xB0B)), 0);
    }
}
