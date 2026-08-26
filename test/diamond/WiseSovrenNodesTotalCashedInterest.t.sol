// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";

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
 * @dev INT-7 lockstep suite: `totalCashedInterest` must equal the
 * sum of every user's `cashedInterest` bucket after every mutation
 * path - accrual, full claim, exact-amount claim, partial claim
 * plus compound, compound (direct, via queue fulfillment),
 * user-to-user interest moves (net-zero), and ERC20 transfer
 * accrual of both parties. Every mutation also emits
 * `TotalCashedInterestChanged` with the new running total.
 */
contract WiseSovrenNodesTotalCashedInterestTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address comp = address(0xC0FFEE);

    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant PRECISION_RATE = 10_000;

    event TotalCashedInterestChanged(
        uint256 totalCashedInterest
    );

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

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );
    }

    function _total()
        internal
        view
        returns (uint256)
    {
        return CashedInterestFacet(address(diamond)).getTotalCashedInterest();
    }

    function _accrue(
        address _user,
        uint256 _warpSeconds
    )
        internal
        returns (uint256)
    {
        vm.warp(
            block.timestamp + _warpSeconds
        );

        return _trigger(
            _user
        );
    }

    function _trigger(
        address _user
    )
        internal
        returns (uint256)
    {
        vm.prank(
            address(diamond)
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            _user
        );

        return diamond.cashedInterest(
            _user
        );
    }

    function _expectTotalChanged(
        uint256 _newTotal
    )
        internal
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(diamond)
        );

        emit TotalCashedInterestChanged(
            _newTotal
        );
    }

    // ---- 1. getter starts at zero ----

    function test_totalCashedInterest_startsAtZero()
        public
        view
    {
        assertEq(
            _total(),
            0
        );
    }

    // ---- 2. accrual adds exactly the banked pending, per user ----

    function test_assignInterest_addsExactPending_perUserAndGlobal()
        public
    {
        uint256 principal1 = 1_000 * 1e6;
        uint256 principal2 = 3_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal1
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            principal2
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 pending1 = principal1
            * INTEREST_RATE
            / PRECISION_RATE;

        uint256 pending2 = principal2
            * INTEREST_RATE
            / PRECISION_RATE;

        _expectTotalChanged(
            pending1
        );

        uint256 cashed1 = _trigger(
            user1
        );

        assertEq(
            cashed1,
            pending1
        );

        assertEq(
            _total(),
            pending1
        );

        _expectTotalChanged(
            pending1 + pending2
        );

        uint256 cashed2 = _trigger(
            user2
        );

        assertEq(
            cashed2,
            pending2
        );

        assertEq(
            _total(),
            cashed1 + cashed2
        );
    }

    // ---- 3. zero-pending accrual leaves the global untouched ----

    function test_assignInterest_zeroPending_noGlobalChange()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        uint256 cashed = _accrue(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 totalBefore = _total();

        assertEq(
            totalBefore,
            cashed
        );

        _trigger(
            user1
        );

        assertEq(
            _total(),
            totalBefore
        );
    }

    // ---- 4. full claim subtracts exactly the zeroed bucket ----

    function test_claimInterest_fullClaim_subtractsExactly()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            3_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 cashed1 = _trigger(
            user1
        );

        uint256 cashed2 = _trigger(
            user2
        );

        _expectTotalChanged(
            cashed2
        );

        vm.prank(
            user1
        );

        uint256 claimed = UserFacet(address(diamond)).claimInterest();

        assertEq(
            claimed,
            cashed1
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            _total(),
            cashed2
        );
    }

    // ---- 5. exact-amount claim subtracts only the amount ----

    function test_claimInterestExactAmount_subtractsAmountOnly()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        uint256 cashed = _accrue(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 amount = 50 * 1e6;

        _expectTotalChanged(
            cashed - amount
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterestExactAmount(
            amount
        );

        assertEq(
            diamond.cashedInterest(user1),
            cashed - amount
        );

        assertEq(
            _total(),
            cashed - amount
        );
    }

    // ---- 6. partial claim + compound hits both decrement sites ----

    function test_claimInterestPartiallyAndCompound_hitsBothDecrements()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        uint256 cashed = _accrue(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 amount = 60 * 1e6;

        uint256 balanceBefore = diamond.balanceOf(
            user1
        );

        _expectTotalChanged(
            cashed - amount
        );

        _expectTotalChanged(
            0
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterestPartiallyAndCompound(
            amount
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            _total(),
            0
        );

        assertEq(
            usd.balanceOf(user1),
            amount
        );

        assertEq(
            diamond.balanceOf(user1),
            balanceBefore + cashed - amount
        );
    }

    // ---- 7. compound zeroes user and global ----

    function test_compoundInterest_zeroesUserAndGlobal()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        uint256 cashed = _accrue(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 balanceBefore = diamond.balanceOf(
            user1
        );

        _expectTotalChanged(
            0
        );

        vm.prank(
            user1
        );

        uint256 compounded = UserFacet(address(diamond)).compoundInterest();

        assertEq(
            compounded,
            cashed
        );

        assertEq(
            diamond.balanceOf(user1),
            balanceBefore + cashed
        );

        assertEq(
            _total(),
            0
        );
    }

    // ---- 9. moving interest between users never changes the global ----

    function test_moveMyInterestTo_globalUnchanged()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            3_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 cashed1 = _trigger(
            user1
        );

        uint256 cashed2 = _trigger(
            user2
        );

        uint256 totalBefore = _total();

        uint256 moveAmount = 50 * 1e6;

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            moveAmount,
            user2,
            false
        );

        assertEq(
            diamond.cashedInterest(user1),
            cashed1 - moveAmount
        );

        assertEq(
            diamond.cashedInterest(user2),
            cashed2 + moveAmount
        );

        assertEq(
            _total(),
            totalBefore
        );
    }

    // ---- 10. transfer banks both parties, global tracks the sum ----

    function test_transfer_accruesBothParties_globalTracksSum()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            500 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 pending1 = 1_000 * 1e6
            * INTEREST_RATE
            / PRECISION_RATE;

        uint256 pending2 = 500 * 1e6
            * INTEREST_RATE
            / PRECISION_RATE;

        vm.prank(
            user1
        );

        IERC20(address(diamond)).transfer(
            user2,
            100 * 1e6
        );

        assertEq(
            diamond.cashedInterest(user1),
            pending1
        );

        assertEq(
            diamond.cashedInterest(user2),
            pending2
        );

        assertEq(
            _total(),
            pending1 + pending2
        );
    }

    // ---- 11. transferFrom banks both parties, not the spender ----

    function test_transferFrom_accruesBothParties_globalTracksSum()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        IERC20(address(diamond)).approve(
            user3,
            type(uint256).max
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 pending1 = 1_000 * 1e6
            * INTEREST_RATE
            / PRECISION_RATE;

        uint256 pending2 = 500 * 1e6
            * INTEREST_RATE
            / PRECISION_RATE;

        vm.prank(
            user3
        );

        IERC20(address(diamond)).transferFrom(
            user1,
            user2,
            100 * 1e6
        );

        assertEq(
            diamond.cashedInterest(user3),
            0
        );

        assertEq(
            _total(),
            pending1 + pending2
        );
    }

    // ---- 13. queue compound-via-fulfill: debit + remainder compound ----

    function test_compoundInterestViaFulfillBulk_lockstep_partialRemainder()
        public
    {
        uint256 interest = _setupQueueCompound(
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

        uint256 cashedJoin1 = diamond.cashedInterest(
            user1
        );

        uint256 cashedJoin2 = diamond.cashedInterest(
            user2
        );

        (
            ,
            uint256 spent
        ) = _bulkCompound(
            id1,
            id2
        );

        assertEq(
            spent,
            250 * 1e6
        );

        assertLt(
            spent,
            interest
        );

        assertEq(
            diamond.cashedInterest(comp),
            0
        );

        assertEq(
            _total(),
            cashedJoin1 + cashedJoin2
        );
    }

    // ---- 14. queue compound-via-fulfill: exact spend, no remainder ----

    function test_compoundInterestViaFulfillBulk_lockstep_exactNoRemainder()
        public
    {
        uint256 interest = _setupQueueCompound(
            10_000 * 1e6
        );

        uint256 id1 = _join(
            user1,
            interest,
            0
        );

        uint256 cashedJoin1 = diamond.cashedInterest(
            user1
        );

        (
            ,
            uint256 spent
        ) = _bulkCompoundSingle(
            id1
        );

        assertEq(
            spent,
            interest
        );

        assertEq(
            diamond.cashedInterest(comp),
            0
        );

        assertEq(
            _total(),
            cashedJoin1
        );
    }

    function _setupQueueCompound(
        uint256 _principal
    )
        internal
        returns (uint256 interest)
    {
        AdminFacet(address(diamond)).mintSupply(
            comp,
            _principal
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            10_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            10_000 * 1e6
        );

        vm.prank(
            user1
        );

        IERC20(address(diamond)).approve(
            address(diamond),
            type(uint256).max
        );

        vm.prank(
            user2
        );

        IERC20(address(diamond)).approve(
            address(diamond),
            type(uint256).max
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        interest = _principal
            * INTEREST_RATE
            / PRECISION_RATE;
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _amount,
            _incentive
        );
    }

    function _bulkCompound(
        uint256 _id1,
        uint256 _id2
    )
        internal
        returns (
            uint256 received,
            uint256 spent
        )
    {
        int256[] memory incs = new int256[](2);
        incs[0] = 0;
        incs[1] = 0;

        uint256[] memory orders = new uint256[](2);
        orders[0] = _id1;
        orders[1] = _id2;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        (
            received,
            spent
        ) = QueueFulfillFacet(address(diamond)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function _bulkCompoundSingle(
        uint256 _id
    )
        internal
        returns (
            uint256 received,
            uint256 spent
        )
    {
        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = _id;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        (
            received,
            spent
        ) = QueueFulfillFacet(address(diamond)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }
}
