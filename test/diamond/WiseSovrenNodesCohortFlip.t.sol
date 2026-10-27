// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev End-to-end referrer-flip suite driving the cross-chain
 * min-merge through the REAL per-chain registry against two fully
 * wired vaults: an allowlisted vault relays a strictly-lower-key
 * pair via `mergeReferrer`, the registry records pending-flip
 * markers for every tracked vault, and the permissionless
 * `pokeMigration` relocates each vault's book credit through
 * `receiveReferrerFlip` into the flip engine. Proves the
 * conservation contract of the migration (the three lane totals
 * leave the old book and land under the new referrer at the oldest
 * live position, ring slot `(pokeWeek + 1) % 52` on each ring plus
 * the mature lane, `trackedContribution` untouched by the relocation
 * itself), the clamp-first ordering (a lazy deficit is destroyed
 * against the OLD referrer before anything lands), the redirect
 * window (`effectiveReferrerOf` answers the old referrer while a
 * marker stands, so interim clamps and credits keep hitting the book
 * that actually holds the cover), the zero-tracked short-circuit, the
 * defer-and-retry contract for a disarmed vault holding the mover's
 * attributed book, and the consume on a disarmed vault holding none
 * (the first credit after arming lands under the new referrer), poke
 * idempotence, and the marker-vs-current reconciliation
 * (`FlipCleared`, no engine call) when a key chain lands back on the
 * original referrer.
 * Registry-caller authentication on `receiveReferrerFlip` is pinned
 * directly against the routed selector. The relocation rule is
 * pinned against a pooled book (a second and a third referee under
 * the old referrer, a referee under the new one): the walk out of
 * the old book is the sale walk, newest credit first, so the newest
 * ring-1 slot leaves first, a partial take leaves the older cohorts
 * in place, an exhausted newest slot spills into the next newest,
 * one walk crosses ring 1, ring 2 and the mature lane in that order
 * and ring 1 before ring 2 on a partial ring-2 take, a mature old
 * book gives up the mover's fresh cohort rather than its mature
 * lane, and a mature-only book gives up exactly the attributed
 * amount without pairs; the old book after a flip is lane- and
 * ring-identical to the same book after a sale of the attributed
 * amount, on a fixed fixture and under a differential fuzz that also
 * pins the new book as the landing of exactly what left; every taken
 * pair lands at its own slot and ring, so a front-running deposit that
 * travels keeps its fresh age, a cohort exactly one year old stays on
 * ring two until its second anniversary, a 51-week-old cohort lands on
 * its own slot, and a second flip carries the same pairs on again at
 * their own slots. The pooled residual is pinned too: the flip walks
 * the old book newest first, so the slice that travels can be another
 * referee's fresher cover, and that slice keeps its own slot under the
 * new referrer. Every
 * single-referee scenario closes with the no-orphan identity: the
 * effective referrer's book score equals the mover's tracked
 * contribution, valid there because the destination book has no
 * other referee and every deposit of the mover is referred. The flip
 * clamp arm is pinned on the self crumb: a poke that meets the mover
 * still parked from a transfer resolves the park inside the migration
 * at the park instant against the old referrer and clears it, the
 * self crumb settled to the park instant at the pre-clamp stake; with
 * a time gap the old book and the self crumb stop at the park, and a
 * parked mover whose balance was restored is released without a
 * clamp. A mover holding an unparked lazy deficit (a master burn
 * runs no hook) is clamped inside the migration at the poke instant,
 * the self crumb settled to the poke at the pre-clamp stake before
 * the tracked contribution drops. The routed flip entrypoint drains the deferred-divest park
 * first: a third party parked by a transfer on the vault is synced at
 * the post-transfer balance, and the park slot cleared, inside the
 * poke of another user's flip before the migration lands.
 */
contract WiseSovrenNodesCohortFlipTest is TwoVaultCohortHarness {

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    event ReferralSyncFlipped(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    event FlipMarked(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipCleared(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event CohortDivestParked(
        address indexed user
    );

    event CohortDivestDrained(
        address indexed user
    );

    uint256 internal constant SEEDED_TOTAL = 3_500 * 1e6;

    uint256 internal constant DIVEST_SLOT = 91;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal user3 = address(0xA3);

    address internal refY = address(0xB1);

    address internal refX = address(0xB2);

    address internal refZ = address(0xB3);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _mergeAsVaultA(
        address _newReferrer,
        uint256 _assignedAt
    )
        internal
    {
        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            user1,
            _newReferrer,
            _assignedAt,
            1
        );
    }

    function _seedThreeWeekSchedule()
        internal
        returns (uint256 stampTime)
    {
        stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refY
        );
    }

    function _assertReferrerBookEmpty(
        WiseSovrenNodesDiamond d,
        address _referrer
    )
        internal
        view
    {
        assertEq(
            _recorderOf(
                d
            ).getCohortScore(
                _referrer
            ),
            0
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                ring1[i],
                0
            );

            assertEq(
                ring2[i],
                0
            );
        }
    }

    function _assertNoOrphan(
        WiseSovrenNodesDiamond d,
        address _user
    )
        internal
        view
    {
        address effective = registry.effectiveReferrerOf(
            _user,
            address(d)
        );

        assertEq(
            _recorderOf(
                d
            ).getCohortScore(
                effective
            ),
            _recorderOf(
                d
            ).getTrackedContribution(
                _user
            )
        );
    }

    function _assertBookA(
        address _referrer,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
        ) = _recorderOf(vaultA).getCohortBook(
            _referrer
        );

        assertEq(
            year1,
            _year1
        );

        assertEq(
            year2,
            _year2
        );

        assertEq(
            mature,
            _mature
        );
    }

    function _assertSelfCrumbA(
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
        ) = _recorderOf(vaultA).getCohortSelfCrumb(
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

    function _parkWordA()
        internal
        view
        returns (uint256)
    {
        return uint256(
            vm.load(
                address(vaultA),
                bytes32(DIVEST_SLOT)
            )
        );
    }

    function _countLogsFrom(
        Vm.Log[] memory _logs,
        address _emitter
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == _emitter) {
                ++count;
            }
        }
    }

    function _countLogsMatching(
        Vm.Log[] memory _logs,
        address _emitter,
        bytes32 _topic0,
        bytes32 _topic1
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (
                _logs[i].emitter == _emitter
                    && _logs[i].topics.length > 1
                    && _logs[i].topics[0] == _topic0
                    && _logs[i].topics[1] == _topic1
            ) {
                ++count;
            }
        }
    }

    // ---- merge marks and redirects ----

    function test_mergeReferrer_lowerKey_flipsAndMarksAllVaults()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            1_000 * 1e6,
            refY
        );

        uint256 assignedAt = stampTime - 1_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            address(vaultA),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipMarked(
            address(vaultB),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralSyncFlipped(
            user1,
            refY,
            refX,
            (assignedAt << 8) | 1
        );

        _mergeAsVaultA(
            refX,
            assignedAt
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refX
        );

        assertEq(
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            refY
        );

        assertEq(
            registry.pendingFlip(
                address(vaultB),
                user1
            ),
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refY
        );

        (
            address referrer,
            uint256 pairAssignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            user1
        );

        assertEq(
            referrer,
            refX
        );

        assertEq(
            pairAssignedAt,
            assignedAt
        );

        assertEq(
            rank,
            1
        );
    }

    // ---- full-path conservation ----

    /**
     * @dev the reverse direction arrives with the earlier key: the
     * local losing edge dissolves and the markers route the
     * book to a zero target
     * the losing referrer book is destroyed, never relocated
     * and never re-credited
     */
    function test_mutualDissolution_pokeDestroysLoserBook()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            3_500 * 1e6,
            refY
        );

        uint256 bookScoreBefore = _recorderOf(vaultA).getCohortScore(
            refY
        );

        assertGt(
            bookScoreBefore,
            0
        );

        assertGt(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            0
        );

        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            refY,
            user1,
            block.timestamp - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            refY
        );

        registry.pokeMigration(
            user1
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
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
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            address(0)
        );
    }

    function test_pokeMigration_fullPath_landsScheduleAtItsSlots()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            SEEDED_TOTAL,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            SEEDED_TOTAL
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refX
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_fullPath_emitsFlipEventsInOrder()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        _depositWithReferralOn(
            vaultB,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            SEEDED_TOTAL,
            0,
            0,
            3
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultA),
            user1,
            refY,
            refX
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );
    }

    // ---- clamp-first: interim exit resolves the OLD referrer ----

    function test_interimWindow_clampResolvesOldReferrer_thenPokeMovesResidual()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            3_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            1_000 * 1e6
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
            refY,
            3_000 * 1e6,
            2_000 * 1e6
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            2_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            2_000 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- flip clamp: self crumb settled at the pre-clamp stake ----

    function test_flipClamp_settlesSelfCrumbBeforeLoweringTracked()
        public
    {
        uint256 deposit = 5_000 * 1e6;

        uint256 transferred = 2_000 * 1e6;

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositWithReferralOn(
            vaultA,
            user1,
            deposit,
            refY
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            transferred
        );

        _assertSelfCrumbA(
            user1,
            depositAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            deposit
        );

        _mergeAsVaultA(
            refX,
            depositAt - 1_000
        );

        uint256 pokeAt = block.timestamp;

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refY,
            deposit,
            deposit - transferred
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _parkWordA(),
            0
        );

        _assertSelfCrumbA(
            user1,
            pokeAt,
            deposit * (pokeAt - boundary),
            deposit * (boundary - depositAt)
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            deposit - transferred
        );
    }

    function test_flipClamp_unparkedDeficit_settlesSelfCrumbBeforeLoweringTracked()
        public
    {
        uint256 deposit = 5_000 * 1e6;

        uint256 burned = 2_000 * 1e6;

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositWithReferralOn(
            vaultA,
            user1,
            deposit,
            refY
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        AdminFacet(address(vaultA)).burnSupply(
            user1,
            burned
        );

        assertEq(
            _parkWordA(),
            0
        );

        _assertSelfCrumbA(
            user1,
            depositAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            deposit
        );

        _mergeAsVaultA(
            refX,
            depositAt - 1_000
        );

        vm.warp(
            block.timestamp + 3 hours
        );

        uint256 pokeAt = block.timestamp;

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refY,
            deposit,
            deposit - burned
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _parkWordA(),
            0
        );

        _assertSelfCrumbA(
            user1,
            pokeAt,
            deposit * (pokeAt - boundary),
            deposit * (boundary - depositAt)
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            deposit - burned
        );
    }

    function test_pokeMigration_parkedFlipper_settlesOldBookToParkInstant()
        public
    {
        uint256 depositAt = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            5_000 * 1e6,
            refY
        );

        vm.warp(
            depositAt + 1 days
        );

        uint256 parkAt = block.timestamp;

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            2_000 * 1e6
        );

        assertEq(
            _parkWordA(),
            uint256(uint160(user1)) | (parkAt << 160)
        );

        _mergeAsVaultA(
            refX,
            depositAt - 1_000
        );

        vm.warp(
            parkAt + 1 days
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
            refY,
            5_000 * 1e6,
            3_000 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDivestDrained(
            user1
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            3_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _parkWordA(),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        _assertSelfCrumbA(
            user1,
            parkAt,
            5_000 * 1e6 * (parkAt - depositAt),
            0
        );

        _assertLandedTotals(
            vaultA,
            refX,
            3_000 * 1e6,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            0
        );

        vm.warp(
            (parkAt / 1 weeks + 1) * 1 weeks + 1 hours
        );

        _recorderOf(vaultA).advanceBook(
            refY,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            CohortWeeks._laneY1(
                _recorderOf(vaultA).getCohortWeekCrumb(
                    refY,
                    parkAt / 1 weeks
                )
            ),
            5_000 * 1e6 * 1 days
                + 3_000 * 1e6 * 1 days
        );
    }

    function test_pokeMigration_parkedFlipperBalanceRestored_drainsWithoutClamp()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            5_000 * 1e6,
            refY
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            2_000 * 1e6
        );

        AdminFacet(address(vaultA)).mintSupply(
            user1,
            2_000 * 1e6
        );

        _mergeAsVaultA(
            refX,
            block.timestamp - 1_000
        );

        vm.recordLogs();

        registry.pokeMigration(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countLogsMatching(
                logs,
                address(vaultA),
                keccak256(
                    "CohortDivestDrained(address)"
                ),
                bytes32(uint256(uint160(user1)))
            ),
            1
        );

        assertEq(
            _countLogsMatching(
                logs,
                address(vaultA),
                keccak256(
                    "CohortContributionSynced(address,address,uint256,uint256)"
                ),
                bytes32(uint256(uint160(user1)))
            ),
            0
        );

        assertEq(
            _parkWordA(),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            5_000 * 1e6
        );

        _assertLandedTotals(
            vaultA,
            refX,
            5_000 * 1e6,
            0,
            0
        );
    }

    // ---- flip entrypoint drains a parked third party first ----

    function test_pokeMigration_drainsParkedThirdPartyBeforeMigration()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        uint256 thirdPartyDeposit = 1_000 * 1e6;

        uint256 transferred = 400 * 1e6;

        _depositWithReferralOn(
            vaultA,
            user2,
            thirdPartyDeposit,
            refZ
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDivestParked(
            user2
        );

        vm.prank(
            user2
        );

        vaultA.transfer(
            outsider,
            transferred
        );

        uint256 heldAfter = vaultA.balanceOf(
            user2
        );

        assertEq(
            _parkWordA(),
            uint256(uint160(user2)) | (block.timestamp << 160)
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user2
            ),
            thirdPartyDeposit
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortDivestDrained(
            user2
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            SEEDED_TOTAL,
            0,
            0,
            3
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _parkWordA(),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user2
            ),
            heldAfter
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refZ
            ),
            heldAfter
        );

        _assertLandedTotals(
            vaultA,
            refX,
            SEEDED_TOTAL,
            0,
            0
        );
    }

    // ---- interim deposits credit old, post-poke deposits credit new ----

    function test_interimWindow_depositCreditsOldReferrer_newAfterPoke()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        _fundAndApproveOn(
            vaultA,
            user1,
            500 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionCredited(
            user1,
            refY,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultA)).deposit(
            500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            1_500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            0
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            1_500 * 1e6
        );

        _fundAndApproveOn(
            vaultA,
            user1,
            300 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortContributionCredited(
            user1,
            refX,
            300 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultA)).deposit(
            300 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            1_800 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- zero tracked: degenerate migration touches no books ----

    /**
     * @dev the whole booked vault leaves refY for refX on the marker
     * poke: the same-block deposit carries one year-1 pair, and
     * no residue stays behind on the vacated referrer
     */
    function test_pokeMigration_freshDepositVault_migratesOnPoke()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            1_000 * 1e6
        );

        assertEq(
            registry.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );
    }

    // ---- receiveReferrerFlip authentication ----

    function test_receiveReferrerFlip_nonRegistryCaller_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotReferralRegistry.selector
        );

        CohortRecorderFacet(address(vaultA)).receiveReferrerFlip(
            user1,
            refY,
            refX
        );
    }

    // ---- disarmed vault defers, marker keeps redirecting ----

    function test_pokeMigration_disarmedVault_defersAndKeepsMarker()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            2_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultA),
            user1,
            refY,
            refX
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrationDeferred(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refX
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refY
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            0
        );
    }

    /**
     * @dev the book probe answers zero for the disarmed bookless
     * vault, so it never carries a marker at all and its first
     * credit for the user lands on the current referrer with no
     * poke needed
     */
    function test_pokeMigration_disarmedVaultWithoutBook_neverMarked()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        _mergeAsVaultA(
            refX,
            block.timestamp - 1_000
        );

        assertEq(
            registry.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultA),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refX
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );

        _fundAndApproveOn(
            vaultB,
            user1,
            500 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortContributionCredited(
            user1,
            refX,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultB)).deposit(
            500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            0
        );

        _assertReferrerBookEmpty(
            vaultB,
            refY
        );

        _assertNoOrphan(
            vaultB,
            user1
        );
    }

    /**
     * @dev the marker stands (the probe saw the attributed book at
     * flip time), then the stake leaves and the clamp drains the
     * attributed ledger to zero before the poke: the disarmed
     * vault consumes its marker silently, with no vault event
     */
    function test_pokeMigration_disarmedVaultWithDrainedBook_consumesSilently()
        public
    {
        _depositWithReferralOn(
            vaultB,
            user1,
            700 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            block.timestamp - 1_000
        );

        vm.prank(
            user1
        );

        vaultB.transfer(
            outsider,
            700 * 1e6
        );

        _recorderOf(vaultB).syncReferee(
            user1
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            0
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        vm.recordLogs();

        registry.pokeMigration(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countLogsFrom(
                logs,
                address(vaultB)
            ),
            0
        );

        assertEq(
            _countLogsMatching(
                logs,
                address(registry),
                keccak256(
                    "FlipMigrated(address,address,address,address)"
                ),
                bytes32(uint256(uint160(address(vaultB))))
            ),
            1
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
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            0
        );

        _assertReferrerBookEmpty(
            vaultB,
            refY
        );

        _assertReferrerBookEmpty(
            vaultB,
            refX
        );
    }

    function test_pokeMigration_rearmedVault_migratesOnSecondPoke()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            2_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            false
        );

        registry.pokeMigration(
            user1
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refY,
            refX
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            2_000 * 1e6
        );

        _assertReferrerBookEmpty(
            vaultB,
            refY
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refX
        );

        _assertNoOrphan(
            vaultB,
            user1
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- poke idempotence ----

    function test_pokeMigration_secondCall_noEventsNoStateChange()
        public
    {
        uint256 stampTime = _seedThreeWeekSchedule();

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        CohortSnap memory afterX = _captureCohort(
            vaultA,
            refX,
            user1
        );

        vm.recordLogs();

        registry.pokeMigration(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            logs.length,
            0
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refX,
                user1
            ),
            afterX
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );
    }

    // ---- key chain landing back on the original referrer ----

    function test_pokeMigration_keyChainBackToOriginal_clearsWithoutMigration()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            1_000 * 1e6,
            refY
        );

        CohortSnap memory beforeY = _captureCohort(
            vaultA,
            refY,
            user1
        );

        _mergeAsVaultA(
            refX,
            stampTime - 100
        );

        _mergeAsVaultA(
            refZ,
            stampTime - 200
        );

        _mergeAsVaultA(
            refY,
            stampTime - 300
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refY
        );

        assertEq(
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vaultA),
            user1,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit FlipCleared(
            address(vaultB),
            user1,
            refY
        );

        registry.pokeMigration(
            user1
        );

        _assertScheduleEq(
            _captureCohort(
                vaultA,
                refY,
                user1
            ),
            beforeY
        );

        _assertReferrerBookEmpty(
            vaultA,
            refX
        );

        _assertReferrerBookEmpty(
            vaultA,
            refZ
        );

        assertEq(
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            address(0)
        );

        assertEq(
            registry.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- fuzz: conservation across settle horizons ----

    function testFuzz_pokeMigration_conservationAcrossWarp(
        uint256 _amountSeed,
        uint256 _warpSeed
    )
        public
    {
        uint256 amount = bound(
            _amountSeed,
            1e6,
            9_999 * 1e6
        );

        uint256 warp = bound(
            _warpSeed,
            0,
            160 weeks
        );

        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            amount,
            refY
        );

        vm.warp(
            block.timestamp + warp
        );

        _recorderOf(vaultA).advanceBook(
            refY,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory beforeY = _captureCohort(
            vaultA,
            refY,
            user1
        );

        uint256 boundaries = block.timestamp / 1 weeks - stampTime / 1 weeks;

        assertEq(
            beforeY.year1,
            boundaries < 52
                ? amount
                : 0
        );

        assertEq(
            beforeY.year2,
            boundaries >= 52 && boundaries < 104
                ? amount
                : 0
        );

        assertEq(
            beforeY.mature,
            boundaries >= 104
                ? amount
                : 0
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            beforeY.year1,
            beforeY.year2,
            beforeY.mature
        );

        assertEq(
            beforeY.year1
                + beforeY.year2
                + beforeY.mature,
            amount
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            amount
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- relocation charges the old book newest credit first ----

    function test_pokeMigration_multiReferee_takesNewestSlotFirst()
        public
    {
        uint256 stampTime = block.timestamp;

        uint256 oldSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 5 weeks
        );

        uint256 freshSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user2,
            2_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        (
            uint64[52] memory ringY,
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        _assertLandedTotals(
            vaultA,
            refX,
            1_000 * 1e6,
            0,
            0
        );

        assertEq(
            uint256(ringY[oldSlot]),
            1_000 * 1e6
        );

        assertEq(
            uint256(ringY[freshSlot]),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            2_000 * 1e6
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_frontRunDeposit_takenSliceKeepsItsSlot()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        uint256 pokeSlot = (block.timestamp / 1 weeks) % 52;

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        _depositWithReferralOn(
            vaultA,
            user2,
            3_000 * 1e6,
            refY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            1_000 * 1e6,
            0,
            0
        );

        _assertBookA(
            refY,
            2_000 * 1e6,
            0,
            1_000 * 1e6
        );

        (
            uint64[52] memory ringY,
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ringY[pokeSlot]),
            2_000 * 1e6
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refX,
            1
        );

        _assertBookA(
            refX,
            1_000 * 1e6,
            0,
            0
        );

        (
            uint64[52] memory ringX,
        ) = _recorderOf(vaultA).getCohortRings(
            refX
        );

        assertEq(
            uint256(ringX[pokeSlot]),
            1_000 * 1e6
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_partialTake_leavesOlderCohortsInPlace()
        public
    {
        uint256 stampTime = block.timestamp;

        uint256 firstSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        uint256 sharedSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            700 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultA,
            user2,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 60 weeks
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            0,
            1_200 * 1e6,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            0,
            1_200 * 1e6,
            0
        );

        (
            ,
            uint64[52] memory ring2Y
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ring2Y[firstSlot]),
            500 * 1e6
        );

        assertEq(
            uint256(ring2Y[sharedSlot]),
            500 * 1e6
        );

        _assertBookA(
            refY,
            0,
            1_000 * 1e6,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_newestSlotExhausted_spillsToNextNewest()
        public
    {
        uint256 slotZero = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user2,
            500 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 stampTime = block.timestamp;

        uint256 slotTwo = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 slotFour = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 slotSix = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user3,
            700 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            3_000 * 1e6,
            0,
            0,
            3
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            3_000 * 1e6,
            0,
            0
        );

        (
            uint64[52] memory ringY,
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ringY[slotZero]),
            500 * 1e6
        );

        assertEq(
            uint256(ringY[slotTwo]),
            700 * 1e6
        );

        assertEq(
            uint256(ringY[slotFour]),
            0
        );

        assertEq(
            uint256(ringY[slotSix]),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            1_200 * 1e6
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_threeLaneBook_drainsYearOneThenYearTwoThenMatureKeepingSlots()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            500 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 53 weeks
        );

        uint256 yearTwoSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            400 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 54 weeks
        );

        uint256 freshSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user2,
            300 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            BASE_TIME - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            300 * 1e6,
            400 * 1e6,
            200 * 1e6,
            2
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            300 * 1e6,
            400 * 1e6,
            200 * 1e6
        );

        (
            uint64[52] memory ring1Y,
            uint64[52] memory ring2Y
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ring1Y[freshSlot]),
            0
        );

        assertEq(
            uint256(ring2Y[yearTwoSlot]),
            0
        );

        _assertBookA(
            refY,
            0,
            0,
            300 * 1e6
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refX,
            1
        );

        _assertBookA(
            refX,
            300 * 1e6,
            400 * 1e6,
            200 * 1e6
        );

        (
            uint64[52] memory ring1X,
            uint64[52] memory ring2X
        ) = _recorderOf(vaultA).getCohortRings(
            refX
        );

        assertEq(
            uint256(ring1X[freshSlot]),
            300 * 1e6
        );

        assertEq(
            uint256(ring2X[yearTwoSlot]),
            400 * 1e6
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_matureOnlyBook_movesMatureResidualWithoutPairs()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user2,
            5_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        _mergeAsVaultA(
            refX,
            BASE_TIME - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            0,
            0,
            1_000 * 1e6,
            0
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.pendingFlip(
                address(vaultA),
                user1
            ),
            address(0)
        );

        _assertLandedTotals(
            vaultA,
            refX,
            0,
            0,
            1_000 * 1e6
        );

        _assertLandedTotals(
            vaultA,
            refY,
            0,
            0,
            5_000 * 1e6
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_oneYearOldCohort_keepsItsSlotOnRingTwo()
        public
    {
        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 52 weeks
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            0,
            1_000 * 1e6,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            0,
            1_000 * 1e6,
            0
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refX,
            1
        );

        _assertBookA(
            refX,
            0,
            1_000 * 1e6,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_twoHops_keepsTheSlotAtEachHop()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user2,
            2_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        uint256 stampTime = block.timestamp;

        uint256 pokeSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user3,
            500 * 1e6,
            refX
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        _assertBookA(
            refX,
            1_500 * 1e6,
            0,
            0
        );

        _mergeAsVaultA(
            refZ,
            stampTime - 2_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refX,
            refZ,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refZ
        );

        _assertLandedTotals(
            vaultA,
            refZ,
            1_000 * 1e6,
            0,
            0
        );

        _assertBookA(
            refY,
            0,
            0,
            2_000 * 1e6
        );

        _assertBookA(
            refX,
            500 * 1e6,
            0,
            0
        );

        (
            uint64[52] memory ringX,
        ) = _recorderOf(vaultA).getCohortRings(
            refX
        );

        assertEq(
            uint256(ringX[pokeSlot]),
            500 * 1e6
        );

        assertEq(
            uint256(ringX[_landingSlot()]),
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- one rule: the old book cannot tell a flip from a sale ----

    function test_pokeMigration_oldBookAfterFlip_equalsOldBookAfterSaleOfAttributed()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user2,
            500 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            500 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        uint256 stampTime = block.timestamp;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            2_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user3,
            700 * 1e6,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user3,
            700 * 1e6,
            refY
        );

        vm.prank(
            user1
        );

        vaultB.transfer(
            outsider,
            3_000 * 1e6
        );

        _recorderOf(vaultB).syncReferee(
            user1
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        CohortSnap memory afterFlip = _captureCohort(
            vaultA,
            refY,
            user1
        );

        CohortSnap memory afterSale = _captureCohort(
            vaultB,
            refY,
            user1
        );

        assertEq(
            afterFlip.year1,
            afterSale.year1
        );

        assertEq(
            afterFlip.year2,
            afterSale.year2
        );

        assertEq(
            afterFlip.mature,
            afterSale.mature
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                afterFlip.ring1[i],
                afterSale.ring1[i]
            );

            assertEq(
                afterFlip.ring2[i],
                afterSale.ring2[i]
            );
        }

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            1_200 * 1e6
        );

        _assertLandedTotals(
            vaultA,
            refX,
            3_000 * 1e6,
            0,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_matureOldBook_takesMoverFreshCohortNotMature()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user2,
            5_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        uint256 stampTime = block.timestamp;

        uint256 pokeSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            1_000 * 1e6,
            0,
            0
        );

        _assertBookA(
            refY,
            0,
            0,
            5_000 * 1e6
        );

        (
            uint64[52] memory ringY,
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ringY[pokeSlot]),
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_partialRingTwo_takesRingOneBeforeRingTwo()
        public
    {
        uint256 moverSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            400 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 54 weeks
        );

        uint256 freshSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user2,
            300 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            BASE_TIME - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            300 * 1e6,
            100 * 1e6,
            0,
            2
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            300 * 1e6,
            100 * 1e6,
            0
        );

        (
            uint64[52] memory ring1Y,
            uint64[52] memory ring2Y
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ring1Y[freshSlot]),
            0
        );

        assertEq(
            uint256(ring2Y[moverSlot]),
            300 * 1e6
        );

        _assertBookA(
            refY,
            0,
            300 * 1e6,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    function test_pokeMigration_fiftyOneWeekOldCohort_landsOnItsOwnSlot()
        public
    {
        uint256 stampTime = block.timestamp;

        uint256 slot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 51 weeks
        );

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refY,
            refX,
            1_000 * 1e6,
            0,
            0,
            1
        );

        registry.pokeMigration(
            user1
        );

        assertEq(
            _landingSlot(),
            slot
        );

        _assertLandedTotals(
            vaultA,
            refX,
            1_000 * 1e6,
            0,
            0
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refX,
            1
        );

        _assertBookA(
            refX,
            0,
            1_000 * 1e6,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- the pooled residual: the flip takes the old pool's freshest cover
    // and that slice keeps its own slot under the new referrer ----

    function test_pokeMigration_laterExitOfOldPool_relocatedSliceKeepsItsSlot()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refY
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user2,
            1_000 * 1e6,
            refY
        );

        _mergeAsVaultA(
            refX,
            BASE_TIME - 1_000
        );

        registry.pokeMigration(
            user1
        );

        _assertLandedTotals(
            vaultA,
            refX,
            1_000 * 1e6,
            0,
            0
        );

        _assertBookA(
            refY,
            0,
            0,
            1_000 * 1e6
        );

        vm.prank(
            user2
        );

        vaultA.transfer(
            outsider,
            1_000 * 1e6
        );

        _recorderOf(vaultA).syncReferee(
            user2
        );

        _assertBookA(
            refY,
            0,
            0,
            0
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refX,
            1
        );

        _assertBookA(
            refX,
            1_000 * 1e6,
            0,
            0
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- differential fuzz: the old book equals a sale, the new book is
    // the landing of exactly what left ----

    function testFuzz_pokeMigration_oldBookEqualsSaleAndNewBookLandsWhatLeft(
        uint256 _olderSeed,
        uint256 _moverSeed,
        uint256 _fresherSeed,
        uint256 _gapOneSeed,
        uint256 _gapTwoSeed,
        uint256 _gapThreeSeed
    )
        public
    {
        uint256 older = bound(
            _olderSeed,
            1e6,
            5_000 * 1e6
        );

        uint256 mover = bound(
            _moverSeed,
            1e6,
            5_000 * 1e6
        );

        uint256 fresher = bound(
            _fresherSeed,
            1e6,
            5_000 * 1e6
        );

        _depositWithReferralOn(
            vaultA,
            user2,
            older,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            older,
            refY
        );

        uint256 gapOne = bound(
            _gapOneSeed,
            0,
            55
        );

        vm.warp(
            block.timestamp + gapOne * 1 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            mover,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            mover,
            refY
        );

        uint256 gapTwo = bound(
            _gapTwoSeed,
            0,
            55
        );

        vm.warp(
            block.timestamp + gapTwo * 1 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user3,
            fresher,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user3,
            fresher,
            refY
        );

        uint256 gapThree = bound(
            _gapThreeSeed,
            0,
            10
        );

        vm.warp(
            block.timestamp + gapThree * 1 weeks
        );

        vm.prank(
            user1
        );

        vaultB.transfer(
            outsider,
            mover
        );

        _recorderOf(vaultB).syncReferee(
            user1
        );

        _recorderOf(vaultA).advanceBook(
            refY,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        CohortSnap memory beforeA = _captureCohort(
            vaultA,
            refY,
            user1
        );

        _mergeAsVaultA(
            refX,
            BASE_TIME - 1_000
        );

        registry.pokeMigration(
            user1
        );

        CohortSnap memory afterA = _captureCohort(
            vaultA,
            refY,
            user1
        );

        CohortSnap memory afterSale = _captureCohort(
            vaultB,
            refY,
            user1
        );

        assertEq(
            afterA.year1,
            afterSale.year1
        );

        assertEq(
            afterA.year2,
            afterSale.year2
        );

        assertEq(
            afterA.mature,
            afterSale.mature
        );

        for (uint256 i; i < 52; ++i) {

            assertEq(
                afterA.ring1[i],
                afterSale.ring1[i]
            );

            assertEq(
                afterA.ring2[i],
                afterSale.ring2[i]
            );
        }

        _assertLandedTotals(
            vaultA,
            refX,
            beforeA.year1 - afterA.year1,
            beforeA.year2 - afterA.year2,
            beforeA.mature - afterA.mature
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refX
            ),
            mover
        );

        _assertNoOrphan(
            vaultA,
            user1
        );
    }

    // ---- exact age: a flip replants every captured pair at its own slot ----

    function test_pokeMigration_fullPath_replantsEveryPairAtItsSlot()
        public
    {
        uint256 s0 = (block.timestamp / 1 weeks) % 52;

        uint256 stampTime = _seedThreeWeekSchedule();

        uint256 s3 = (block.timestamp / 1 weeks) % 52;

        _mergeAsVaultA(
            refX,
            stampTime - 1_000
        );

        registry.pokeMigration(
            user1
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(vaultA).getCohortRings(
            refX
        );

        assertEq(
            uint256(ring1[s0]),
            1_000 * 1e6
        );

        assertEq(
            uint256(ring1[(s0 + 2) % 52]),
            2_000 * 1e6
        );

        assertEq(
            uint256(ring1[s3]),
            500 * 1e6
        );

        assertEq(
            uint256(ring1[(s3 + 1) % 52]),
            0
        );

        assertEq(
            uint256(ring2[(s3 + 1) % 52]),
            0
        );

        _assertReferrerBookEmpty(
            vaultA,
            refY
        );
    }

    // ---- moved-amount pin: the flip clamp logs the completed self week ----

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    function test_flipClamp_afterBoundary_logsTheCompletedSelfWeek()
        public
    {
        uint256 deposit = 5_000 * 1e6;

        uint256 depositAt = block.timestamp;

        uint256 boundary = (depositAt / CohortWeeks.WEEK + 1) * CohortWeeks.WEEK;

        _depositWithReferralOn(
            vaultA,
            user1,
            deposit,
            refY
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            outsider,
            2_000 * 1e6
        );

        _mergeAsVaultA(
            refX,
            depositAt - 1_000
        );

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
            deposit * (boundary - depositAt),
            deposit
        );

        registry.pokeMigration(
            user1
        );
    }
}
