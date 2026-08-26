// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
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
 * @dev Exercises {InterestAdminFacet}. The load-bearing properties:
 * every set keeps `totalCashedInterest` in lockstep with the delta
 * in both directions (INT-7 and the sweep-buffer reservation), the
 * two-call rescue flow nets the accumulator to zero, a granted
 * bucket is genuinely claimable, the setter touches only the
 * settled bucket (pending accrual survives a zero-out), and the
 * master/latch/address gates reject.
 */
contract WiseSovrenNodesInterestAdminFacetTest is DiamondTestHarness {

    event CashedInterestSet(
        address indexed user,
        uint256 previousAmount,
        uint256 newAmount
    );

    uint256 internal constant PRINCIPAL = 10_000 * 1e6;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;

    address internal lostWallet = address(0xA1);
    address internal newWallet = address(0xA2);
    address internal stranger = address(0xBEEF);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        diamond.finalizeSetup();

        AdminFacet(address(diamond)).mintSupply(
            lostWallet,
            PRINCIPAL
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );
    }

    function _set(
        address _user,
        uint256 _amount
    )
        internal
    {
        InterestAdminFacet(address(diamond)).setCashedInterest(
            _user,
            _amount
        );
    }

    function _total()
        internal
        view
        returns (uint256)
    {
        return CashedInterestFacet(address(diamond)).getTotalCashedInterest();
    }

    function _bankPendingOf(
        address _user
    )
        internal
    {
        vm.prank(
            _user
        );

        diamond.transfer(
            _user,
            1
        );
    }

    function test_set_increase_movesAccumulatorUp()
        public
    {
        uint256 totalBefore = _total();

        _set(
            newWallet,
            500 * 1e6
        );

        assertEq(
            diamond.cashedInterest(newWallet),
            500 * 1e6
        );

        assertEq(
            _total(),
            totalBefore + 500 * 1e6
        );
    }

    function test_set_decrease_movesAccumulatorDown()
        public
    {
        _set(
            newWallet,
            500 * 1e6
        );

        uint256 totalBefore = _total();

        _set(
            newWallet,
            200 * 1e6
        );

        assertEq(
            diamond.cashedInterest(newWallet),
            200 * 1e6
        );

        assertEq(
            _total(),
            totalBefore - 300 * 1e6
        );
    }

    function test_rescueFlow_netsAccumulatorToZero()
        public
    {
        _bankPendingOf(
            lostWallet
        );

        uint256 frozen = diamond.cashedInterest(
            lostWallet
        );

        assertGt(
            frozen,
            0
        );

        uint256 totalBefore = _total();

        _set(
            lostWallet,
            0
        );

        _set(
            newWallet,
            frozen
        );

        assertEq(
            diamond.cashedInterest(lostWallet),
            0
        );

        assertEq(
            diamond.cashedInterest(newWallet),
            frozen
        );

        assertEq(
            _total(),
            totalBefore,
            "two-call rescue must net the accumulator to zero"
        );
    }

    function test_set_grantIsClaimable()
        public
    {
        _set(
            newWallet,
            777 * 1e6
        );

        vm.prank(
            newWallet
        );

        uint256 paid = UserFacet(address(diamond)).claimInterest();

        assertEq(
            paid,
            777 * 1e6
        );

        assertEq(
            usd.balanceOf(newWallet),
            777 * 1e6
        );
    }

    function test_set_touchesOnlySettledBucket()
        public
    {
        uint256 pendingBefore = diamond.getTotalInterestUser(
            lostWallet
        );

        assertGt(
            pendingBefore,
            0
        );

        _set(
            lostWallet,
            0
        );

        assertEq(
            diamond.cashedInterest(lostWallet),
            0
        );

        assertEq(
            diamond.getTotalInterestUser(lostWallet),
            pendingBefore,
            "unbanked pending accrual must survive a zero-out"
        );
    }

    function test_set_emitsBothEvents()
        public
    {
        _set(
            newWallet,
            100 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit CashedInterestSet(
            newWallet,
            100 * 1e6,
            40 * 1e6
        );

        _set(
            newWallet,
            40 * 1e6
        );
    }

    function test_set_zeroOrDiamondAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _set(
            address(0),
            1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _set(
            address(diamond),
            1
        );
    }

    function test_set_nonMaster_reverts()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _set(
            newWallet,
            1
        );
    }

    function test_set_latchThrown_reverts()
        public
    {
        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SupplyChangeNotAllowed.selector
        );

        _set(
            newWallet,
            1
        );
    }

    function testFuzz_set_lockstepBothDirections(
        uint256 _first,
        uint256 _second
    )
        public
    {
        _first = bound(
            _first,
            0,
            1_000_000 * 1e6
        );

        _second = bound(
            _second,
            0,
            1_000_000 * 1e6
        );

        uint256 totalBefore = _total();

        _set(
            newWallet,
            _first
        );

        assertEq(
            _total(),
            totalBefore + _first
        );

        _set(
            newWallet,
            _second
        );

        assertEq(
            _total(),
            totalBefore + _second
        );

        assertEq(
            diamond.cashedInterest(newWallet),
            _second
        );
    }
}
