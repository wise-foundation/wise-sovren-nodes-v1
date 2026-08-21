// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
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
 * @dev Tests for the swappable grace-freeze transfer hook
 * (`GraceFreezeHookFacet`). Once installed as `transferHookFacet`,
 * any share movement OUT of an address inside its large-deposit grace
 * window reverts, so a freshly-boosted holder can neither transfer the
 * shares to a fresh address nor escrow them via `joinQue` for a
 * confederate wallet to fulfil. Inbound receipts and vault-escrow
 * payouts (queue leave / fulfil) stay open,
 * and everything unlocks once the grace window elapses. A no-hook
 * control demonstrates the queue-laundering path the hook closes.
 */
contract WiseSovrenNodesGraceFreezeHookTest is DiamondTestHarness {

    uint256 internal constant THRESHOLD = 10_000 * 1e6;
    uint256 internal constant GRACE_PERIOD = 45 days;
    uint256 internal constant HOOK_DELAY = 3 days;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal user3 = address(0xA3);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    address internal freezeHook;

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

        freezeHook = address(
            new GraceFreezeHookFacet()
        );

        _installHook(
            diamond,
            freezeHook
        );

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );
    }

    // ---- helpers ----

    function _installHook(
        WiseSovrenNodesDiamond _d,
        address _facet
    )
        internal
    {
        AdminFacet(address(_d)).proposeTransferHookFacet(
            _facet
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(_d)).executeTransferHookFacetChange();
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

    function _stampViaDeposit(
        address _user
    )
        internal
    {
        _depositAs(
            diamond,
            _user,
            THRESHOLD
        );
    }

    // ---- install ----

    function test_freezeHook_installed()
        public
        view
    {
        assertEq(
            diamond.transferHookFacet(),
            freezeHook
        );
    }

    function test_freezeHook_directCall_reverts()
        public
    {
        GraceFreezeHookFacet facet = new GraceFreezeHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyTransferHook(
            user1,
            user2
        );
    }

    function test_transferHookSelector_routedButExternalCallStillGuarded()
        public
    {
        bytes4 transferHookSelector = bytes4(
            keccak256("applyTransferHook(address,address)")
        );

        diamond.proposeSelector(
            transferHookSelector,
            freezeHook
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        diamond.executeSelectorChange(
            transferHookSelector
        );

        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                transferHookSelector,
                user1,
                user2
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );
    }

    // ---- master toggle (graceFreezeEnabled) ----

    function test_graceFreeze_defaultFalse_noFreeze()
        public
    {
        WiseSovrenNodesDiamond dormant = _deployDiamondWithQueue(
            address(usd)
        );

        _installHook(
            dormant,
            address(new GraceFreezeHookFacet())
        );

        assertEq(
            dormant.graceFreezeEnabled(),
            false
        );

        _depositAs(
            dormant,
            user1,
            THRESHOLD
        );

        vm.prank(
            user1
        );

        dormant.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            dormant.balanceOf(user2),
            1_000 * 1e6
        );
    }

    function test_graceFreeze_masterToggleOff_unfreezes()
        public
    {
        _stampViaDeposit(
            user1
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

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            false
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            1_000 * 1e6
        );
    }

    function test_setGraceFreezeEnabled_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );
    }

    // ---- freeze: outbound from a locked address ----

    function test_freeze_transferByLockedUser_reverts()
        public
    {
        _stampViaDeposit(
            user1
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

    function test_freeze_transferFromLockedOwner_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            1_000 * 1e6
        );

        vm.prank(
            user2
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transferFrom(
            user1,
            user3,
            1_000 * 1e6
        );
    }

    function test_freeze_joinQueByLockedUser_reverts()
        public
    {
        _stampViaDeposit(
            user1
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

    // ---- no-hook control: the queue-laundering path the hook closes ----

    function test_noHook_queueLaundering_succeeds()
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

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(noHook)).joinQue(
            THRESHOLD,
            0
        );

        _fundAndApprove(
            noHook,
            user2,
            THRESHOLD
        );

        vm.prank(
            user2
        );

        QueueFulfillFacet(address(noHook)).fulfillOrder(
            id,
            0
        );

        assertEq(
            noHook.balanceOf(user2),
            THRESHOLD
        );

        assertEq(
            noHook.lastLargeDepositAt(user2),
            0
        );
    }

    // ---- open paths under the freeze ----

    function test_freeze_unstampedUser_transferSucceeds()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            2 * THRESHOLD
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            THRESHOLD
        );

        assertEq(
            diamond.balanceOf(user2),
            THRESHOLD
        );
    }

    function test_freeze_unstampedUser_queueFlowSucceeds()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            2 * THRESHOLD
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2 * THRESHOLD,
            0
        );

        _fundAndApprove(
            diamond,
            user2,
            2 * THRESHOLD
        );

        vm.prank(
            user2
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            id,
            0
        );

        assertEq(
            diamond.balanceOf(user2),
            2 * THRESHOLD
        );
    }

    function test_freeze_receiveWhileLocked_allowed()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user2,
            THRESHOLD
        );

        _stampViaDeposit(
            user1
        );

        vm.prank(
            user2
        );

        diamond.transfer(
            user1,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD + 1_000 * 1e6
        );
    }

    // ---- unlock after grace elapses ----

    function test_freeze_afterGraceElapsed_transferSucceeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            1_000 * 1e6
        );
    }

    function test_freeze_afterGraceElapsed_joinQueSucceeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD - 1_000 * 1e6
        );
    }
}
