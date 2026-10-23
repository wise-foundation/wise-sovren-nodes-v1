// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {CohortPinnedProbeFacet, PinnedPrefixView} from "./utils/CohortPinnedProbeFacet.sol";
import {MockUSD} from "./WiseSovrenNodesCohortFlush.t.sol";

/**
 * @dev USD mock whose `transferFrom` first makes one armed call, so a
 * deposit (which holds the diamond's reentrancy lock while it pulls
 * USD) can probe whether a slim cohort facet sees that lock.
 */
contract ReenteringUSD is ERC20 {

    address internal target;

    bytes internal callData;

    constructor()
        ERC20("Reentering USD", "RUSD")
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

    function arm(
        address _target,
        bytes calldata _callData
    )
        external
    {
        target = _target;
        callData = _callData;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        public
        override
        returns (bool)
    {
        if (target != address(0)) {
            (
                bool success,
                bytes memory returnData
            ) = target.call(
                callData
            );

            if (success == false) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        return super.transferFrom(
            _from,
            _to,
            _amount
        );
    }
}

error HookStubFailed();

/**
 * @dev Transfer hook stand-in that reverts on every call, so a flush
 * that settles a book through the slim base meets a failing hook.
 */
contract RevertingHookStub {

    fallback()
        external
        payable
    {
        revert HookStubFailed();
    }
}

/**
 * @dev Pins of the slim cohort storage base against the diamond's
 * real storage, through contract code only. The probe facet reads
 * what the diamond's genesis setters wrote and writes what the
 * diamond's genesis getters then read, for every hand-pinned prefix
 * variable, with the packed neighbours checked untouched. The flow
 * pins drive the real slim facets: the full-chain reentrancy lock
 * refusing the slim flush and the slim lock refusing a full-chain
 * entry, the diamond pause stopping the slim flush, and the diamond's
 * grace freeze enforced by the slim hook inside the full-chain
 * transfer bracket.
 */
contract WiseSovrenNodesCohortPinnedStorageTest is DiamondTestHarness {

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal newMaster = address(0xC1);
    address internal router = address(0xC2);

    uint256 internal constant GRACE = 3 days;
    uint256 internal constant THRESHOLD = 1_000 * 1e6;
    uint256 internal constant LARGE = 2_000 * 1e6;

    MockUSD internal usd;

    WiseSovrenNodesDiamond internal diamond;

    CohortHookFacet internal hookFacet;

    function setUp()
        public
    {
        usd = new MockUSD();

        diamond = _buildSlimDiamond(
            address(usd)
        );
    }

    function _buildSlimDiamond(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _wireOne(
            d,
            address(new QueueAdminFacet()),
            WiseSovrenNodesDiamondSelectors._queueAdminSelectors()
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _wireOne(
            d,
            address(new CohortPinnedProbeFacet()),
            _probeSelectors()
        );

        hookFacet = new CohortHookFacet();

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(hookFacet)
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            d
        );

        AdminFacet(address(d)).proposeFlushHub(
            address(0xF00D),
            0
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    function _probeSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);

        sels[0] = CohortPinnedProbeFacet.probeReadPinned.selector;
        sels[1] = CohortPinnedProbeFacet.probeWritePinned.selector;
        sels[2] = CohortPinnedProbeFacet.probeLockedCall.selector;
        sels[3] = CohortPinnedProbeFacet.probeLockOpen.selector;
    }

    function _probe()
        internal
        view
        returns (CohortPinnedProbeFacet)
    {
        return CohortPinnedProbeFacet(
            address(diamond)
        );
    }

    function _deposit(
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

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _armGrace()
        internal
    {
        AdminFacet(address(diamond)).setGracePeriodDuration(
            GRACE
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            THRESHOLD
        );

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );
    }

    function _reentrantReason()
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "Error(string)",
            "ReentrancyGuard: reentrant call"
        );
    }

    function _oneRef(
        address _referrer
    )
        internal
        pure
        returns (address[] memory refs)
    {
        refs = new address[](1);

        refs[0] = _referrer;
    }

    function test_pinnedPrefix_readsDiamondGenesisWrites()
        public
    {
        diamond.proposeOwner(
            newMaster
        );

        QueueAdminFacet(address(diamond)).setNegativeIncentivesNotAllowed(
            true
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        _armGrace();

        _deposit(
            user1,
            LARGE
        );

        AdminFacet(address(diamond)).pauseDeposits();

        bytes4 selector = UserFacet.deposit.selector;

        PinnedPrefixView memory seen = _probe().probeReadPinned(
            user1,
            selector
        );

        assertEq(
            seen.master,
            address(this)
        );
        assertEq(
            seen.proposedMaster,
            newMaster
        );
        assertEq(
            seen.paused,
            true
        );
        assertEq(
            seen.balance,
            diamond.balanceOf(
                user1
            )
        );
        assertGt(
            seen.balance,
            0
        );
        assertEq(
            seen.routedFacet,
            diamond.selectorToFacet(
                selector
            )
        );
        assertTrue(
            seen.routedFacet != address(0)
        );
        assertEq(
            seen.router,
            router
        );
        assertEq(
            seen.hookFacet,
            address(hookFacet)
        );
        assertEq(
            seen.graceDuration,
            GRACE
        );
        assertEq(
            seen.largeDepositAt,
            block.timestamp
        );
        assertEq(
            seen.graceFreeze,
            true
        );
    }

    function test_pinnedPrefix_writesReadByDiamondGenesisGetters()
        public
    {
        QueueAdminFacet(address(diamond)).setNegativeIncentivesNotAllowed(
            true
        );

        uint256 supplyBefore = diamond.totalSupply();

        address depositHookBefore = diamond.depositHookFacet();

        bytes4 selector = bytes4(0x12345678);

        PinnedPrefixView memory written = PinnedPrefixView({
            master: address(0),
            proposedMaster: newMaster,
            paused: true,
            balance: 777,
            routedFacet: address(0xF1),
            router: router,
            hookFacet: address(0xF2),
            graceDuration: GRACE,
            largeDepositAt: 1_700_000_000,
            graceFreeze: true
        });

        _probe().probeWritePinned(
            written,
            user2,
            selector
        );

        assertEq(
            diamond.master(),
            address(this)
        );
        assertEq(
            diamond.proposedMaster(),
            newMaster
        );
        assertEq(
            diamond.paused(),
            true
        );
        assertEq(
            diamond.balanceOf(
                user2
            ),
            777
        );
        assertEq(
            diamond.totalSupply(),
            supplyBefore
        );
        assertEq(
            diamond.selectorToFacet(
                selector
            ),
            address(
                0xF1
            )
        );
        assertEq(
            diamond.ccipRouter(),
            router
        );
        assertEq(
            diamond.negativeIncentivesNotAllowed(),
            true
        );
        assertEq(
            diamond.transferHookFacet(),
            address(0xF2)
        );
        assertEq(
            diamond.gracePeriodDuration(),
            GRACE
        );
        assertEq(
            diamond.lastLargeDepositAt(
                user2
            ),
            1_700_000_000
        );
        assertEq(
            diamond.graceFreezeEnabled(),
            true
        );
        assertEq(
            diamond.depositHookFacet(),
            depositHookBefore
        );
    }

    function test_pinnedLock_slimLockRefusesFullChainEntry()
        public
    {
        bytes memory reason = _probe().probeLockedCall(
            abi.encodeCall(
                UserFacet.deposit,
                (1)
            )
        );

        assertEq(
            reason,
            _reentrantReason()
        );

        assertEq(
            _probe().probeLockOpen(),
            true
        );

        _deposit(
            user1,
            LARGE
        );

        assertGt(
            diamond.balanceOf(
                user1
            ),
            0
        );
    }

    function test_pinnedLock_fullChainLockRefusesSlimFlush()
        public
    {
        ReenteringUSD reUsd = new ReenteringUSD();

        WiseSovrenNodesDiamond d = _buildSlimDiamond(
            address(reUsd)
        );

        address[] memory refs = _oneRef(
            refA
        );

        reUsd.arm(
            address(d),
            abi.encodeCall(
                CohortFlushFacet.flushReferrals,
                (refs)
            )
        );

        reUsd.mint(
            user1,
            LARGE
        );

        vm.prank(
            user1
        );

        reUsd.approve(
            address(d),
            LARGE
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            bytes("ReentrancyGuard: reentrant call")
        );

        UserFacet(address(d)).deposit(
            LARGE
        );
    }

    function test_pinnedPause_diamondPauseStopsSlimFlush()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        CohortFlushFacet(address(diamond)).flushReferrals(
            refs
        );
    }

    function test_pinnedGrace_slimHookEnforcesDiamondFreeze()
        public
    {
        _armGrace();

        _deposit(
            user1,
            LARGE
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            user2,
            1e6
        );

        vm.warp(
            block.timestamp + GRACE
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1e6
        );

        assertEq(
            diamond.balanceOf(
                user2
            ),
            1e6
        );
    }

    function test_pinnedTransient_fullChainBracketReachesSlimHook()
        public
    {
        usd.mint(
            user1,
            LARGE
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            LARGE
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            LARGE,
            refA
        );

        assertEq(
            CohortRecorderFacet(address(diamond)).getTrackedContribution(
                user1
            ),
            LARGE
        );
    }

    function test_pinnedHook_slimFlushBubblesHookRevert()
        public
    {
        usd.mint(
            user1,
            LARGE
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            LARGE
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            LARGE,
            refA
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new RevertingHookStub())
        );

        vm.warp(
            block.timestamp + 3 days
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            HookStubFailed.selector
        );

        CohortFlushFacet(address(diamond)).flushReferrals(
            refs
        );
    }
}
