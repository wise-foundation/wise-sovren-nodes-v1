// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {FacetBase} from "../../src/diamond/vault/facets/FacetBase.sol";

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
        public
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Interest-moving swap target: re-implements the removed
 * interest-follows-tokens policy as an installable facet, relocating
 * the sender's whole cashed interest to the recipient (tolerant of a
 * zero balance). Proves the DELEGATECALL plumbing is transparent AND
 * that a delegatecalled hook writes the correct diamond storage slots.
 * Test-only - never added to src/, a deploy script, or a selector
 * list.
 */
contract IdentityTransferHookFacet is FacetBase {

    function applyTransferHook(
        address _from,
        address _to
    )
        external
        onlyDelegateCall
    {
        if (_from != _to) {
            cashedInterest[_to] += cashedInterest[_from];

            cashedInterest[_from] = 0;
        }
    }
}

/**
 * @dev Behaviour-CHANGING swap target: never moves interest, only
 * flags that it ran. Used to prove the hook is swappable on a live
 * diamond. Test-only.
 */
contract NoopTransferHookFacet is FacetBase {

    event HookRan(
        address indexed from,
        address indexed to
    );

    function applyTransferHook(
        address _from,
        address _to
    )
        external
        onlyDelegateCall
    {
        emit HookRan(
            _from,
            _to
        );
    }
}

/**
 * @dev Reverting swap target: proves the indirection bubbles a hook
 * revert (the `success == false` branch of `_runTransferHook`).
 * Test-only.
 */
contract RevertingTransferHookFacet is FacetBase {

    error HookRejected();

    function applyTransferHook(
        address,
        address
    )
        external
        view
        onlyDelegateCall
    {
        revert HookRejected();
    }
}

/**
 * @dev Reentrant swap target: tries to re-enter `transfer` on the
 * diamond while the outer transfer still holds the reentrancy guard.
 * Test-only.
 */
contract ReentrantTransferHookFacet is FacetBase {

    function applyTransferHook(
        address,
        address _to
    )
        external
        onlyDelegateCall
    {
        WiseSovrenNodesDiamond(payable(address(this))).transfer(
            _to,
            1
        );
    }
}

/**
 * @dev Exercises the swappable transfer-hook feature: the timelocked
 * `transferHookFacet` pointer, the `_runTransferHook` indirection on
 * `transfer` / `transferFrom`, equivalence with the inline default,
 * live in-system swapping, access control, reentrancy and the
 * absence of storage collision. The test contract is master.
 */
contract WiseSovrenNodesTransferHookFacetTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address stranger = address(0xBEEF);

    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant PRINCIPAL = 1_000 * 1e6;
    uint256 constant TRANSFER_AMT = 100 * 1e6;
    uint256 constant HOOK_DELAY = 3 days;

    bytes4 constant HOOK_SELECTOR = bytes4(
        keccak256("applyTransferHook(address,address)")
    );

    event HookRan(
        address indexed from,
        address indexed to
    );

    event TransferHookFacetSet(
        address transferHookFacet
    );

    event TransferHookFacetProposed(
        address indexed proposedTransferHookFacet,
        uint256 executableAt
    );

    event TransferHookFacetProposalCancelled(
        address indexed cancelledTransferHookFacet
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

    /**
     * @dev Mints principal to `user1`, accrues one year of interest,
     * then transfers to `user2`. Returns the interest pending on
     * `user1` right before the transfer plus both cashed balances
     * afterwards. With no hook the inline default leaves interest in
     * place; an installed interest-moving hook relocates it.
     */
    function _runInterestMoveScenario(
        WiseSovrenNodesDiamond _d
    )
        internal
        returns (
            uint256 pendingBefore,
            uint256 cashedFromAfter,
            uint256 cashedToAfter
        )
    {
        AdminFacet(address(_d)).mintSupply(
            user1,
            PRINCIPAL
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        pendingBefore = _d.getPendingInterest(
            user1
        );

        vm.prank(
            user1
        );

        _d.transfer(
            user2,
            TRANSFER_AMT
        );

        cashedFromAfter = _d.cashedInterest(
            user1
        );

        cashedToAfter = _d.cashedInterest(
            user2
        );
    }

    // ---- default / inline ----

    function test_default_pointerIsUnset()
        public
    {
        assertEq(
            diamond.transferHookFacet(),
            address(0)
        );
    }

    function test_inlineDefault_doesNotMoveInterestOnTransfer()
        public
    {
        (
            uint256 pendingBefore,
            uint256 cashedFromAfter,
            uint256 cashedToAfter
        ) = _runInterestMoveScenario(diamond);

        assertGt(
            pendingBefore,
            0
        );

        assertEq(
            cashedFromAfter,
            pendingBefore
        );

        assertEq(
            cashedToAfter,
            0
        );
    }

    // ---- equivalence (Req #1) ----

    function test_installedHook_movesInterestOnTransfer()
        public
    {
        WiseSovrenNodesDiamond hookDiamond = _deployDiamond(
            address(usd)
        );

        _installHook(
            hookDiamond,
            address(new IdentityTransferHookFacet())
        );

        (
            uint256 pendingBefore,
            uint256 cashedFromAfter,
            uint256 cashedToAfter
        ) = _runInterestMoveScenario(hookDiamond);

        assertGt(
            pendingBefore,
            0
        );

        assertEq(
            cashedFromAfter,
            0
        );

        assertEq(
            cashedToAfter,
            pendingBefore
        );
    }

    // ---- live swap in a running system (Req #2) ----

    function test_liveSwap_changesThenRestoresBehaviour()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            PRINCIPAL
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user3,
            TRANSFER_AMT
        );

        assertGt(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            diamond.cashedInterest(user3),
            0
        );

        _installHook(
            diamond,
            address(new IdentityTransferHookFacet())
        );

        assertTrue(
            diamond.transferHookFacet() != address(0)
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user3,
            TRANSFER_AMT
        );

        assertEq(
            diamond.cashedInterest(user1),
            0
        );

        assertGt(
            diamond.cashedInterest(user3),
            0
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(0)
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        assertEq(
            diamond.transferHookFacet(),
            address(0)
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            TRANSFER_AMT
        );

        assertGt(
            diamond.cashedInterest(user1),
            0
        );

        assertEq(
            diamond.cashedInterest(user2),
            0
        );
    }

    // ---- transferFrom routes the hook too ----

    function test_transferFrom_routesHook()
        public
    {
        _installHook(
            diamond,
            address(new NoopTransferHookFacet())
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            PRINCIPAL
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            TRANSFER_AMT
        );

        vm.expectEmit(
            true,
            true,
            false,
            false,
            address(diamond)
        );

        emit HookRan(
            user1,
            user3
        );

        vm.prank(
            user2
        );

        diamond.transferFrom(
            user1,
            user3,
            TRANSFER_AMT
        );
    }

    // ---- genesis-instant vs post-finalize timelock ----

    function test_genesisInstall_beforeFinalize_isInstant()
        public
    {
        WiseSovrenNodesDiamond fresh = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            fresh
        );

        address facet = address(new IdentityTransferHookFacet());

        AdminFacet(address(fresh)).proposeTransferHookFacet(
            facet
        );

        AdminFacet(address(fresh)).executeTransferHookFacetChange();

        assertEq(
            fresh.transferHookFacet(),
            facet
        );

        fresh.finalizeSetup();

        AdminFacet(address(fresh)).proposeTransferHookFacet(
            address(new NoopTransferHookFacet())
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.TransferHookTimelockNotElapsed.selector
        );

        AdminFacet(address(fresh)).executeTransferHookFacetChange();
    }

    // ---- timelock / authz ----

    function test_propose_emitsAndQueues()
        public
    {
        address facet = address(new IdentityTransferHookFacet());

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit TransferHookFacetProposed(
            facet,
            block.timestamp + HOOK_DELAY
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            facet
        );

        assertEq(
            diamond.proposedTransferHookFacet(),
            facet
        );

        assertEq(
            diamond.transferHookChangeQueuedAt(),
            block.timestamp
        );
    }

    function test_execute_beforeDelayReverts()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new IdentityTransferHookFacet())
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.TransferHookTimelockNotElapsed.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }

    function test_execute_withoutProposalReverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoTransferHookChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }

    function test_execute_setsFacetAndEmits()
        public
    {
        address facet = address(new IdentityTransferHookFacet());

        AdminFacet(address(diamond)).proposeTransferHookFacet(
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

        emit TransferHookFacetSet(
            facet
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        assertEq(
            diamond.transferHookFacet(),
            facet
        );

        assertEq(
            diamond.proposedTransferHookFacet(),
            address(0)
        );

        assertEq(
            diamond.transferHookChangeQueuedAt(),
            0
        );
    }

    function test_cancel_clearsProposal()
        public
    {
        address facet = address(new IdentityTransferHookFacet());

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            facet
        );

        vm.expectEmit(
            true,
            false,
            false,
            false,
            address(diamond)
        );

        emit TransferHookFacetProposalCancelled(
            facet
        );

        AdminFacet(address(diamond)).cancelTransferHookFacetChange();

        assertEq(
            diamond.proposedTransferHookFacet(),
            address(0)
        );

        assertEq(
            diamond.transferHookChangeQueuedAt(),
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoTransferHookChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }

    function test_propose_nonMasterReverts()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(0xABCD)
        );
    }

    function test_execute_nonMasterReverts()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new IdentityTransferHookFacet())
        );

        vm.warp(
            block.timestamp + HOOK_DELAY + 1
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();
    }

    // ---- access control ----

    function test_hookSelector_notCallableThroughDiamond()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                HOOK_SELECTOR,
                user1,
                user2
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

    function test_directCallToFacet_reverts()
        public
    {
        IdentityTransferHookFacet facet = new IdentityTransferHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyTransferHook(
            user1,
            user2
        );
    }

    // ---- revert bubbling / reentrancy ----

    function test_revertingHook_bubblesRevert()
        public
    {
        _installHook(
            diamond,
            address(new RevertingTransferHookFacet())
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            PRINCIPAL
        );

        vm.expectRevert(
            RevertingTransferHookFacet.HookRejected.selector
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            TRANSFER_AMT
        );
    }

    function test_reentrantHook_blockedByGuard()
        public
    {
        _installHook(
            diamond,
            address(new ReentrantTransferHookFacet())
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            PRINCIPAL
        );

        vm.expectRevert();

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            TRANSFER_AMT
        );
    }

    // ---- storage collision guard ----

    function test_hookStorage_doesNotCollide()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user3,
            PRINCIPAL
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        AdminFacet(address(diamond)).mintSupply(
            user3,
            1
        );

        uint256 strangerCashed = diamond.cashedInterest(
            user3
        );

        address thirdPartyBefore = diamond.thirdPartyAddress();
        uint256 totalSupplyBefore = diamond.totalSupply();

        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            address(0xF00D)
        );

        uint256 proposedTpQueuedAt = diamond.thirdPartyChangeQueuedAt();

        address hookFacet = address(new IdentityTransferHookFacet());

        _installHook(
            diamond,
            hookFacet
        );

        assertEq(
            diamond.transferHookFacet(),
            hookFacet
        );

        assertEq(
            diamond.thirdPartyAddress(),
            thirdPartyBefore
        );

        assertEq(
            diamond.proposedThirdPartyAddress(),
            address(0xF00D)
        );

        assertEq(
            diamond.thirdPartyChangeQueuedAt(),
            proposedTpQueuedAt
        );

        assertEq(
            diamond.cashedInterest(user3),
            strangerCashed
        );

        assertEq(
            diamond.totalSupply(),
            totalSupplyBefore
        );
    }
}
