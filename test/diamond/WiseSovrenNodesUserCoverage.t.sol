// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";

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
        public
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Coverage suite driving the WiseSovrenNodes diamond user /
 * interest surface: {UserFacet}, {WiseSovrenNodesInterestHelper},
 * {WiseSovrenNodesHelper} and {WiseSovrenNodesBufferHelper}. Ported from
 * the legacy {ForwardVaultERC20} blueprint but routed through the
 * facet casts on the deployed diamond, with the test contract as
 * master.
 */
contract WiseSovrenNodesUserCoverageTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address attacker = address(0xBEEF);
    address proxy = address(0xC0DE);

    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant SECONDS_IN_TWO_WEEKS = 14 days;
    uint256 constant PRECISION = 10_000;
    uint256 constant PRECISION_FACTOR_E18 = 1e18;

    event InterestMoved(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event Deposited(
        address indexed user,
        uint256 amount
    );

    event ClaimInterestSimple(
        address indexed user,
        uint256 interest
    );

    event CompoundInterest(
        address indexed user,
        uint256 interest
    );

    event ClaimInterestExactAmount(
        address indexed user,
        uint256 amount
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployDiamond(
            address(usd)
        );

        proxy = address(diamond);

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );
    }

    // ---- helpers ----

    function _setupUser(
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        IERC20(address(usd)).approve(
            address(diamond),
            type(uint256).max
        );
    }

    function _accrueRealInterest(
        address _user,
        uint256 _principal
    )
        internal
        returns (uint256)
    {
        AdminFacet(address(diamond)).mintSupply(
            _user,
            _principal
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            proxy
        );

        AdminFacet(address(diamond)).setProxyBenefactor(
            _user
        );

        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            proxy
        );

        return diamond.cashedInterest(
            _user
        );
    }

    function _expectedBuffer(
        uint256 _principal,
        uint256 _rate
    )
        internal
        pure
        returns (uint256)
    {
        if (_principal == 0) {
            return 0;
        }

        uint256 yearFactor = SECONDS_IN_TWO_WEEKS
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        return _principal
            * _rate
            * yearFactor
            / PRECISION
            / PRECISION_FACTOR_E18;
    }

    // ---- Deposits ----

    function test_deposit_transfersAndMints_emits()
        public
    {
        _setupUser(
            user1,
            1_000 * 1e6
        );

        uint256 before3rd = usd.balanceOf(
            thirdPty
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit Deposited(
            user1,
            100 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            100 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            100 * 1e6
        );

        assertEq(
            usd.balanceOf(thirdPty),
            before3rd + 100 * 1e6
        );

        assertEq(
            diamond.lastSyncTimeStamp(user1),
            block.timestamp
        );
    }

    function test_deposit_zeroReverts()
        public
    {
        _setupUser(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        UserFacet(address(diamond)).deposit(
            0
        );
    }

    function test_deposit_overCapReverts()
        public
    {
        AdminFacet(address(diamond)).setTotalDepositCap(
            100 * 1e6
        );

        _setupUser(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        UserFacet(address(diamond)).deposit(
            101 * 1e6
        );
    }

    function test_deposit_whenPausedReverts()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        _setupUser(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        UserFacet(address(diamond)).deposit(
            1
        );
    }

    // ---- Pending / Total Interest Views ----

    function test_pendingInterest_zeroBalance_returnsZero()
        public
        view
    {
        assertEq(
            diamond.getPendingInterest(user1),
            0
        );
    }

    function test_pendingInterest_basic()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expected = (1_000 * 1e6)
            * INTEREST_RATE
            / PRECISION;

        assertApproxEqAbs(
            diamond.getPendingInterest(user1),
            expected,
            10
        );
    }

    function test_pendingInterest_proxyReturnsZero()
        public
    {
        assertEq(
            diamond.getPendingInterest(proxy),
            0
        );
    }

    function test_pendingInterest_timestampBeforeSyncReturnsZero()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000
        );

        uint256 syncAt = diamond.lastSyncTimeStamp(
            user1
        );

        assertEq(
            diamond.getPendingInterestByTimeStamp(user1, syncAt),
            0
        );
    }

    function test_pendingInterest_includesProxyBalance()
        public
    {
        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).increaseProxyBalance(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            1
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expected = (1 + 1_000 * 1e6)
            * INTEREST_RATE
            / PRECISION;

        assertApproxEqAbs(
            diamond.getPendingInterest(user1),
            expected,
            100
        );
    }

    function test_getPendingInterestBulk_returnsArray()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            2_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory r = diamond.getPendingInterestBulk(
            users
        );

        assertEq(
            r.length,
            2
        );

        assertGt(
            r[0],
            0
        );

        assertGt(
            r[1],
            r[0]
        );
    }

    function test_getPendingInterestBulkByTimeStamp_returnsArray()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            2_000 * 1e6
        );

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256 at = block.timestamp + SECONDS_IN_YEAR;

        uint256[] memory r = diamond.getPendingInterestBulkByTimeStamp(
            users,
            at
        );

        assertEq(
            r.length,
            2
        );

        assertGt(
            r[0],
            0
        );

        assertGt(
            r[1],
            0
        );
    }

    function test_getTotalInterestUser_includesCashed()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        assertGt(
            cached,
            0
        );

        assertEq(
            diamond.getPendingInterest(user1),
            0
        );

        assertEq(
            diamond.getTotalInterestUser(user1),
            cached
        );
    }

    function test_getTotalInterestUserByTimeStamp_addsPending()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        uint256 at = block.timestamp + SECONDS_IN_YEAR;

        assertGt(
            diamond.getTotalInterestUserByTimeStamp(user1, at),
            0
        );
    }

    function test_getTotalInterestUserBulk_andByTimeStamp()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user2,
            1_500 * 1e6
        );

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory now1 = diamond.getTotalInterestUserBulk(
            users
        );

        uint256[] memory then1 = diamond.getTotalInterestUserBulkByTimeStamp(
            users,
            block.timestamp + SECONDS_IN_YEAR
        );

        assertEq(
            now1.length,
            2
        );

        assertEq(
            then1.length,
            2
        );

        assertEq(
            now1[0],
            0
        );

        assertGt(
            then1[0],
            0
        );
    }

    // ---- assignInterest Modifier Behaviour ----

    function test_assignInterest_proxyAssignsToBenefactor()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            100 * 1e6
        );

        vm.prank(
            proxy
        );

        AdminFacet(address(diamond)).setProxyBenefactor(
            user1
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR / 2
        );

        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            proxy
        );

        assertEq(
            diamond.lastSyncTimeStamp(user1),
            block.timestamp
        );

        assertGt(
            diamond.cashedInterest(user1),
            0
        );
    }

    function test_assignInterest_zeroAddressBenefactor_noop()
        public
    {
        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            proxy
        );

        assertEq(
            diamond.cashedInterest(address(0)),
            0
        );
    }

    function test_assignInterest_benefactorNoPendingInterest_stillSyncs()
        public
    {
        vm.prank(
            proxy
        );

        AdminFacet(address(diamond)).setProxyBenefactor(
            user1
        );

        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            proxy
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            diamond.lastSyncTimeStamp(user1),
            block.timestamp
        );
    }

    // ---- claimInterest Variants ----

    function test_claimInterest_basic_emits_transfers()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        uint256 usdBefore = usd.balanceOf(
            user1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit ClaimInterestSimple(
            user1,
            cached
        );

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).claimInterest();

        assertEq(
            ret,
            cached
        );

        assertEq(
            usd.balanceOf(user1),
            usdBefore + cached
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );
    }

    function test_claimInterest_noInterestReverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        UserFacet(address(diamond)).claimInterest();
    }

    function test_claimInterest_whenPausedReverts()
        public
    {
        _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).pauseDeposits();

        vm.prank(
            user1
        );

        vm.expectRevert();

        UserFacet(address(diamond)).claimInterest();
    }

    function test_claimInterestExactAmount_basic()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        uint256 toClaim = cached / 2;

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit ClaimInterestExactAmount(
            user1,
            toClaim
        );

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).claimInterestExactAmount(
            toClaim
        );

        assertEq(
            ret,
            toClaim
        );

        assertEq(
            diamond.cashedInterest(user1),
            cached - toClaim
        );
    }

    function test_claimInterestExactAmount_zeroReverts()
        public
    {
        _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        UserFacet(address(diamond)).claimInterestExactAmount(
            0
        );
    }

    function test_claimInterestExactAmount_insufficientReverts()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientInterest.selector
        );

        UserFacet(address(diamond)).claimInterestExactAmount(
            cached + 1
        );
    }

    function test_claimInterestPartiallyAndCompound_combines()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        uint256 part = cached / 4;

        uint256 supplyBefore = diamond.totalSupply();
        uint256 vaultBalanceBefore = diamond.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).claimInterestPartiallyAndCompound(
            part
        );

        assertGt(
            ret,
            part
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertGt(
            diamond.totalSupply(),
            supplyBefore
        );

        assertGt(
            diamond.balanceOf(user1),
            vaultBalanceBefore
        );
    }

    // ---- compoundInterest Variants ----

    function test_compoundInterest_basic_mintsAndEmits()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        uint256 supplyBefore = diamond.totalSupply();
        uint256 userBalanceBefore = diamond.balanceOf(
            user1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit CompoundInterest(
            user1,
            cached
        );

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).compoundInterest();

        assertEq(
            ret,
            cached
        );

        assertEq(
            diamond.balanceOf(user1),
            userBalanceBefore + cached
        );

        assertEq(
            diamond.totalSupply(),
            supplyBefore + cached
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );
    }

    function test_compoundInterest_noInterestReverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        UserFacet(address(diamond)).compoundInterest();
    }

    function test_compoundInterest_overCapReverts()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            diamond.totalSupply() + cached - 1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        UserFacet(address(diamond)).compoundInterest();
    }

    // ---- depositAndClaim / depositAndCompound ----

    function test_depositAndClaimInterest_combined()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        _setupUser(
            user1,
            500 * 1e6
        );

        uint256 usdBefore = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).depositAndClaimInterest(
            100 * 1e6
        );

        assertGt(
            ret,
            0
        );

        assertEq(
            usd.balanceOf(user1),
            usdBefore - 100 * 1e6 + ret
        );

        assertGe(
            ret,
            cached
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );
    }

    function test_depositAndCompoundInterest_combined()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        _setupUser(
            user1,
            500 * 1e6
        );

        uint256 supplyBefore = diamond.totalSupply();

        vm.prank(
            user1
        );

        uint256 ret = UserFacet(address(diamond)).depositAndCompoundInterest(
            100 * 1e6
        );

        assertGe(
            ret,
            cached
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertGt(
            diamond.totalSupply(),
            supplyBefore + 100 * 1e6
        );
    }

    // ---- ERC20 transfer / transferFrom Overrides ----

    function test_transfer_basic()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        bool ok = diamond.transfer(
            user2,
            200 * 1e6
        );

        assertTrue(
            ok
        );

        assertEq(
            diamond.balanceOf(user1),
            800 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            200 * 1e6
        );
    }

    function test_transfer_zeroReverts()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            100
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        diamond.transfer(
            user2,
            0
        );
    }

    function test_transfer_doesNotMoveInterest()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            500 * 1e6
        );

        assertEq(
            diamond.cashedInterest(user1),
            cached
        );

        assertEq(
            diamond.cashedInterest(user2),
            0
        );
    }

    function test_transferFrom_basic()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            500 * 1e6
        );

        vm.prank(
            user2
        );

        bool ok = diamond.transferFrom(
            user1,
            user3,
            200 * 1e6
        );

        assertTrue(
            ok
        );

        assertEq(
            diamond.balanceOf(user1),
            800 * 1e6
        );

        assertEq(
            diamond.balanceOf(user3),
            200 * 1e6
        );
    }

    function test_transferFrom_zeroReverts()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            100
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            100
        );

        vm.prank(
            user2
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        diamond.transferFrom(
            user1,
            user3,
            0
        );
    }

    function test_transferFrom_doesNotMoveInterest()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            type(uint256).max
        );

        vm.prank(
            user2
        );

        diamond.transferFrom(
            user1,
            user3,
            500 * 1e6
        );

        assertEq(
            diamond.cashedInterest(user1),
            cached
        );

        assertEq(
            diamond.cashedInterest(user3),
            0
        );
    }

    // ---- moveMyInterestTo (Explicit Interest Reassignment) ----

    function test_moveMyInterestTo_all_movesEntireInterest()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            true
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            diamond.cashedInterest(user2),
            cached
        );
    }

    function test_moveMyInterestTo_partial_movesAmount()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        uint256 part = cached / 2;

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            part,
            user2,
            false
        );

        assertEq(
            diamond.cashedInterest(user1),
            cached - part
        );

        assertEq(
            diamond.cashedInterest(user2),
            part
        );
    }

    function test_moveMyInterestTo_banksPendingBeforeMove()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 pending = diamond.getPendingInterest(
            user1
        );

        assertGt(
            pending,
            0
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            true
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            diamond.cashedInterest(user2),
            pending
        );
    }

    function test_moveMyInterestTo_emitsEvent()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true
        );

        emit InterestMoved(
            user1,
            user2,
            cached
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            true
        );
    }

    function test_moveMyInterestTo_selfTarget_isNoop()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user1,
            true
        );

        assertEq(
            diamond.cashedInterest(user1),
            cached
        );
    }

    function test_moveMyInterestTo_zeroTarget_reverts()
        public
    {
        _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            address(0),
            true
        );
    }

    function test_moveMyInterestTo_proxyTarget_reverts()
        public
    {
        _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        address proxyTarget = diamond.InterestRateProxy();

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            proxyTarget,
            true
        );
    }

    function test_moveMyInterestTo_amountExceedsAvailable_reverts()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            cached + 1,
            user2,
            false
        );
    }

    function test_moveMyInterestTo_zeroInterest_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            true
        );
    }

    function test_moveMyInterestTo_partialZeroAmount_reverts()
        public
    {
        _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            false
        );
    }

    function test_moveMyInterestTo_viaMulticall_withTransfer()
        public
    {
        uint256 cached = _accrueRealInterest(
            user1,
            1_000 * 1e6
        );

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            UserFacet.moveMyInterestTo.selector,
            uint256(0),
            user2,
            true
        );

        calls[1] = abi.encodeWithSignature(
            "transfer(address,uint256)",
            user2,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        (
            bool ok,
        ) = address(diamond).call(
            abi.encodeWithSignature(
                "multicall(bytes[])",
                calls
            )
        );

        assertTrue(
            ok
        );

        assertEq(
            diamond.cashedInterest(user2),
            cached
        );

        assertEq(
            diamond.balanceOf(user2),
            500 * 1e6
        );
    }

    // ---- Buffer / Overhang Sweep (WiseSovrenNodesBufferHelper) ----

    function test_getOverhang_zeroSupply_positiveBalance_returnsBalance()
        public
        view
    {
        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            100_000_000 * 1e6
        );
    }

    function test_getOverhang_balanceBelowBuffer_returnsZero()
        public
    {
        WiseSovrenNodesDiamond fresh = _deployDiamond(
            address(usd)
        );

        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(fresh)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(fresh),
            buffer - 1
        );

        assertEq(
            SweepFacet(address(fresh)).getOverhang(),
            0
        );
    }

    function test_getOverhang_balanceAboveBuffer_returnsDiff()
        public
    {
        WiseSovrenNodesDiamond fresh = _deployDiamond(
            address(usd)
        );

        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 7_777 * 1e6;

        AdminFacet(address(fresh)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(fresh),
            buffer + excess
        );

        assertEq(
            SweepFacet(address(fresh)).getOverhang(),
            excess
        );
    }

    function test_sweepOverhang_transfersExcessToWorker()
        public
    {
        WiseSovrenNodesDiamond fresh = _deployDiamond(
            address(usd)
        );

        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 50_000 * 1e6;

        AdminFacet(address(fresh)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(fresh),
            buffer + excess
        );

        uint256 workerBefore = usd.balanceOf(
            worker
        );

        uint256 swept = SweepFacet(address(fresh)).sweepOverhang();

        assertEq(
            swept,
            excess
        );

        assertEq(
            usd.balanceOf(worker),
            workerBefore + excess
        );

        assertEq(
            usd.balanceOf(address(fresh)),
            buffer
        );
    }

    function test_sweepOverhang_revertsWhenNoOverhang()
        public
    {
        WiseSovrenNodesDiamond fresh = _deployDiamond(
            address(usd)
        );

        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(fresh)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(fresh),
            buffer
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(fresh)).sweepOverhang();
    }
}
