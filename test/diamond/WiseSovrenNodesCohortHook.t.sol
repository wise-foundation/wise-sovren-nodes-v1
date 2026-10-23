// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall, FacetNotFound, SelectorTimelockNotElapsed} from "../../src/diamond/shared/DiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

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

contract MockPermit2 is IPermit2 {

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata
    )
        external
    {
        require(
            block.timestamp <= _permit.deadline,
            "deadline"
        );

        IERC20(_permit.permitted.token).transferFrom(
            _owner,
            _transferDetails.to,
            _transferDetails.requestedAmount
        );
    }
}

/**
 * @dev Composed-transfer-hook suite for {CohortHookFacet}: proves the
 * grace-freeze semantics it inherits from {GraceFreezeHookFacet} are
 * preserved byte-for-byte (freeze check runs FIRST, before any cohort
 * gating or sync) both while `cohortSyncEnabled` is armed and while
 * the facet sits installed-but-unarmed (parity with the plain grace
 * hook), the direct-call and unrouted-selector guards on the
 * `applyCohort*` entrypoints, and the full timelocked live-upgrade
 * sequence: installing the cohort selectors and hook onto a diamond
 * that started on the plain grace hook with pre-existing holders,
 * confirming neutrality until armed, then swapping back to a fresh
 * grace hook and confirming the recorder goes cleanly inert. Mirrors
 * the wiring and helper shapes of
 * {WiseSovrenNodesCohortTouchpointsTest} and the grace-freeze
 * scenarios of {WiseSovrenNodesGraceFreezeHookTest}. The
 * transfer-hook execute refuses a pending zero hook while the
 * recorder is armed and executes it after a disarm, while a cohort
 * hook swap still executes armed and an execute with nothing pending
 * keeps its own error.
 */
contract WiseSovrenNodesCohortHookTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant STAMP_AMOUNT = 12_000 * 1e6;

    uint256 internal constant GRACE_PERIOD = 45 days;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant HOOK_DELAY = 3 days;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);
    address internal poker = address(0xD1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
        );

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireQueueFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            diamond,
            address(new Permit2ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );
    }

    // ---- helpers ----

    function _arm()
        internal
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _fundAndApprove(
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
            address(diamond),
            _amount
        );
    }

    function _depositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApprove(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApprove(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    // ---- grace-freeze preservation under CohortHookFacet (armed) ----

    function test_freeze_transferByLockedUser_stillReverts()
        public
    {
        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _arm();

        _depositWithReferralAs(
            user1,
            STAMP_AMOUNT,
            refA
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            outsider,
            1_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            STAMP_AMOUNT
        );
    }

    function test_freeze_joinQueByLockedUser_stillReverts()
        public
    {
        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _arm();

        _depositWithReferralAs(
            user1,
            STAMP_AMOUNT,
            refA
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

    function test_freeze_afterWindowElapsed_transferSucceedsAndSyncs()
        public
    {
        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _arm();

        _depositWithReferralAs(
            user1,
            STAMP_AMOUNT,
            refA
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            STAMP_AMOUNT
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            STAMP_AMOUNT - 2_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            STAMP_AMOUNT - 2_000 * 1e6
        );
    }

    function test_freeze_disabled_transfersFreeAndSynced()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            STAMP_AMOUNT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                outsider
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            STAMP_AMOUNT
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            STAMP_AMOUNT - 2_000 * 1e6
        );
    }

    function test_freeze_vaultEscrowReturn_passes()
        public
    {
        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _arm();

        _depositAs(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            DEPOSIT,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );
    }

    // ---- unarmed parity ----

    function test_unarmedHook_behavesLikeGraceFreezeHook()
        public
    {
        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        _depositWithReferralAs(
            user1,
            STAMP_AMOUNT,
            refA
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            outsider,
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            false
        );

        _transferAs(
            user1,
            outsider,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                outsider
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- guards ----

    function test_hook_directCall_reverts()
        public
    {
        CohortHookFacet facet = new CohortHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyTransferHook(
            user1,
            user2
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyCohortSync(
            user1
        );
    }

    function test_hook_selectorsNotRouted()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSignature(
                "applyCohortSync(address)",
                user1
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

    // ---- live-upgrade simulation ----

    function test_liveUpgrade_timelockedCohortInstall_endToEnd()
        public
    {
        WiseSovrenNodesDiamond live = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            live
        );

        _wireQueueFacets(
            live
        );

        _wireOne(
            live,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            live,
            address(new Permit2ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        AdminFacet(address(live)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        AdminFacet(address(live)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            live
        );

        live.finalizeSetup();

        usd.mint(
            user2,
            DEPOSIT
        );

        vm.prank(
            user2
        );

        usd.approve(
            address(live),
            DEPOSIT
        );

        vm.prank(
            user2
        );

        UserFacet(address(live)).deposit(
            DEPOSIT
        );

        uint256 user2BalanceBefore = live.balanceOf(
            user2
        );

        usd.mint(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(live),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(live)).depositWithReferral(
            DEPOSIT,
            refA
        );

        address cohortRecorder = address(new CohortRecorderFacet());
        address cohortHook = address(new CohortHookFacet());

        live.proposeSelectors(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors(),
            cohortRecorder
        );

        AdminFacet(address(live)).proposeTransferHookFacet(
            cohortHook
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        live.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.TransferHookTimelockNotElapsed.selector
        );

        AdminFacet(address(live)).executeTransferHookFacetChange();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        live.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        AdminFacet(address(live)).executeTransferHookFacetChange();

        CohortRecorderFacet liveRecorder = CohortRecorderFacet(address(live));

        assertEq(
            liveRecorder.getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            liveRecorder.getCohortScore(
                refA
            ),
            0
        );

        usd.mint(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(live),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        UserFacet(address(live)).deposit(
            DEPOSIT
        );

        vm.prank(
            user1
        );

        live.transfer(
            outsider,
            1_000 * 1e6
        );

        assertEq(
            liveRecorder.getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            liveRecorder.getCohortScore(
                refA
            ),
            0
        );

        AdminFacet(address(live)).setCohortSyncEnabled(
            true
        );

        usd.mint(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(live),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(live)).depositWithReferral(
            DEPOSIT,
            refA
        );

        assertEq(
            liveRecorder.getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            liveRecorder.getCohortScore(
                refA
            ),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        live.transfer(
            outsider,
            10_000 * 1e6
        );

        vm.prank(
            poker
        );

        liveRecorder.syncReferee(
            user1
        );

        assertEq(
            liveRecorder.getTrackedContribution(
                user1
            ),
            4_000 * 1e6
        );

        assertEq(
            liveRecorder.getCohortScore(
                refA
            ),
            4_000 * 1e6
        );

        assertEq(
            live.balanceOf(
                user1
            ),
            4_000 * 1e6
        );

        assertEq(
            live.balanceOf(
                user2
            ),
            user2BalanceBefore
        );
    }

    function test_hookSwapBack_removesRecorderSyncCleanly()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        uint256 trackedBefore = _recorder().getTrackedContribution(
            user1
        );

        uint256 scoreBefore = _recorder().getCohortScore(
            refA
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        _transferAs(
            user1,
            outsider,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                outsider
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            trackedBefore
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            scoreBefore
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            trackedBefore
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            scoreBefore
        );
    }

    function test_arm_revertsWhileNonCohortHookInstalled()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        vm.expectRevert();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function test_executeTransferHookFacetChange_zeroHookWhileArmed_reverts()
        public
    {
        _arm();

        address hookBefore = diamond.transferHookFacet();

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(0)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortHookNotInstalled.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        assertEq(
            diamond.transferHookFacet(),
            hookBefore
        );

        assertGt(
            diamond.transferHookChangeQueuedAt(),
            0
        );
    }

    function test_executeTransferHookFacetChange_zeroHookAfterDisarm_succeeds()
        public
    {
        _arm();

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(0)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        assertEq(
            diamond.transferHookFacet(),
            address(0)
        );
    }

    function test_executeTransferHookFacetChange_cohortHookSwapWhileArmed_succeeds()
        public
    {
        _arm();

        address fresh = address(new CohortHookFacet());

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            fresh
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        assertEq(
            diamond.transferHookFacet(),
            fresh
        );

        assertTrue(
            _recorder().getCohortSyncEnabled()
        );
    }

    function test_executeTransferHookFacetChange_nothingProposedWhileArmed_reverts()
        public
    {
        _arm();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoTransferHookChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }
}
