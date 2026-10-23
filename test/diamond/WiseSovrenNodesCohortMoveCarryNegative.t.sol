// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev A peer mock whose `mintFromPeer` always reverts, standing in
 * for a bricked or malicious destination. `decimals()` is fixed at 6
 * so `_peerScaleFactors` reads a plain 1:1 scale against the harness
 * vaults.
 */
contract RevertingPeerVault {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mintFromPeer(
        address,
        uint256
    )
        external
        pure
    {
        revert(
            "RevertingPeerVault: reverts"
        );
    }
}

/**
 * @dev A peer mock that calls back into the caller's own
 * `moveBetweenVaults` from inside `mintFromPeer`: `msg.sender` at
 * that point is the source diamond itself (a delegatecall-routed
 * facet call always presents the diamond's address to the callee),
 * so the callback re-enters the diamond that is still mid-move.
 */
contract ReentrantPeerVault {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mintFromPeer(
        address,
        uint256 _amount
    )
        external
    {
        MoveFacet(msg.sender).moveBetweenVaults(
            address(this),
            _amount
        );
    }
}

/**
 * @dev A peer mock that accepts `mintFromPeer` as a silent no-op;
 * it never applies any cohort attribution, mirroring a real
 * destination diamond that has not yet installed the cohort recorder
 * at all. Proves a source-side stage can outlive a peer that will
 * never consume it.
 */
contract NoCohortPeerVault {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mintFromPeer(
        address,
        uint256
    )
        external
    {}
}

/**
 * @dev A peer mock with `decimals() == 4`, two less than the
 * harness vaults' 6, so the same-chain scale factor is `1 / 100`,
 * enough to exercise per-component floor scaling on a tiny move
 * without needing a second real diamond.
 */
contract LowDecimalsPeerVault {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 4;
    }

    function mintFromPeer(
        address,
        uint256
    )
        external
    {}
}

/**
 * @dev A routed move slice that always reverts. The pointer facet's
 * forwarder must bubble that revert unchanged, so a move through it
 * fails with this contract's error and changes nothing.
 */
contract RevertingMoveHookSlice {

    error MoveSliceReverted();

    function applyCohortMoveOut(
        address,
        address,
        uint256,
        uint256,
        uint256
    )
        external
        payable
    {
        revert MoveSliceReverted();
    }

    function applyCohortMoveIn(
        address,
        address
    )
        external
        payable
    {
        revert MoveSliceReverted();
    }
}

/**
 * @dev Full-diamond negative-space suite for the same-chain move-carry
 * seam, complementing the engine-level failure injection
 * already covered in WiseSovrenNodesCohortCarryEngineTest. Every
 * test here drives a REAL moveBetweenVaults call across two real
 * diamonds (or one real diamond against a hostile peer mock) and
 * asserts the same doctrine the engine proves in isolation: the move
 * itself (burn on the source, mint on the destination) must never
 * be blocked by attribution machinery (the never-block doctrine
 * extended to the move
 * path), and every non-applied carry degrades soft into an anomaly
 * event rather than a fund-affecting revert. The one exception is a
 * genuinely PAUSED destination, which is a deliberate operational
 * halt of the move itself, not an attribution failure; that case is
 * expected to revert the whole move atomically and leave the source
 * untouched. An unarmed counterparty (source or destination) makes
 * its half of the carry seam a structural no-op, which orphans a
 * staged payload in the shared registry rather than discarding it;
 * the orphan is provably inert (stagedAt only ever matches a
 * DIFFERENT move's block.timestamp) and a later real move to the same
 * (srcVault, dstVault, user) key overwrites it via the registry's
 * delete-then-write, never accumulating stale credit. Hostile peers
 * (reverting, reentrant, silently no-op) and a hostile registry
 * (codeful but always-reverting) are driven directly against one real
 * diamond to pin the trust boundary at the peer/registry seam rather
 * than at the cohort engine itself. The unreferred mover is pinned
 * beyond the full exit: a partial move splits tracked exactly into
 * the kept and moved slices and the wash returns it to the origin,
 * with the zero-referrer book untouched on both vaults and both
 * mailbox directions drained; a mover carrying a lazy deficit from an
 * earlier transfer has that deficit clamped sale-like by the pre-burn
 * sync first, after which the carry relocates exactly the burned
 * remainder and nothing else. The routed move slice is pinned on
 * both ends: zero-routed on the source, the pointer facet clamps the
 * mover sale-like and skips the carry; zero-routed on the
 * destination, the degraded destination emits CohortCarryDiscarded
 * with a zero staged-at and books nothing (a routed destination
 * finding nothing staged books and emits nothing), while the staged
 * payload stays readable in the registry; a direct external call to
 * either routed entrypoint reverts, and a routed slice that reverts
 * makes the move revert with that error, bubbled unchanged through
 * the forwarder. A registry pointer cleared while
 * the recorder stays armed (written directly, because the AdminFacet
 * refuses a registry change while armed) reads as a failed lookup:
 * the carry is skipped and the clamp is deferred, so the mover's
 * tracked and attributed contribution stand unchanged. A routed move
 * settles the mover's self crumb at both ends before either tracked
 * write: the source word to the move instant at the pre-clamp stake,
 * and the destination word stamped at the landing with no history
 * before the carried tracked delta lands.
 */
contract WiseSovrenNodesCohortMoveCarryNegativeTest is TwoVaultCohortHarness {

    event CohortCarryStaged(
        address indexed user,
        address indexed dstVault,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortCarryApplied(
        address indexed user,
        address indexed srcVault,
        address indexed referrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortCarrySkipped(
        address indexed user,
        address indexed dstVault
    );

    event CohortCarryDiscarded(
        address indexed user,
        address indexed srcVault,
        uint256 stagedAt
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    uint256 internal constant REFERRAL_REGISTRY_SLOT = 77;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant MOVE_AMOUNT = 2_000 * 1e6;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();
    }

    // ---- helpers ----

    function _assertZeroReferrerBookUntouched()
        internal
        view
    {
        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                address(0)
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                address(0)
            ),
            0
        );

        (
            uint256 year1A,
            uint256 year2A,
            uint256 matureA,
        ) = _recorderOf(vaultA).getCohortBook(address(0));

        assertEq(
            year1A,
            0
        );

        assertEq(
            year2A,
            0
        );

        assertEq(
            matureA,
            0
        );

        (
            uint256 year1B,
            uint256 year2B,
            uint256 matureB,
        ) = _recorderOf(vaultB).getCohortBook(address(0));

        assertEq(
            year1B,
            0
        );

        assertEq(
            year2B,
            0
        );

        assertEq(
            matureB,
            0
        );
    }

    function _assertCarryDrained(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst
    )
        internal
        view
    {
        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(_src),
            address(_dst),
            user1
        );

        assertEq(
            stagedAt,
            0
        );

        assertEq(
            payload.length,
            0
        );
    }

    function _assertSelfCrumbOn(
        WiseSovrenNodesDiamond _d,
        address _user,
        uint256 _settledAt,
        uint256 _current,
        uint256 _previous
    )
        internal
        view
    {
        (
            uint256 settledAt,
            uint256 current,
            uint256 previous
        ) = _recorderOf(_d).getCohortSelfCrumb(
            _user
        );

        assertEq(
            settledAt,
            _settledAt
        );

        assertEq(
            current,
            _current
        );

        assertEq(
            previous,
            _previous
        );
    }

    function _discardCountOn(
        Vm.Log[] memory _logs,
        WiseSovrenNodesDiamond _vault
    )
        internal
        pure
        returns (uint256 count)
    {
        bytes32 topic = keccak256(
            "CohortCarryDiscarded(address,address,uint256)"
        );

        for (uint256 i; i < _logs.length; ++i) {

            if (_logs[i].topics.length == 0) {
                continue;
            }

            if (_logs[i].emitter == address(_vault) && _logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    // ---- destination not armed: source clamps, orphan inert until overwritten ----

    function test_move_destinationNotArmed_sourceClampsCarryOrphaned()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 firstMoveTimestamp = block.timestamp;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortCarryStaged(
            user1,
            address(vaultB),
            refA,
            MOVE_AMOUNT,
            MOVE_AMOUNT,
            0,
            0,
            1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        (
            uint256 year1AfterFirst,
            ,
            ,
        ) = _recorderOf(vaultA).getCohortBook(refA);

        assertEq(
            year1AfterFirst,
            DEPOSIT - MOVE_AMOUNT
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultB,
                refA,
                user1
            )
        );

        (
            uint256 orphanStagedAt,
            uint256[] memory orphanPayload
        ) = registry.getCarry(
            address(vaultA),
            address(vaultB),
            user1
        );

        assertEq(
            orphanStagedAt,
            firstMoveTimestamp
        );

        assertGt(
            orphanPayload.length,
            0
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            block.timestamp + 1
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            1_000 * 1e6
        );

        (
            uint256 year1B,
            ,
            ,
        ) = _recorderOf(vaultB).getCohortBook(refA);

        assertEq(
            year1B,
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            1_000 * 1e6
        );

        (
            uint256 stagedAtAfterOverwrite,
        ) = registry.getCarry(
            address(vaultA),
            address(vaultB),
            user1
        );

        assertEq(
            stagedAtAfterOverwrite,
            0
        );
    }

    // ---- source not armed: destination sees an empty mailbox ----

    function test_move_sourceNotArmed_destinationEmptyMailboxSilent()
        public
    {
        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            0
        );

        vm.recordLogs();

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            _discardCountOn(
                vm.getRecordedLogs(),
                vaultB
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- paused destination reverts the whole move atomically ----

    function test_move_destinationPaused_revertsAtomicallySourceUntouched()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        AdminFacet(address(vaultB)).pauseDeposits();

        CohortSnap memory snapBefore = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refA,
                user1
            ),
            snapBefore
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(vaultA),
            address(vaultB),
            user1
        );

        assertEq(
            stagedAt,
            0
        );

        assertEq(
            payload.length,
            0
        );
    }

    // ---- both unarmed: genesis parity, zero cohort topics ----

    function test_move_bothUnarmed_behavesExactlyAsGenesis()
        public
    {
        vm.recordLogs();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            MOVE_AMOUNT
        );

        bytes32[5] memory cohortTopics = [
            keccak256("CohortCarryStaged(address,address,address,uint256,uint256,uint256,uint256,uint256)"),
            keccak256(
                "CohortCarryApplied(address,address,address,address,uint256,uint256,uint256,uint256,uint256)"
            ),
            keccak256(
                "CohortCarrySkipped(address,address)"
            ),
            keccak256(
                "CohortCarryDiscarded(address,address,uint256)"
            ),
            keccak256(
                "CohortContributionSynced(address,address,uint256,uint256)"
            )
        ];

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 cohortTopicCount;

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics.length == 0) {
                continue;
            }

            for (uint256 j; j < cohortTopics.length; ++j) {

                if (logs[i].topics[0] == cohortTopics[j]) {
                    ++cohortTopicCount;
                }
            }
        }

        assertEq(
            cohortTopicCount,
            0
        );
    }

    // ---- unreferred mover: tracked-only carry, book untouched ----

    function test_move_unreferredUser_trackedCarriesNoBookTouched()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortCarryApplied(
            user1,
            address(vaultA),
            address(0),
            address(0),
            DEPOSIT,
            0,
            0,
            0,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        _assertScheduleEmpty(
            _captureCohort(
                vaultA,
                address(0),
                user1
            )
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        (
            uint256 year1B,
            uint256 year2B,
            uint256 matureB,
        ) = _recorderOf(vaultB).getCohortBook(address(0));

        assertEq(
            year1B,
            0
        );

        assertEq(
            year2B,
            0
        );

        assertEq(
            matureB,
            0
        );
    }

    // ---- unreferred mover: partial split, wash restores ----

    function test_move_unreferredUser_partial_trackedSplitsAndWashRestores()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortCarryStaged(
            user1,
            address(vaultB),
            address(0),
            MOVE_AMOUNT,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortCarryApplied(
            user1,
            address(vaultA),
            address(0),
            address(0),
            MOVE_AMOUNT,
            0,
            0,
            0,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            MOVE_AMOUNT
        );

        _assertZeroReferrerBookUntouched();

        _assertCarryDrained(
            vaultA,
            vaultB
        );

        _moveAs(
            user1,
            vaultB,
            vaultA,
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT
        );

        _assertZeroReferrerBookUntouched();

        _assertCarryDrained(
            vaultA,
            vaultB
        );

        _assertCarryDrained(
            vaultB,
            vaultA
        );
    }

    // ---- unreferred mover with a lazy deficit: clamp first, carry the remainder ----

    function test_move_unreferredUser_withLazyDeficit_clampsThenCarriesRemainder()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT - 1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            address(0),
            DEPOSIT,
            DEPOSIT - 1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortCarryStaged(
            user1,
            address(vaultB),
            address(0),
            MOVE_AMOUNT,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortCarryApplied(
            user1,
            address(vaultA),
            address(0),
            address(0),
            MOVE_AMOUNT,
            0,
            0,
            0,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        uint256 trackedA = _recorderOf(vaultA).getTrackedContribution(
            user1
        );

        uint256 trackedB = _recorderOf(vaultB).getTrackedContribution(
            user1
        );

        uint256 heldA = vaultA.balanceOf(
            user1
        );

        assertEq(
            trackedA,
            MOVE_AMOUNT
        );

        assertEq(
            trackedA,
            heldA
        );

        assertEq(
            trackedB,
            MOVE_AMOUNT
        );

        assertEq(
            trackedA + trackedB,
            DEPOSIT - 1_000 * 1e6
        );

        _assertZeroReferrerBookUntouched();

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                outsider
            ),
            0
        );
    }

    // ---- hostile peers ----

    function test_move_revertingPeer_revertsAtomicallySourceUntouched()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        RevertingPeerVault hostile = new RevertingPeerVault();

        MoveFacet(address(vaultA)).proposePeerVault(
            address(hostile)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(hostile)
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        CohortSnap memory snapBefore = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.expectRevert(
            bytes("RevertingPeerVault: reverts")
        );

        vm.prank(
            user1
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(hostile),
            MOVE_AMOUNT
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refA,
                user1
            ),
            snapBefore
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(vaultA),
            address(hostile),
            user1
        );

        assertEq(
            stagedAt,
            0
        );

        assertEq(
            payload.length,
            0
        );
    }

    function test_move_reentrantPeer_revertsAtomicallySourceUntouched()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        ReentrantPeerVault hostile = new ReentrantPeerVault();

        MoveFacet(address(vaultA)).proposePeerVault(
            address(hostile)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(hostile)
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        CohortSnap memory snapBefore = _captureCohort(
            vaultA,
            refA,
            user1
        );

        vm.expectRevert(
            bytes("ReentrancyGuard: reentrant call")
        );

        vm.prank(
            user1
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(hostile),
            MOVE_AMOUNT
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refA,
                user1
            ),
            snapBefore
        );
    }

    function test_move_noCohortPeer_sourceStagesOrphanFundsUnaffected()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        NoCohortPeerVault mock = new NoCohortPeerVault();

        MoveFacet(address(vaultA)).proposePeerVault(
            address(mock)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(mock)
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortCarryStaged(
            user1,
            address(mock),
            refA,
            MOVE_AMOUNT,
            MOVE_AMOUNT,
            0,
            0,
            1
        );

        vm.prank(
            user1
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(mock),
            MOVE_AMOUNT
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(vaultA),
            address(mock),
            user1
        );

        assertGt(
            stagedAt,
            0
        );

        assertGt(
            payload.length,
            0
        );
    }

    // ---- hostile registry: codeful but always-reverting ----

    function test_move_registryEtchedHostile_moveSucceedsCarrySkippedThenRecovers()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortCarrySkipped(
            user1,
            address(vaultB)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(vaultA),
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        vm.etch(
            address(registry),
            realCode
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            vaultA.balanceOf(
                user1
            )
        );
    }

    // ---- replant saturation on a trusted-peer synthetic payload ----

    function test_move_replantSaturation_atThePairSlot_clipsNeverReverts()
        public
    {
        _armBoth();

        MoveFacet(address(vaultB)).proposePeerVault(
            address(this)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultB)).executePeerVaultChange(
            address(this)
        );

        registry.setAllowedVault(
            address(this),
            true
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT,
            refA
        );

        uint256 depositSlot = (block.timestamp / 1 weeks) % 52;

        vm.warp(
            block.timestamp + 51 weeks
        );

        uint256 landSlot = (block.timestamp / 1 weeks + 1) % 52;

        uint256 pairSlot = (block.timestamp / 1 weeks) % 52;

        assertEq(
            landSlot,
            depositSlot
        );

        uint256[] memory payload = new uint256[](3);

        payload[0] = CohortWeeks._packCarryEnvelope(
            refA,
            1
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            CohortWeeks.RING_LANE_MAX,
            0
        );

        payload[2] = CohortWeeks._packCarryPair(
            CohortWeeks.RING_LANE_MAX,
            landSlot,
            CohortWeeks.CARRY_RING_YEAR1
        );

        registry.stageCarry(
            address(vaultB),
            user1,
            payload
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultB)
        );

        emit CohortLaneSaturated(
            refA,
            0,
            landSlot,
            DEPOSIT
        );

        MoveFacet(address(vaultB)).mintFromPeer(
            user1,
            CohortWeeks.RING_LANE_MAX
        );

        (
            uint64[52] memory ring1,
        ) = _recorderOf(vaultB).getCohortRings(refA);

        assertEq(
            ring1[landSlot],
            uint64(CohortWeeks.RING_LANE_MAX)
        );

        assertEq(
            ring1[pairSlot],
            0
        );

        (
            uint256 year1,
            ,
            ,
        ) = _recorderOf(vaultB).getCohortBook(refA);

        assertEq(
            year1,
            DEPOSIT + CohortWeeks.RING_LANE_MAX
        );

        assertLe(
            year1,
            CohortWeeks.LANE_MASK_80
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT + CohortWeeks.RING_LANE_MAX
        );
    }

    // ---- dust decimals never inflate the destination ----

    function test_move_dustDecimals_neverCreatesCredit()
        public
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        LowDecimalsPeerVault mock = new LowDecimalsPeerVault();

        MoveFacet(address(vaultA)).proposePeerVault(
            address(mock)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(mock)
        );

        uint256 depositAmount = DEPOSIT + 33;

        _depositWithReferralOn(
            vaultA,
            user1,
            depositAmount,
            refA
        );

        vm.prank(
            user1
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(mock),
            1_033
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            depositAmount - 1_033
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(vaultA),
            address(mock),
            user1
        );

        assertGt(
            stagedAt,
            0
        );

        assertLe(
            CohortWeeks._carryTrackedDelta(
                payload[1]
            ),
            10
        );
    }

    // ---- move slice not routed ----

    function test_moveOut_revertInsideRoutedSlice_bubblesThroughForwarder()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors();

        vaultA.proposeSelectors(
            sels,
            address(new RevertingMoveHookSlice())
        );

        vm.warp(
            block.timestamp + SELECTOR_CHANGE_DELAY
        );

        vaultA.executeSelectorChanges(
            sels
        );

        vm.expectRevert(
            RevertingMoveHookSlice.MoveSliceReverted.selector
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );
    }

    function test_moveOut_sliceUnroutedOnSource_clampsAndSkipsCarry()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _unrouteMoveHook(
            vaultA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            DEPOSIT,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortCarrySkipped(
            user1,
            address(vaultB)
        );

        vm.recordLogs();

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT
        );

        assertEq(
            _discardCountOn(
                vm.getRecordedLogs(),
                vaultB
            ),
            0
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            0
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        _assertCarryDrained(
            vaultA,
            vaultB
        );
    }

    function test_moveIn_sliceUnroutedOnDestination_discardsWithZeroStagedAt()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _unrouteMoveHook(
            vaultB
        );

        uint256 moveTimestamp = block.timestamp;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortCarryStaged(
            user1,
            address(vaultB),
            refA,
            MOVE_AMOUNT,
            MOVE_AMOUNT,
            0,
            0,
            1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortCarryDiscarded(
            user1,
            address(vaultA),
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        (
            uint256 stagedAt,
            uint256[] memory payload
        ) = registry.getCarry(
            address(vaultA),
            address(vaultB),
            user1
        );

        assertEq(
            stagedAt,
            moveTimestamp
        );

        assertGt(
            payload.length,
            0
        );
    }

    function test_RevertWhen_applyCohortMoveOut_calledDirectly()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortMoveHookFacet(address(vaultA)).applyCohortMoveOut(
            user1,
            address(vaultB),
            MOVE_AMOUNT,
            1,
            1
        );
    }

    function test_RevertWhen_applyCohortMoveIn_calledDirectly()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortMoveHookFacet(address(vaultB)).applyCohortMoveIn(
            user1,
            address(vaultA)
        );
    }

    // ---- registry pointer cleared while armed: carry skipped, clamp deferred ----

    function test_moveOut_zeroRegistryPointerWhileArmed_skipsCarryWithoutClamp()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 attributedBefore = _recorderOf(vaultA).getAttributedContribution(
            user1
        );

        vm.store(
            address(vaultA),
            bytes32(REFERRAL_REGISTRY_SLOT),
            bytes32(0)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortCarrySkipped(
            user1,
            address(vaultB)
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            MOVE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            attributedBefore
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        _assertCarryDrained(
            vaultA,
            vaultB
        );
    }

    // ---- self crumb settled at both ends of a routed move ----

    function test_moveOut_settlesSourceSelfCrumbBeforeClamp_andDestinationBeforeLanding()
        public
    {
        _armBoth();

        uint256 moved = DEPOSIT / 2;

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        uint256 moveAt = block.timestamp;

        _moveAs(
            user1,
            vaultA,
            vaultB,
            moved
        );

        _assertSelfCrumbOn(
            vaultA,
            user1,
            moveAt,
            DEPOSIT * (moveAt - boundary),
            DEPOSIT * (boundary - depositAt)
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - moved
        );

        _assertSelfCrumbOn(
            vaultB,
            user1,
            moveAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            moved
        );
    }

    // ---- moved-amount pins: self log on move, unreferred move crumbs ----

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    function test_moveOut_logsTheCompletedSelfWeekOnTheSourceOnly()
        public
    {
        _armBoth();

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortSelfLogged(
            user1,
            depositAt / CohortWeeks.WEEK,
            DEPOSIT * (boundary - depositAt),
            DEPOSIT
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            DEPOSIT / 2
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fromB;

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(vaultB)
                    && logs[i].topics[0] == CohortSelfLogged.selector
            ) {
                ++fromB;
            }
        }

        assertEq(
            fromB,
            0
        );
    }

    function test_move_unreferredUser_settlesBothCrumbsAttributesNothing()
        public
    {
        _armBoth();

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        uint256 moveAt = block.timestamp;

        _moveAs(
            user1,
            vaultA,
            vaultB,
            MOVE_AMOUNT
        );

        _assertSelfCrumbOn(
            vaultA,
            user1,
            moveAt,
            DEPOSIT * (moveAt - boundary),
            DEPOSIT * (boundary - depositAt)
        );

        _assertSelfCrumbOn(
            vaultB,
            user1,
            moveAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            MOVE_AMOUNT
        );

        _assertZeroReferrerBookUntouched();
    }
}
