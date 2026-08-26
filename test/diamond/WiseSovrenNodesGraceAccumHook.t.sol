// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {GraceAccumHookFacet} from "../../src/diamond/vault/facets/GraceAccumHookFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {FacetNotFound, OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";

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
 * @dev Tests for the swappable split-deposit accumulator hook
 * (`GraceAccumHookFacet`). Installed as `depositHookFacet`, it
 * ships dormant (`depositAccumWindow == 0`) and reproduces the inline
 * single-call grace stamp exactly; once master arms the window,
 * sub-threshold deposits inside the rolling per-user window sum
 * toward `graceThresholdAmount` and stamp the same grace lock a lone
 * large deposit does — closing the split-deposit dodge end to end
 * (interest gate + freeze hook both read the one stamp). Covers the
 * timelocked propose/execute wiring, the never-routed hook selector,
 * dormant byte-equivalence, armed accumulation and window expiry,
 * reset-on-stamp, disarm/uninstall fallbacks and the freeze-hook
 * end-to-end path.
 */
contract WiseSovrenNodesGraceAccumHookTest is DiamondTestHarness {

    event DepositHookFacetSet(
        address depositHookFacet
    );

    event DepositHookFacetProposed(
        address indexed proposedDepositHookFacet,
        uint256 executableAt
    );

    event DepositHookFacetProposalCancelled(
        address indexed cancelledDepositHookFacet
    );

    event DepositAccumWindowSet(
        uint256 depositAccumWindow
    );

    event DepositWindowAccumulated(
        address indexed user,
        uint256 windowTotal,
        uint256 windowEndsAt
    );

    event LargeDepositRegistered(
        address indexed user,
        uint256 balanceIncrease,
        uint256 graceEndsAt
    );

    uint256 internal constant THRESHOLD = 10_000 * 1e6;
    uint256 internal constant GRACE_PERIOD = 45 days;
    uint256 internal constant HOOK_DELAY = 3 days;
    uint256 internal constant ACCUM_WINDOW = 1 days;
    uint256 internal constant MAX_GRACE = 365 days;

    bytes4 internal constant ACCUM_HOOK_SELECTOR = bytes4(
        keccak256("applyDepositAccumHook(address,uint256)")
    );

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal user3 = address(0xA3);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    address internal accumHook;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _deployDiamondWithQueue(
            address(usd)
        );

        accumHook = address(
            new GraceAccumHookFacet()
        );

        _installAccumHook(
            diamond,
            accumHook
        );
    }

    // ---- helpers ----

    function _installAccumHook(
        WiseSovrenNodesDiamond _d,
        address _facet
    )
        internal
    {
        AdminFacet(address(_d)).proposeDepositHookFacet(
            _facet
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(_d)).executeDepositHookFacetChange();
    }

    function _armWindow(
        uint256 _window
    )
        internal
    {
        AdminFacet(address(diamond)).setDepositAccumWindow(
            _window
        );
    }

    function _fundAndApprove(
        WiseSovrenNodesDiamond _d,
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

        usd.approve(
            address(_d),
            _amount
        );
    }

    function _depositAs(
        WiseSovrenNodesDiamond _d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApprove(
            _d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_d)).deposit(
            _amount
        );
    }

    // ---- install + access control ----

    function test_accumHook_installed()
        public
        view
    {
        assertEq(
            diamond.depositHookFacet(),
            accumHook
        );

        assertEq(
            diamond.depositAccumWindow(),
            0
        );
    }

    function test_accumHook_directCall_reverts()
        public
    {
        GraceAccumHookFacet facet = new GraceAccumHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyDepositAccumHook(
            user1,
            THRESHOLD
        );
    }

    function test_accumHookSelector_notCallableThroughDiamond()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                ACCUM_HOOK_SELECTOR,
                user1,
                THRESHOLD
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_accumHookSelector_routedButExternalCallStillGuarded()
        public
    {
        diamond.proposeSelector(
            ACCUM_HOOK_SELECTOR,
            accumHook
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        diamond.executeSelectorChange(
            ACCUM_HOOK_SELECTOR
        );

        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                ACCUM_HOOK_SELECTOR,
                user1,
                THRESHOLD
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        _depositAs(
            diamond,
            user1,
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_proposeDepositHookFacet_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            accumHook
        );
    }

    function test_executeDepositHookFacetChange_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    function test_cancelDepositHookFacetChange_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).cancelDepositHookFacetChange();
    }

    function test_setDepositAccumWindow_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setDepositAccumWindow(
            ACCUM_WINDOW
        );
    }

    function test_proposeDepositHookFacet_directFacetCall_reverts()
        public
    {
        AdminFacet facet = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.proposeDepositHookFacet(
            accumHook
        );
    }

    function test_setDepositAccumWindow_directFacetCall_reverts()
        public
    {
        AdminFacet facet = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.setDepositAccumWindow(
            ACCUM_WINDOW
        );
    }

    // ---- timelock lifecycle ----

    function test_proposeDepositHookFacet_emitsAndQueues()
        public
    {
        address facet = address(
            new GraceAccumHookFacet()
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositHookFacetProposed(
            facet,
            block.timestamp + HOOK_DELAY
        );

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            facet
        );

        assertEq(
            diamond.proposedDepositHookFacet(),
            facet
        );

        assertEq(
            diamond.depositHookChangeQueuedAt(),
            block.timestamp
        );
    }

    function test_executeDepositHookFacetChange_beforeDelay_reverts()
        public
    {
        AdminFacet(address(diamond)).proposeDepositHookFacet(
            address(new GraceAccumHookFacet())
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositHookTimelockNotElapsed.selector
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    function test_executeDepositHookFacetChange_withoutProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoDepositHookChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    function test_executeDepositHookFacetChange_setsFacetAndEmits()
        public
    {
        address facet = address(
            new GraceAccumHookFacet()
        );

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            facet
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositHookFacetSet(
            facet
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();

        assertEq(
            diamond.depositHookFacet(),
            facet
        );

        assertEq(
            diamond.proposedDepositHookFacet(),
            address(0)
        );

        assertEq(
            diamond.depositHookChangeQueuedAt(),
            0
        );
    }

    function test_cancelDepositHookFacetChange_clearsProposal()
        public
    {
        address facet = address(
            new GraceAccumHookFacet()
        );

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            facet
        );

        vm.expectEmit(
            true,
            false,
            false,
            false,
            address(diamond)
        );

        emit DepositHookFacetProposalCancelled(
            facet
        );

        AdminFacet(address(diamond)).cancelDepositHookFacetChange();

        assertEq(
            diamond.proposedDepositHookFacet(),
            address(0)
        );

        assertEq(
            diamond.depositHookChangeQueuedAt(),
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoDepositHookChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    function test_genesisInstall_beforeFinalize_isInstant()
        public
    {
        WiseSovrenNodesDiamond fresh = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            fresh
        );

        address facet = address(
            new GraceAccumHookFacet()
        );

        AdminFacet(address(fresh)).proposeDepositHookFacet(
            facet
        );

        AdminFacet(address(fresh)).executeDepositHookFacetChange();

        assertEq(
            fresh.depositHookFacet(),
            facet
        );

        fresh.finalizeSetup();

        AdminFacet(address(fresh)).proposeDepositHookFacet(
            address(new GraceAccumHookFacet())
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositHookTimelockNotElapsed.selector
        );

        AdminFacet(address(fresh)).executeDepositHookFacetChange();
    }

    function test_proposeZeroFacet_uninstallsAndRestoresInlineDefault()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            address(0)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();

        assertEq(
            diamond.depositHookFacet(),
            address(0)
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_executeDepositHookFacetChange_codelessTarget_reverts()
        public
    {
        AdminFacet(address(diamond)).proposeDepositHookFacet(
            address(0xDEAD01)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    function test_executeTransferHookFacetChange_codelessTarget_reverts()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(0xDEAD01)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }

    function test_wrongFacetInstalled_depositsRevert_thresholdZeroUnbricks()
        public
    {
        AdminFacet(address(diamond)).proposeDepositHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            0
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            1_000 * 1e6
        );
    }

    // ---- setter ----

    function test_setDepositAccumWindow_aboveMax_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositAccumWindowTooLong.selector
        );

        AdminFacet(address(diamond)).setDepositAccumWindow(
            MAX_GRACE + 1
        );
    }

    function test_setDepositAccumWindow_byMaster_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositAccumWindowSet(
            ACCUM_WINDOW
        );

        AdminFacet(address(diamond)).setDepositAccumWindow(
            ACCUM_WINDOW
        );

        assertEq(
            diamond.depositAccumWindow(),
            ACCUM_WINDOW
        );
    }

    // ---- dormant default: hook installed, window 0 ----

    function test_windowOff_splitDeposits_doNotStamp()
        public
    {
        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_windowOff_loneLargeDeposit_stampsAndEmits()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            THRESHOLD
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit LargeDepositRegistered(
            user1,
            THRESHOLD,
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_windowOff_thresholdZero_neverStamps()
        public
    {
        AdminFacet(address(diamond)).setGraceThresholdAmount(
            0
        );

        _depositAs(
            diamond,
            user1,
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    // ---- armed accumulation ----

    function test_armed_splitDeposits_stampOnCumulative()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _fundAndApprove(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit LargeDepositRegistered(
            user1,
            12_000 * 1e6,
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_armed_subThresholdDeposit_emitsWindowAccumulated()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _fundAndApprove(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositWindowAccumulated(
            user1,
            4_000 * 1e6,
            block.timestamp + ACCUM_WINDOW
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            4_000 * 1e6
        );

        assertEq(
            diamond.depositWindowStart(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_armed_windowBoundary_lastSecondAccumulates()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.warp(
            block.timestamp + ACCUM_WINDOW - 1
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_armed_windowBoundary_atExpiryAdjacentBucketsSum()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.warp(
            block.timestamp + ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_armed_spreadDeposits_doNotStamp()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.warp(
            block.timestamp + 2 days
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            6_000 * 1e6
        );
    }

    function test_armed_boundaryStraddle_dustAnchor_stampsOnCumulative()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            50 * 1e6
        );

        vm.warp(
            block.timestamp + ACCUM_WINDOW - 1
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        vm.warp(
            block.timestamp + 2
        );

        _fundAndApprove(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit LargeDepositRegistered(
            user1,
            12_050 * 1e6,
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            6_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_armed_adjacentBuckets_almostTwoWindowsApart_coCount()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.warp(
            block.timestamp + 2 * ACCUM_WINDOW - 1
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_armed_bucketAdvance_carriesPrevTotal()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        uint256 anchor = block.timestamp;

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 3 / 2
        );

        _fundAndApprove(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositWindowAccumulated(
            user1,
            8_000 * 1e6,
            anchor + 2 * ACCUM_WINDOW
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            4_000 * 1e6
        );

        assertEq(
            diamond.depositWindowStart(user1),
            anchor + ACCUM_WINDOW
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            4_000 * 1e6
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            4_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 19 / 10
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );
    }

    function test_armed_bucketAdvance_countedTotalCanDecrease()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        uint256 anchor = block.timestamp;

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 6 / 5
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositWindowAccumulated(
            user1,
            5_000 * 1e6,
            anchor + 2 * ACCUM_WINDOW
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 5 / 2
        );

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositWindowAccumulated(
            user1,
            3_000 * 1e6,
            anchor + 3 * ACCUM_WINDOW
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            2_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            1_000 * 1e6
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            2_000 * 1e6
        );
    }

    function test_armed_twoWindowSkip_dropsBothBuckets()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        uint256 anchor = block.timestamp;

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 3 / 2
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.warp(
            anchor + ACCUM_WINDOW * 7 / 2
        );

        _depositAs(
            diamond,
            user1,
            3_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowStart(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowPrevTotal(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            3_000 * 1e6
        );
    }

    function testFuzz_armed_depositsWithinOneWindow_alwaysStamp(
        uint256 _gap,
        uint256 _first,
        uint256 _second
    )
        public
    {
        _gap = bound(
            _gap,
            0,
            ACCUM_WINDOW
        );

        _first = bound(
            _first,
            THRESHOLD / 2,
            THRESHOLD - 1
        );

        _second = bound(
            _second,
            THRESHOLD / 2,
            THRESHOLD - 1
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            _first
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        vm.warp(
            block.timestamp + _gap
        );

        _depositAs(
            diamond,
            user1,
            _second
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function testFuzz_armed_depositsTwoWindowsApart_neverStamp(
        uint256 _gap,
        uint256 _first,
        uint256 _second
    )
        public
    {
        _gap = bound(
            _gap,
            2 * ACCUM_WINDOW,
            10 * ACCUM_WINDOW
        );

        _first = bound(
            _first,
            50 * 1e6,
            THRESHOLD - 1
        );

        _second = bound(
            _second,
            50 * 1e6,
            THRESHOLD - 1
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            _first
        );

        vm.warp(
            block.timestamp + _gap
        );

        _depositAs(
            diamond,
            user1,
            _second
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_armed_loneLargeDeposit_stampsImmediately()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_armed_largeDepositWithPriorAccum_stampsCumulativeAndClearsWindow()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _fundAndApprove(
            diamond,
            user1,
            THRESHOLD
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit LargeDepositRegistered(
            user1,
            14_000 * 1e6,
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            THRESHOLD
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    function test_armed_windowsArePerUser()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user2,
            7_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.lastLargeDepositAt(user2),
            0
        );

        _depositAs(
            diamond,
            user2,
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user2),
            block.timestamp
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            4_000 * 1e6
        );
    }

    function test_armed_compoundInterest_countsTowardWindow()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            100_000 * 1e6
        );

        vm.warp(
            block.timestamp + 1 days
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        uint256 balanceBefore = diamond.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).compoundInterest();

        uint256 compounded = diamond.balanceOf(user1)
            - balanceBefore;

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            compounded
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_armed_multicallSplit_stampsInOneTx()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _fundAndApprove(
            diamond,
            user1,
            12_000 * 1e6
        );

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            4_000 * 1e6
        );

        calls[1] = calls[0];
        calls[2] = calls[0];

        vm.prank(
            user1
        );

        MulticallFacet(address(diamond)).multicall(
            calls
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_armed_reArmAfterWindowAged_resetsStaleRecords()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        _armWindow(
            0
        );

        vm.warp(
            block.timestamp + 3 days
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            5_000 * 1e6
        );
    }

    function test_armed_reArmWithinWindow_countsResidual()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        _armWindow(
            0
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    // ---- reset on stamp ----

    function test_armed_postStampDust_doesNotRestamp()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        uint256 stampTime = diamond.lastLargeDepositAt(
            user1
        );

        assertEq(
            stampTime,
            block.timestamp
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _depositAs(
            diamond,
            user1,
            500 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            stampTime
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            500 * 1e6
        );
    }

    function test_armed_secondCumulativeThreshold_restamps()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        uint256 firstStamp = diamond.lastLargeDepositAt(
            user1
        );

        vm.warp(
            block.timestamp + 10 days
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            5_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            firstStamp + 10 days
        );
    }

    // ---- disarm and fallback surfaces ----

    function test_disarmMidFlight_residualWindowIgnored()
        public
    {
        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        _armWindow(
            0
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            6_000 * 1e6
        );
    }

    function test_noHookInstalled_legacySingleCallSemantics()
        public
    {
        WiseSovrenNodesDiamond noHook = _deployDiamondWithQueue(
            address(usd)
        );

        _depositAs(
            noHook,
            user1,
            THRESHOLD
        );

        assertEq(
            noHook.lastLargeDepositAt(user1),
            block.timestamp
        );

        _depositAs(
            noHook,
            user2,
            4_000 * 1e6
        );

        _depositAs(
            noHook,
            user2,
            4_000 * 1e6
        );

        _depositAs(
            noHook,
            user2,
            4_000 * 1e6
        );

        assertEq(
            noHook.lastLargeDepositAt(user2),
            0
        );
    }

    function test_windowSetWithoutHook_hasNoEffect()
        public
    {
        WiseSovrenNodesDiamond noHook = _deployDiamondWithQueue(
            address(usd)
        );

        AdminFacet(address(noHook)).setDepositAccumWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            noHook,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            noHook,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            noHook,
            user1,
            4_000 * 1e6
        );

        assertEq(
            noHook.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            noHook.depositWindowTotal(user1),
            0
        );
    }

    // ---- end-to-end with the freeze hook ----

    function test_armed_splitStamp_transferReverts_withFreezeHook()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );
    }

    function test_armed_splitStamp_joinQueReverts_withFreezeHook()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        _depositAs(
            diamond,
            user1,
            4_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );
    }

    function test_armed_straddleStamp_transferReverts_withFreezeHook()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _armWindow(
            ACCUM_WINDOW
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        vm.warp(
            block.timestamp + ACCUM_WINDOW + 1
        );

        _depositAs(
            diamond,
            user1,
            6_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );
    }
}
