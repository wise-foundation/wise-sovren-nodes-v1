// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortLaneHarness} from "./utils/CohortLaneHarness.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

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

/**
 * @dev Coverage-closure suite for the cohort recorder (pattern:
 * {WiseSovrenNodesAdminCoverage}): the residual arms the behavioral
 * suites cannot reach through normal drivers: the `NotHookExecution`
 * guard on an engine entrypoint reached OUTSIDE the transient
 * `hookExecuting` bracket (requires deliberately routing an engine
 * selector, which production never does); the `getCohortSyncEnabled`
 * view through the routed dispatcher; the credit-path book-lane clip
 * (a saturating Y1 add during `_creditRingCohort`, distinct from the
 * rotate/reduce clips the saturation suite covers); the reduction
 * walk below one ring revolution, where the modular slot index wraps
 * through the slots above the settle week and still reaches the
 * oldest live slot `(week + 1) % 52` on both rings, exactly as on a
 * real chain clock; the two clip arms a flip
 * relocation can meet (a ring lane mirrored above its book lane,
 * where the sale core clips the old lane while the full ring take
 * lands at its own slot in the new referrer's rings, and an attributed
 * amount no lane covers, where the mature lane clips and nothing
 * lands), both barred on wired state because ring sums equal book
 * lanes and the referees' attributed sum equals the book, and both
 * checked by the invariant suites only outside a relocation, so both
 * arms are pinned here directly; the flip relocation's 104-pair
 * capture with every ring slot populated, replanted slot for slot in
 * the new referrer's rings; and a sync against an unset registry
 * pointer, which reads as a failed lookup and defers the clamp with
 * tracked and attributed contribution unchanged.
 */
contract WiseSovrenNodesCohortCoverageTest is DiamondTestHarness {

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            3_000 weeks + 1 hours
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
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
    }

    function test_engineEntrypoint_outsideHookBracket_reverts()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        CohortHookFacet hook = new CohortHookFacet();

        bytes4[] memory sels = new bytes4[](1);

        sels[0] = CohortHookFacet.applyCohortSync.selector;

        bare.proposeSelectors(
            sels,
            address(hook)
        );

        bare.executeSelectorChanges(
            sels
        );

        bare.finalizeSetup();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortHookFacet(payable(address(bare))).applyCohortSync(
            user1
        );
    }

    function test_engineEntrypoints_outsideHookBracket_allRevert()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        CohortHookFacet hook = new CohortHookFacet();

        bytes4[] memory sels = new bytes4[](5);

        sels[0] = CohortHookFacet.applyTransferHook.selector;
        sels[1] = CohortHookFacet.applyCohortCredit.selector;
        sels[2] = CohortHookFacet.applyCohortAdvance.selector;
        sels[3] = CohortHookFacet.applyCohortMoveOut.selector;
        sels[4] = CohortHookFacet.applyCohortMoveIn.selector;

        bare.proposeSelectors(
            sels,
            address(hook)
        );

        bare.executeSelectorChanges(
            sels
        );

        bare.finalizeSetup();

        CohortHookFacet routed = CohortHookFacet(
            payable(address(bare))
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        routed.applyTransferHook(
            user1,
            address(0xB0B)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        routed.applyCohortCredit(
            user1,
            1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        routed.applyCohortAdvance(
            user1,
            1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        routed.applyCohortMoveOut(
            user1,
            address(diamond),
            0,
            0,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        routed.applyCohortMoveIn(
            user1,
            address(diamond)
        );
    }

    function test_getCohortSyncEnabled_tracksArmSwitch()
        public
    {
        CohortRecorderFacet recorder = CohortRecorderFacet(
            address(diamond)
        );

        assertFalse(
            recorder.getCohortSyncEnabled()
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        assertTrue(
            recorder.getCohortSyncEnabled()
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        assertFalse(
            recorder.getCohortSyncEnabled()
        );
    }

    function test_creditRing_bookLaneClipEmitsAnomaly()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetBookLanes(
            refA,
            CohortWeeks.LANE_MASK_80 - 5,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            95
        );

        harness.exposedCreditRing(
            refA,
            100
        );

        assertEq(
            CohortWeeks._laneY1(
                harness.viewBookWord(
                    refA
                )
            ),
            CohortWeeks.LANE_MASK_80
        );
    }

    function test_zeroAmountCredit_isSilentNoop()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        ReferralRegistry laneRegistry = new ReferralRegistry(
            address(this),
            0
        );

        laneRegistry.setAllowedVault(
            address(harness),
            true
        );

        harness.harnessSetRegistry(
            address(laneRegistry)
        );

        harness.harnessSetReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        harness.exposedCreditContribution(
            user1,
            0
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            harness.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_syncReferee_unsetRegistryPointer_defersClampAsFailedLookup()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetTracked(
            user1,
            500
        );

        harness.harnessMintBalance(
            user1,
            200
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        harness.exposedSyncReferee(
            user1
        );

        assertEq(
            harness.viewTracked(
                user1
            ),
            500
        );

        assertEq(
            harness.viewAttributed(
                user1
            ),
            500
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_reduceWalk_ringMirrorClipEmitsBookAnomaly()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetRingYear1(
            refA,
            (block.timestamp / 1 weeks) % 52,
            100
        );

        harness.harnessSetBookLanes(
            refA,
            50,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            50
        );

        harness.exposedReduceBook(
            refA,
            100
        );

        assertEq(
            CohortWeeks._laneY1(
                harness.viewBookWord(
                    refA
                )
            ),
            0
        );
    }

    function test_reduceWalk_belowOneRingRevolution_visitsOldestLiveSlot()
        public
    {
        vm.warp(
            2 weeks + 1 hours
        );

        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetRingYear1(
            refA,
            2,
            1_000
        );

        harness.harnessSetRingYear1(
            refA,
            3,
            400
        );

        harness.harnessSetRingYear2(
            refA,
            3,
            600
        );

        harness.harnessSetBookLanes(
            refA,
            1_400,
            600,
            0
        );

        harness.exposedReduceBook(
            refA,
            2_000
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refA,
                    2
                )
            ),
            0
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refA,
                    3
                )
            ),
            0
        );

        assertEq(
            uint256(
                harness.viewRingYear2(
                    refA,
                    3
                )
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_flipRelocation_allSlotsPopulated_replantsEverySlot()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        for (uint256 slot; slot < CohortWeeks.RING_SLOTS; ++slot) {

            harness.harnessSetRingYear1(
                refA,
                slot,
                1
            );

            harness.harnessSetRingYear2(
                refA,
                slot,
                1
            );
        }

        harness.harnessSetBookLanes(
            refA,
            CohortWeeks.RING_SLOTS,
            CohortWeeks.RING_SLOTS,
            0
        );

        harness.harnessSetTracked(
            user1,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        harness.harnessMintBalance(
            user1,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            CohortWeeks.RING_SLOTS,
            CohortWeeks.RING_SLOTS,
            0,
            CohortWeeks.MAX_CARRY_PAIRS
        );

        harness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        for (uint256 slot; slot < CohortWeeks.RING_SLOTS; ++slot) {

            assertEq(
                uint256(
                    harness.viewRingYear1(
                        refA,
                        slot
                    )
                ),
                0
            );

            assertEq(
                uint256(
                    harness.viewRingYear2(
                        refA,
                        slot
                    )
                ),
                0
            );

            assertEq(
                uint256(
                    harness.viewRingYear1(
                        refB,
                        slot
                    )
                ),
                1
            );

            assertEq(
                uint256(
                    harness.viewRingYear2(
                        refB,
                        slot
                    )
                ),
                1
            );
        }

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harness.viewBookWord(
                    refB
                )
            ),
            CohortWeeks.RING_SLOTS
        );

        assertEq(
            CohortWeeks._laneY2(
                harness.viewBookWord(
                    refB
                )
            ),
            CohortWeeks.RING_SLOTS
        );
    }

    function test_flipRelocation_ringMirrorClip_landsFullTakeAtItsSlot()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        uint256 slot = (block.timestamp / 1 weeks + 3) % 52;

        uint256 landSlot = (block.timestamp / 1 weeks + 1) % 52;

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetRingYear1(
            refA,
            slot,
            100
        );

        harness.harnessSetBookLanes(
            refA,
            50,
            0,
            0
        );

        harness.harnessSetTracked(
            user1,
            100
        );

        harness.harnessMintBalance(
            user1,
            100
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            50
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            100,
            0,
            0,
            1
        );

        harness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refA,
                    slot
                )
            ),
            0
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refB,
                    slot
                )
            ),
            100
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refB,
                    landSlot
                )
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                harness.viewBookWord(
                    refB
                )
            ),
            100
        );
    }

    function test_flipRelocation_emptyOldBook_clipsMatureAndLandsNothing()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetTracked(
            user1,
            100
        );

        harness.harnessMintBalance(
            user1,
            100
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            5,
            0,
            100
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(harness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            0,
            0,
            0,
            0
        );

        harness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refB
            ),
            0
        );
    }
}
