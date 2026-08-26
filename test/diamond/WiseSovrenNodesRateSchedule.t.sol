// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";

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
 * @dev Covers the product's rate schedule: launch at forty percent,
 * then a cut to twenty by a plain master `setInterestRate` call -
 * deliberately no further machinery.
 *
 * The property worth pinning is what that plain call does to accrual
 * nobody has banked yet. The rate carries no per-holder checkpoint,
 * so an un-banked window is priced at whatever rate is current when
 * it banks: after the cut, an idle holder's whole open window
 * computes at twenty percent, including the months it sat at forty.
 * Holders who claim, compound or transfer along the way bank at the
 * rate of the day as they go. When the outgoing-rate window should
 * be preserved for idle holders too, running `syncInterestBulk`
 * before the cut banks it first. Both behaviours are pinned so the
 * operational choice at cut time is made knowingly, and the sweep
 * buffer is checked to hold at the launch rate, since it only ever
 * ratchets up.
 */
contract WiseSovrenNodesRateScheduleTest is DiamondTestHarness {

    uint256 internal constant LAUNCH_RATE = 4000;
    uint256 internal constant DEGRADED_RATE = 2000;
    uint256 internal constant PRINCIPAL = 10_000 * 1e6;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant HALF_YEAR = SECONDS_IN_YEAR / 2;

    address internal alice = address(0xA1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _deployDiamondAtRate(
            address(usd),
            LAUNCH_RATE
        );

        AdminFacet(address(diamond)).mintSupply(
            alice,
            PRINCIPAL
        );
    }

    function _sync(
        address _user
    )
        internal
    {
        address[] memory users = new address[](1);
        users[0] = _user;

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            users
        );
    }

    function test_genesis_launchRate_isFortyPercent()
        public
        view
    {
        assertEq(diamond.interestRate(), LAUNCH_RATE);
        assertEq(diamond.bufferInterestRate(), LAUNCH_RATE);
    }

    function test_accrual_atLaunchRate_isFortyPercentPerYear()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * LAUNCH_RATE / 10_000
        );
    }

    function test_masterCut_isOnePlainCall()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            DEGRADED_RATE
        );

        assertEq(diamond.interestRate(), DEGRADED_RATE);
        assertEq(diamond.bufferInterestRate(), LAUNCH_RATE);
    }

    function test_plainCut_repricesUnbankedWindowAtNewRate()
        public
    {
        vm.warp(
            block.timestamp + HALF_YEAR
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * LAUNCH_RATE / 2 / 10_000
        );

        AdminFacet(address(diamond)).setInterestRate(
            DEGRADED_RATE
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * DEGRADED_RATE / 2 / 10_000
        );
    }

    function test_syncBeforeCut_banksTheOldRateWindow()
        public
    {
        vm.warp(
            block.timestamp + HALF_YEAR
        );

        _sync(
            alice
        );

        AdminFacet(address(diamond)).setInterestRate(
            DEGRADED_RATE
        );

        uint256 bankedAtLaunchRate = PRINCIPAL * LAUNCH_RATE / 2 / 10_000;

        assertEq(diamond.cashedInterest(alice), bankedAtLaunchRate);
        assertEq(diamond.getPendingInterest(alice), 0);

        vm.warp(
            block.timestamp + HALF_YEAR
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * DEGRADED_RATE / 2 / 10_000
        );

        assertEq(
            diamond.getTotalInterestUser(alice),
            bankedAtLaunchRate
                + PRINCIPAL * DEGRADED_RATE / 2 / 10_000
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            bankedAtLaunchRate
        );
    }

    function test_selfBanking_beforeCut_alsoPreservesTheWindow()
        public
    {
        vm.warp(
            block.timestamp + HALF_YEAR
        );

        vm.prank(alice);
        diamond.transfer(
            address(0xA2),
            1
        );

        AdminFacet(address(diamond)).setInterestRate(
            DEGRADED_RATE
        );

        assertEq(
            diamond.cashedInterest(alice),
            PRINCIPAL * LAUNCH_RATE / 2 / 10_000
        );
    }
}
