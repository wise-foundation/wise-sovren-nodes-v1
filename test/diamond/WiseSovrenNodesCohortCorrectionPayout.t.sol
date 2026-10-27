// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {IReferralHub} from "../referral/hub/IReferralHub.sol";
import {HubLeverGrants} from "../referral/hub/utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../referral/hub/utils/HubDiamondHarness.sol";

import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../referral/registry/ReferralRegistryDeclarations.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

/**
 * @dev Six-decimal mintable USD stand-in backing the hub claim tests.
 */
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
 * @dev Referrer corrections in the world after payouts arm, over a
 * real diamond (the cohort recorder behind the cohort transfer hook),
 * a real {ReferralRegistry} and a real standalone {ReferralHub} fed
 * only through its public reporter surface (`deliverCrumbs`, reported
 * by `address(this)`, the same inline
 * reporting shape as `test/hub/ReferralHubRecorderIntegration.t.sol`,
 * whose setUp and helpers this suite copies). Every expected payout
 * is recomputed in the test from the crumb words the recorder wrote
 * and the rates the hub's own `weeklyRates` view answers.
 *
 * The setUp ends with `latchSeeds`: payouts arm only after the seed
 * latch fired, and that latch retires the retroactive seed without
 * touching the correction lane, so every test here runs in exactly
 * the state a live registry is in once commission is being paid.
 *
 * Pins: a correction executed and poked after commission accrued
 * leaves the old referrer's hub bucket untouched and claimable, the
 * new referrer starts from an empty bucket, and the credit moves
 * whole to the new referrer's book; crumbs recorded before the poke
 * price under the old referrer even when delivered afterwards, the
 * new referrer's crumbs start at the poke second, and the poke week
 * is split between the two books without double counting (the old
 * referrer's crumb covers the week boundary to the poke second, the
 * new referrer's crumb covers the poke second to the next boundary,
 * and the relocated credit keeps its own slot, so from the next week on
 * it sits on the new referrer's year-1 lane at its own age; the landing
 * lane is pinned directly, year-one the full week, year-two zero,
 * mature zero, and the old referrer's settled crumbs re-read after the
 * poke equal the pre-poke snapshot);
 * the hub's week buckets follow each book, so the poke week splits
 * between the two referrers and from the next week on only the new
 * referrer's bucket holds the moved principal; a user veto (`cancelCorrectReferrer` by the user)
 * leaves the referrer, both books, the flip marker and both buckets
 * unchanged, and crumbs recorded after the veto keep pricing under
 * the old referrer; and in this world the seed reverts
 * {SeedingLatched} while a correction still proposes, executes and
 * migrates the credit.
 */
contract WiseSovrenNodesCohortCorrectionPayoutTest is DiamondTestHarness, HubDiamondHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant PRINCIPAL = 10_000 * 1e6;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    WiseSovrenNodesDiamond internal diamond;

    MockUSD internal usd;

    IReferralHub internal hub;

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
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
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortBridgeHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        hub = _deployHub(
            address(usd)
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        registry.latchSeeds();
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
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

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _plainDepositAs(
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

    function _expectedPay(
        uint256 _word,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        return (
            CohortWeeks._laneY1(_word) * y1Bps
                + CohortWeeks._laneY2(_word) * y2Bps
                + CohortWeeks._laneM(_word) * mBps
        ) / (10_000 * CohortWeeks.YEAR);
    }

    function _expectedPaySum(
        address _referrer,
        uint256[] memory _weeks,
        uint256[] memory _words
    )
        internal
        view
        returns (uint256 expected)
    {
        for (uint256 i; i < _weeks.length; ++i) {
            expected += _expectedPay(
                _words[i],
                _referrer,
                _weeks[i]
            );
        }
    }

    function _readCrumbs(
        address _referrer,
        uint256 _fromWeekInclusive,
        uint256 _count
    )
        internal
        view
        returns (
            uint256[] memory weeksOut,
            uint256[] memory wordsOut
        )
    {
        weeksOut = new uint256[](_count);
        wordsOut = new uint256[](_count);

        for (uint256 i; i < _count; ++i) {

            weeksOut[i] = _fromWeekInclusive + i;

            wordsOut[i] = _recorder().getCohortWeekCrumb(
                _referrer,
                weeksOut[i]
            );
        }
    }

    function _deliverCrumbChunk(
        address _referrer,
        uint256 _fromWeekInclusive,
        uint256 _toWeekInclusive
    )
        internal
    {
        uint256 count = _toWeekInclusive
            - _fromWeekInclusive
            + 1;

        uint256[] memory weeksBatch = new uint256[](count);

        uint256[] memory wordsBatch = new uint256[](count);

        for (uint256 i; i < count; ++i) {

            weeksBatch[i] = _fromWeekInclusive + i;

            wordsBatch[i] = _recorder().getCohortWeekCrumb(
                _referrer,
                weeksBatch[i]
            );
        }

        hub.deliverCrumbs(
            _referrer,
            _referrer,
            weeksBatch,
            wordsBatch
        );
    }

    function _accrueForOldReferrer()
        internal
        returns (uint256 bucket)
    {
        _depositWithReferralAs(
            user1,
            PRINCIPAL,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        _deliverCrumbChunk(
            refA,
            3_000,
            3_003
        );

        bucket = hub.claimable(
            block.chainid,
            refA
        );

        assertGt(
            bucket,
            0
        );
    }

    function _correctAndPoke()
        internal
    {
        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            block.timestamp + 3 days
        );

        registry.executeCorrectReferrer(
            user1
        );

        registry.pokeMigrationAt(
            user1,
            address(diamond)
        );
    }

    // ---- 1. the old referrer's accrued bucket survives the correction ----

    function test_correction_afterPayouts_oldReferrerBucketUntouchedAndClaimable()
        public
    {
        uint256 bucket = _accrueForOldReferrer();

        _correctAndPoke();

        assertEq(
            hub.claimable(block.chainid, refA),
            bucket
        );

        assertEq(
            hub.claimable(block.chainid, refB),
            0
        );

        assertEq(
            registry.referrerOf(user1),
            refB
        );

        assertEq(
            registry.pendingFlip(address(diamond), user1),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(refA),
            0
        );

        assertEq(
            _recorder().getCohortScore(refB),
            PRINCIPAL
        );

        usd.mint(
            address(hub),
            bucket
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(refA),
            bucket
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0
        );
    }

    // ---- 2. crumbs recorded before the poke stay with the old referrer ----

    function test_correction_afterPayouts_crumbsRecordedBeforePokeStayWithOldReferrer()
        public
    {
        _depositWithReferralAs(
            user1,
            PRINCIPAL,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            uint256[] memory oldWeeks,
            uint256[] memory oldWords
        ) = _readCrumbs(
            refA,
            3_000,
            4
        );

        _correctAndPoke();

        vm.warp(
            BASE_TIME + 8 weeks
        );

        _recorder().advanceBook(
            refB,
            104
        );

        (
            uint256[] memory newWeeks,
            uint256[] memory newWords
        ) = _readCrumbs(
            refB,
            3_004,
            4
        );

        (
            uint256[] memory oldWeeksAfterPoke,
            uint256[] memory oldWordsAfterPoke
        ) = _readCrumbs(
            refA,
            3_000,
            4
        );

        for (uint256 i; i < oldWords.length; ++i) {

            assertEq(
                oldWeeksAfterPoke[i],
                oldWeeks[i]
            );

            assertEq(
                oldWordsAfterPoke[i],
                oldWords[i]
            );
        }

        for (uint256 i = 1; i < newWords.length; ++i) {

            assertEq(
                CohortWeeks._laneY1(newWords[i]),
                PRINCIPAL * CohortWeeks.WEEK
            );

            assertEq(
                CohortWeeks._laneY2(newWords[i]),
                0
            );

            assertEq(
                CohortWeeks._laneM(newWords[i]),
                0
            );
        }

        hub.deliverCrumbs(
            refA,
            refA,
            oldWeeks,
            oldWords
        );

        hub.deliverCrumbs(
            refB,
            refB,
            newWeeks,
            newWords
        );

        uint256 expectedOld = _expectedPaySum(
            refA,
            oldWeeks,
            oldWords
        );

        uint256 expectedNew = _expectedPaySum(
            refB,
            newWeeks,
            newWords
        );

        assertGt(
            expectedOld,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expectedOld
        );

        assertEq(
            hub.claimable(block.chainid, refB),
            expectedNew
        );

        uint256 oldTail = CohortWeeks._laneY1(
            _recorder().getCohortWeekCrumb(
                refA,
                3_004
            )
        );

        uint256 newHead = CohortWeeks._laneY1(
            newWords[0]
        );

        uint256 newHeadSeconds = CohortWeeks.WEEK
            - 1 hours
            - 3 days;

        assertGt(
            newHead,
            0
        );

        assertLt(
            newHead,
            PRINCIPAL * CohortWeeks.WEEK
        );

        assertLe(
            oldTail + newHead,
            PRINCIPAL * CohortWeeks.WEEK
        );

        assertEq(
            oldTail,
            PRINCIPAL * (1 hours + 3 days)
        );

        assertEq(
            newHead,
            PRINCIPAL * newHeadSeconds
        );
    }

    // ---- 3. the hub's week buckets follow each book ----

    function test_correction_afterPayouts_weekBucketsFollowEachBook()
        public
    {
        _depositWithReferralAs(
            user1,
            PRINCIPAL,
            refA
        );

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        _correctAndPoke();

        assertEq(
            block.timestamp / CohortWeeks.WEEK,
            week
        );

        vm.warp(
            (week + 2) * CohortWeeks.WEEK
        );

        _recorder().advanceBook(
            refA,
            104
        );

        _recorder().advanceBook(
            refB,
            104
        );

        _deliverCrumbChunk(
            refA,
            week,
            week + 1
        );

        _deliverCrumbChunk(
            refB,
            week,
            week + 1
        );

        (
            uint256 oldInWeek,
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        (
            uint256 newInWeek,
        ) = hub.ladderInputsAt(
            refB,
            week
        );

        assertGt(
            oldInWeek,
            0
        );

        assertGt(
            newInWeek,
            0
        );

        assertLe(
            oldInWeek + newInWeek,
            PRINCIPAL
        );

        (
            uint256 oldNextWeek,
        ) = hub.ladderInputsAt(
            refA,
            week + 1
        );

        (
            uint256 newNextWeek,
        ) = hub.ladderInputsAt(
            refB,
            week + 1
        );

        assertEq(
            oldNextWeek,
            0
        );

        assertEq(
            newNextWeek,
            PRINCIPAL
        );
    }

    // ---- 4. a user veto leaves everything unchanged ----

    function test_correction_afterPayouts_userVetoLeavesEverythingUnchanged()
        public
    {
        uint256 bucket = _accrueForOldReferrer();

        uint256 scoreOld = _recorder().getCohortScore(refA);

        uint256 scoreNew = _recorder().getCohortScore(refB);

        address referrerBefore = registry.referrerOf(user1);

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.prank(
            user1
        );

        registry.cancelCorrectReferrer(
            user1
        );

        vm.warp(
            block.timestamp + 3 days
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NoCorrectionProposed.selector
        );

        registry.executeCorrectReferrer(
            user1
        );

        assertEq(
            _recorder().getCohortScore(refA),
            scoreOld
        );

        assertEq(
            _recorder().getCohortScore(refB),
            scoreNew
        );

        assertEq(
            registry.referrerOf(user1),
            referrerBefore
        );

        assertEq(
            registry.pendingFlip(address(diamond), user1),
            address(0)
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            bucket
        );

        assertEq(
            hub.claimable(block.chainid, refB),
            0
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            uint256[] memory laterWeeks,
            uint256[] memory laterWords
        ) = _readCrumbs(
            refA,
            3_004,
            3
        );

        _deliverCrumbChunk(
            refA,
            3_004,
            3_006
        );

        uint256 growth = _expectedPaySum(
            refA,
            laterWeeks,
            laterWords
        );

        assertGt(
            growth,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            bucket + growth
        );

        assertEq(
            hub.claimable(block.chainid, refB),
            0
        );
    }

    // ---- 5. the seed latch leaves the correction lane open ----

    function test_correction_afterPayouts_seedLatchedLaneOpen()
        public
    {
        assertTrue(
            registry.seedsLatched()
        );

        assertFalse(
            registry.correctionsLatched()
        );

        _plainDepositAs(
            user1,
            1_000 * 1e6
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SeedingLatched.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        _depositWithReferralAs(
            user1,
            PRINCIPAL,
            refA
        );

        uint256 scoreBefore = _recorder().getCohortScore(refA);

        assertGt(
            scoreBefore,
            0
        );

        _correctAndPoke();

        assertEq(
            registry.referrerOf(user1),
            refB
        );

        assertEq(
            _recorder().getCohortScore(refA),
            0
        );

        assertEq(
            _recorder().getCohortScore(refB),
            scoreBefore
        );
    }
}
