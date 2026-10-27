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

import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

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
 * @dev Registry stand-in that passes the slot-77 pointer's execute
 * shape probe (`referrerOf` answering 32 bytes) and the seed latch
 * read (`seedsLatched`), but deliberately lacks
 * `effectiveReferrerOf`: the recorder's guarded lookup staticcall
 * fails against it, degrading the clamp exactly like an unreachable
 * registry would.
 */
contract MockLookupBrokenRegistry {

    function referrerOf(
        address
    )
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function seedsLatched()
        external
        pure
        returns (bool)
    {
        return false;
    }
}

/**
 * @dev Retroactive-seed suite for {CohortRecorderFacet}'s master-only
 * `seedCohortContribution`, the one sanctioned way to credit
 * balances that existed before the recorder was armed. Pins: the
 * deposit-equivalence law both at the seeding instant AND across
 * time (after graduation walks, books, scores and the seed week's
 * crumb word stay byte-identical to a control referrer whose referee
 * deposited the same amount post-arm, while pre-seed weeks hold zero
 * crumb time), the headroom bound (`min(amount, balance - tracked)`,
 * `type(uint256).max` = full headroom, repeat seeding drains the
 * headroom exactly once, fuzz-pinned tracked <= balance), the
 * unreferred tracked-only arm (self-ladder backfill, no book
 * anywhere), the transfer-received-headroom doctrine (any untracked
 * balance is seedable; which headroom deserves it is master
 * policy), the flip interplay (a seed during a pending flip credits
 * the book that HOLDS the cover and migrates with the poke; a seed
 * after an executed-and-poked registry correction follows the
 * corrected referrer), the I1 three-way equality (sum of referee
 * tracked contributions == bookY1 + bookY2 + bookM == score) after
 * seeding, and every guard arm: master gate, disarmed recorder, the
 * armed-but-hookless state (a zeroed slot-45 pointer, written directly
 * because the AdminFacet refuses a zero hook while armed, reverts
 * {CohortHookNotInstalled} instead of emitting a phantom seed), the
 * registry's one-way seed latch (only `seedsLatched` retires the
 * seed: the correction latch leaves it open, and the correction
 * lane stays usable after the seed latch fires, so a correction
 * executed and poked afterwards still moves the referred credit
 * while every later seed keeps reverting), a broken registry pointer
 * reverting loudly, nothing-to-seed on a fully tracked user and on a
 * zero amount, the standing-deficit case (master `burnSupply` leaves
 * tracked above held; the clamp eats the whole headroom and the
 * seed reverts instead of crediting on top of an unclamped deficit)
 * and its degraded-clamp sibling (a lookup-broken registry, installed
 * through a disarm, the execute and a re-arm because the AdminFacet
 * refuses a registry change while armed, leaves the deficit standing
 * and the seed still lands in {NothingToSeed}).
 * Pre-arm balances are staged with plain deposits while
 * `cohortSyncEnabled` is still false, exactly the live-world shape
 * the seed exists for.
 */
contract WiseSovrenNodesCohortSeedTest is DiamondTestHarness {

    event CohortContributionSeeded(
        address indexed user,
        uint256 amount
    );

    event CohortContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant BASE_WEEK = 3_000;

    uint256 internal constant BASE_SLOT = 3_000 % 52;

    uint256 internal constant ONE = 1e6;

    uint256 internal constant TRANSFER_HOOK_SLOT = 45;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal stranger = address(0xC1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
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

        usd.mint(
            address(diamond),
            100_000_000 * ONE
        );
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

    function _arm()
        internal
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
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

    function _book(
        address _referrer
    )
        internal
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature
        )
    {
        (
            year1,
            year2,
            mature,

        ) = _recorder().getCohortBook(_referrer);
    }

    function _ringSlot(
        address _referrer,
        uint256 _slot
    )
        internal
        view
        returns (uint256)
    {
        (
            uint64[52] memory year1,
        ) = _recorder().getCohortRings(_referrer);

        return year1[_slot];
    }

    // ---- seeding a referred user ----

    function test_seedCohortContribution_referredUser_creditsPreArmBalance()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            50 * ONE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionCredited(
            user1,
            refA,
            1_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSeeded(
            user1,
            1_000 * ONE
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_050 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            1_050 * ONE
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            year1,
            1_050 * ONE
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            1_050 * ONE
        );

        assertEq(
            _ringSlot(
                refA,
                BASE_SLOT
            ),
            1_050 * ONE
        );
    }

    function test_seedCohortContribution_equalsSameInstantDeposit()
        public
    {
        _plainDepositAs(
            user1,
            700 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        _depositWithReferralAs(
            user2,
            50 * ONE,
            refB
        );

        _plainDepositAs(
            user2,
            700 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            _recorder().getTrackedContribution(
                user2
            )
        );

        (
            uint256 seededYear1,
            uint256 seededYear2,
            uint256 seededMature
        ) = _book(refA);

        (
            uint256 controlYear1,
            uint256 controlYear2,
            uint256 controlMature
        ) = _book(refB);

        assertEq(
            seededYear1,
            controlYear1
        );

        assertEq(
            seededYear2,
            controlYear2
        );

        assertEq(
            seededMature,
            controlMature
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            _recorder().getCohortScore(
                refB
            )
        );

        assertEq(
            _ringSlot(
                refA,
                BASE_SLOT
            ),
            _ringSlot(
                refB,
                BASE_SLOT
            )
        );
    }

    function test_seedCohortContribution_agesLikeSameInstantDeposit()
        public
    {
        _plainDepositAs(
            user1,
            700 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        _depositWithReferralAs(
            user2,
            50 * ONE,
            refB
        );

        _plainDepositAs(
            user2,
            700 * ONE
        );

        vm.warp(
            BASE_TIME + 60 weeks
        );

        _recorder().advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _recorder().advanceBook(
            refB,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        (
            uint256 seededYear1,
            uint256 seededYear2,
            uint256 seededMature
        ) = _book(refA);

        (
            uint256 controlYear1,
            uint256 controlYear2,
            uint256 controlMature
        ) = _book(refB);

        assertEq(
            seededYear1,
            controlYear1
        );

        assertEq(
            seededYear2,
            controlYear2
        );

        assertEq(
            seededMature,
            controlMature
        );

        assertGt(
            seededYear2,
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            _recorder().getCohortScore(
                refB
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                BASE_WEEK
            ),
            _recorder().getCohortWeekCrumb(
                refB,
                BASE_WEEK
            )
        );

        assertGt(
            _recorder().getCohortWeekCrumb(
                refA,
                BASE_WEEK
            ),
            0
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                BASE_WEEK - 1
            ),
            0
        );
    }

    function test_seedCohortContribution_partialAmountsDrainHeadroomOnce()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            400 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            450 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSeeded(
            user1,
            600 * ONE
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_050 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            1_050 * ONE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToSeed.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_unreferredUser_tracksOnly()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionCredited(
            user1,
            address(0),
            1_000 * ONE
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _ringSlot(
                refA,
                BASE_SLOT
            ),
            0
        );
    }

    function test_seedCohortContribution_transferReceivedBalanceIsSeedable()
        public
    {
        _arm();

        _depositWithReferralAs(
            user2,
            1_000 * ONE,
            refA
        );

        vm.prank(
            user2
        );

        diamond.transfer(
            user1,
            400 * ONE
        );

        _recorder().syncReferee(
            user2
        );

        (
            uint256 senderYear1,
            ,
        ) = _book(refA);

        assertEq(
            senderYear1,
            600 * ONE
        );

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refB
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            450 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            450 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            600 * ONE
        );
    }

    // ---- flip interplay ----

    function test_seedCohortContribution_duringPendingFlip_creditsBookHolder()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        vm.prank(
            address(diamond)
        );

        registry.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1 days,
            0
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            1_050 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            0
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            1_050 * ONE
        );

        assertEq(
            _ringSlot(
                refB,
                BASE_SLOT
            ),
            1_050 * ONE
        );

        assertEq(
            _ringSlot(
                refB,
                (BASE_SLOT + 1) % 52
            ),
            0
        );
    }

    function test_seedCohortContribution_afterCorrection_followsCorrectedReferrer()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        registry.executeCorrectReferrer(
            user1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            50 * ONE
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            1_050 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- guard arms ----

    function test_seedCohortContribution_revertsWhenNotMaster()
        public
    {
        _arm();

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_revertsWhenDisarmed()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_revertsWhenHookZeroed()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        vm.warp(
            BASE_TIME + 3 days + 1
        );

        vm.store(
            address(diamond),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(0)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortHookNotInstalled.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            0
        );
    }

    function test_seedCohortContribution_revertsWhenLatched()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        registry.latchSeeds();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SeedingLatched.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_correctionsLatchDoesNotBlockSeed()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        registry.latchCorrections();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSeeded(
            user1,
            1_000 * ONE
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_000 * ONE
        );
    }

    function test_seedCohortContribution_seedLatchedCorrectionStillExecutes()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            50 * ONE,
            refA
        );

        registry.latchSeeds();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SeedingLatched.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        registry.proposeCorrectReferrer(
            user1,
            refB
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        registry.executeCorrectReferrer(
            user1
        );

        registry.pokeMigrationAt(
            user1,
            address(diamond)
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            50 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SeedingLatched.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_revertsLoudlyOnBrokenRegistry()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        vm.etch(
            address(registry),
            hex"00"
        );

        vm.expectRevert();

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_revertsWhenFullyTracked()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            1_000 * ONE,
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToSeed.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );
    }

    function test_seedCohortContribution_revertsOnZeroAmount()
        public
    {
        _plainDepositAs(
            user1,
            1_000 * ONE
        );

        _arm();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToSeed.selector
        );

        _recorder().seedCohortContribution(
            user1,
            0
        );
    }

    function test_seedCohortContribution_revertsOnStandingDeficit()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            1_000 * ONE,
            refA
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            400 * ONE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToSeed.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_000 * ONE
        );
    }

    function test_seedCohortContribution_degradedClampRevertsNothingToSeed()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            1_000 * ONE,
            refA
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            400 * ONE
        );

        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(new MockLookupBrokenRegistry())
        );

        vm.warp(
            BASE_TIME + 3 days + 1
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToSeed.selector
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            1_000 * ONE
        );
    }

    // ---- invariant preservation ----

    function test_seedCohortContribution_preservesThreeWayEquality()
        public
    {
        _plainDepositAs(
            user1,
            900 * ONE
        );

        _plainDepositAs(
            user2,
            300 * ONE
        );

        _arm();

        _depositWithReferralAs(
            user1,
            10 * ONE,
            refA
        );

        _depositWithReferralAs(
            user2,
            10 * ONE,
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        _recorder().seedCohortContribution(
            user2,
            250 * ONE
        );

        uint256 trackedSum = _recorder().getTrackedContribution(user1)
            + _recorder().getTrackedContribution(user2);

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            trackedSum,
            year1 + year2 + mature
        );

        assertEq(
            trackedSum,
            _recorder().getCohortScore(
                refA
            )
        );

        assertEq(
            trackedSum,
            900 * ONE + 300 * ONE - 50 * ONE + 20 * ONE
        );

        assertEq(
            _ringSlot(
                refA,
                BASE_SLOT
            ),
            trackedSum
        );
    }

    function testFuzz_seedCohortContribution_headroomBound(
        uint256 _preArm,
        uint256 _refDeposit,
        uint256 _seedAmount
    )
        public
    {
        uint256 preArm = bound(
            _preArm,
            ONE,
            100_000 * ONE
        );

        uint256 refDeposit = bound(
            _refDeposit,
            ONE,
            100_000 * ONE
        );

        uint256 seedAmount = bound(
            _seedAmount,
            1,
            200_000 * ONE
        );

        _plainDepositAs(
            user1,
            preArm
        );

        _arm();

        _depositWithReferralAs(
            user1,
            refDeposit,
            refA
        );

        _recorder().seedCohortContribution(
            user1,
            seedAmount
        );

        uint256 credited = seedAmount < preArm
            ? seedAmount
            : preArm;

        uint256 tracked = _recorder().getTrackedContribution(
            user1
        );

        assertEq(
            tracked,
            refDeposit + credited
        );

        assertLe(
            tracked,
            diamond.balanceOf(
                user1
            )
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            tracked
        );

        assertEq(
            _ringSlot(
                refA,
                BASE_SLOT
            ),
            tracked
        );
    }
}
