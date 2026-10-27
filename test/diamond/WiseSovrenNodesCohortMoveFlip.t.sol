// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

/**
 * @dev Same-chain move carry across a PARTIALLY migrated referrer
 * flip. The registry keeps one pending-flip marker per tracked vault
 * and `pokeMigration` clears a marker only when that vault's
 * migration succeeds, so a poke that finds one vault disarmed over
 * the mover's attributed book, or one whose flip entrypoint reverts
 * (the same state an out-of-gas poke or a not-yet-routed flip
 * selector leaves behind; a disarmed vault where the mover holds no
 * attributed book consumes the marker instead), makes the two vaults
 * of one chain name DIFFERENT effective referrers for the same user.
 * The suite drives a move through that state in both directions and
 * pins the destination rule: carried lanes land under the referrer
 * the destination's own registry seam answers, never under the name
 * the source wrote into the envelope, so the book that receives the
 * credit is the book every later clamp on that vault charges; and
 * when that referrer differs from the carried one the move is a
 * relocation across referrers; either way every carried pair lands at
 * its own slot and ring. Source deferred: the destination plants under
 * the migrated referrer at the pairs' own slots, a clamp there empties
 * it again,
 * and recycling the same capital through deposit, move and clamp
 * never grows a book nobody can charge. Destination deferred (staged
 * with a reverting flip entrypoint, since the mover holds nothing on
 * the destination): the credit lands under the marker's old referrer
 * at its own slot, and the later poke relocates the same
 * amount exactly once, charging that book newest credit first, so the
 * mover's slice travels from the shared slot and the second referee's
 * credit stays; amounts and slots are conserved per referrer. Both
 * markers standing: the credit lands under the old referrer on both
 * ends at its own slot and one poke migrates it. The
 * applied event reports the effective referrer next to the carried
 * one so a divergence stays visible offchain. Every scenario closes
 * on the global identity (the four books across both vaults equal
 * the referees' attributed contribution) and on the per-referrer
 * identity: on each vault, each referrer's book equals the attributed
 * contribution of the referees whose effective referrer on that vault
 * it is, so a landing under the wrong referrer on the right vault
 * fails even where the global sum holds. A pair landing on a slot
 * already at the lane maximum clips there: the move emits
 * `CohortLaneSaturated` for that slot and never reverts, and no other
 * slot takes the clipped amount.
 */
contract WiseSovrenNodesCohortMoveFlipTest is TwoVaultCohortHarness {

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

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    uint256 internal constant STAKE = 1_000 * 1e6;

    uint256 internal constant SECOND_STAKE = 700 * 1e6;

    uint256 internal constant THIRD_STAKE = 500 * 1e6;

    uint256 internal constant RING_YEAR1_SLOT = 72;

    address internal user1 = address(0xA1);

    address internal user2 = address(0xA2);

    address internal refY = address(0xB1);

    address internal refX = address(0xB2);

    address internal outsider = address(0xC1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    // ---- helpers ----

    function _flipUser1ToRefX()
        internal
    {
        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            user1,
            refX,
            block.timestamp - 1_000,
            1
        );
    }

    function _pokeWithDeferredOn(
        WiseSovrenNodesDiamond _deferred
    )
        internal
    {
        AdminFacet(address(_deferred)).setCohortSyncEnabled(
            false
        );

        registry.pokeMigration(
            user1
        );

        AdminFacet(address(_deferred)).setCohortSyncEnabled(
            true
        );
    }

    function _pokeWithFlipRevertingOn(
        WiseSovrenNodesDiamond _deferred
    )
        internal
    {
        vm.mockCallRevert(
            address(_deferred),
            abi.encodeWithSelector(
                CohortRecorderFacet.receiveReferrerFlip.selector
            ),
            ""
        );

        registry.pokeMigration(
            user1
        );

        vm.clearMockedCalls();
    }

    function _clampOutOf(
        WiseSovrenNodesDiamond _vault
    )
        internal
    {
        uint256 balance = _vault.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        _vault.transfer(
            outsider,
            balance
        );

        _recorderOf(_vault).syncReferee(
            user1
        );
    }

    function _expectApplied(
        address _effective,
        address _carried,
        uint256 _year1,
        uint256 _year2
    )
        internal
    {
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
            _effective,
            _carried,
            STAKE,
            _year1,
            _year2,
            0,
            1
        );
    }

    function _globalBook()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getCohortScore(refY)
            + _recorderOf(vaultA).getCohortScore(refX)
            + _recorderOf(vaultB).getCohortScore(refY)
            + _recorderOf(vaultB).getCohortScore(refX);
    }

    function _globalAttributed()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getAttributedContribution(user1)
            + _recorderOf(vaultB).getAttributedContribution(user1)
            + _recorderOf(vaultA).getAttributedContribution(user2)
            + _recorderOf(vaultB).getAttributedContribution(user2);
    }

    function _assertGlobalIdentity()
        internal
        view
    {
        assertEq(
            _globalBook(),
            _globalAttributed()
        );

        _assertPerReferrerIdentity();
    }

    function _assertPerReferrerIdentity()
        internal
        view
    {
        _assertVaultReferrerIdentity(
            vaultA,
            refY
        );

        _assertVaultReferrerIdentity(
            vaultA,
            refX
        );

        _assertVaultReferrerIdentity(
            vaultB,
            refY
        );

        _assertVaultReferrerIdentity(
            vaultB,
            refX
        );
    }

    function _assertVaultReferrerIdentity(
        WiseSovrenNodesDiamond _vault,
        address _referrer
    )
        internal
        view
    {
        uint256 members;

        if (registry.effectiveReferrerOf(user1, address(_vault)) == _referrer) {
            members += _recorderOf(_vault).getAttributedContribution(
                user1
            );
        }

        if (registry.effectiveReferrerOf(user2, address(_vault)) == _referrer) {
            members += _recorderOf(_vault).getAttributedContribution(
                user2
            );
        }

        assertEq(
            _recorderOf(_vault).getCohortScore(
                _referrer
            ),
            members
        );
    }

    function _saturateRingYear1On(
        WiseSovrenNodesDiamond _vault,
        address _referrer,
        uint256 _slot
    )
        internal
    {
        bytes32 word = bytes32(
            uint256(
                keccak256(
                    abi.encode(
                        _referrer,
                        RING_YEAR1_SLOT
                    )
                )
            ) + _slot / 4
        );

        uint256 current = uint256(
            vm.load(
                address(_vault),
                word
            )
        );

        vm.store(
            address(_vault),
            word,
            bytes32(
                current | (uint256(type(uint64).max) << (_slot % 4 * 64))
            )
        );
    }

    function _assertRingsB(
        address _referrer,
        uint256 _slot,
        uint256 _year1,
        uint256 _year2
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(vaultB).getCohortRings(
            _referrer
        );

        assertEq(
            uint256(ring1[_slot]),
            _year1
        );

        assertEq(
            uint256(ring2[_slot]),
            _year2
        );
    }

    // ---- source deferred, destination migrated ----

    function test_move_sourceDeferred_landsUnderDestinationReferrerAndClampsThere()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
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
            refX
        );

        _expectApplied(
            refX,
            refY,
            STAKE,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        _assertLandedTotals(
            vaultB,
            refX,
            STAKE,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            STAKE
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
                vaultA
            ).getCohortScore(
                refY
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            STAKE
        );

        _assertGlobalIdentity();

        _clampOutOf(
            vaultB
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            0
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
            ).getAttributedContribution(
                user1
            ),
            0
        );

        _assertGlobalIdentity();
    }

    function test_move_sourceDeferred_recycledCapitalNeverStacksPhantomCredit()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
        );

        for (uint256 i; i < 3; ++i) {

            _moveAs(
                user1,
                vaultA,
                vaultB,
                STAKE
            );

            _assertLandedTotals(
                vaultB,
                refX,
                STAKE,
                0,
                0
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
                STAKE
            );

            _assertGlobalIdentity();

            _clampOutOf(
                vaultB
            );

            assertEq(
                _globalBook(),
                0
            );

            _assertGlobalIdentity();

            _depositOn(
                vaultA,
                user1,
                STAKE
            );

            assertEq(
                _recorderOf(
                    vaultA
                ).getCohortScore(
                    refY
                ),
                STAKE
            );

            _assertGlobalIdentity();
        }

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            0
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
            0
        );
    }

    function test_move_sourceDeferred_threeLaneCarry_landsEveryPairAtItsSlot()
        public
    {
        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        vm.warp(
            block.timestamp + 53 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            SECOND_STAKE,
            refY
        );

        vm.warp(
            block.timestamp + 54 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            THIRD_STAKE,
            refY
        );

        vm.prank(
            address(vaultA)
        );

        registry.mergeReferrer(
            user1,
            refX,
            BASE_TIME - 1_000,
            1
        );

        _pokeWithDeferredOn(
            vaultA
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
            refX,
            refY,
            STAKE + SECOND_STAKE + THIRD_STAKE,
            THIRD_STAKE,
            SECOND_STAKE,
            STAKE,
            2
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE + SECOND_STAKE + THIRD_STAKE
        );

        _assertLandedTotals(
            vaultB,
            refX,
            THIRD_STAKE,
            SECOND_STAKE,
            STAKE
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            STAKE + SECOND_STAKE + THIRD_STAKE
        );

        _assertGlobalIdentity();
    }

    // ---- source migrated, destination deferred ----

    function test_move_destinationDeferred_landsUnderMarkerKeepingSlotsThenPokeMigratesOnce()
        public
    {
        uint256 depositSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            SECOND_STAKE,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            100 * 1e6,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithFlipRevertingOn(
            vaultB
        );

        vm.warp(
            block.timestamp + 1 weeks
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
            STAKE
        );

        _expectApplied(
            refY,
            refX,
            STAKE,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            STAKE + SECOND_STAKE + 100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            0
        );

        _assertRingsB(
            refY,
            depositSlot,
            SECOND_STAKE + 100 * 1e6 + STAKE,
            0
        );

        _assertRingsB(
            refY,
            (depositSlot + 1) % 52,
            0,
            0
        );

        _assertRingsB(
            refY,
            _landingSlot(),
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            STAKE + 100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user2
            ),
            SECOND_STAKE
        );

        _assertGlobalIdentity();

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
            STAKE + 100 * 1e6,
            0,
            0,
            1
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
            STAKE + 100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            SECOND_STAKE
        );

        _assertLandedTotals(
            vaultB,
            refX,
            STAKE + 100 * 1e6,
            0,
            0
        );

        _assertRingsB(
            refY,
            depositSlot,
            SECOND_STAKE,
            0
        );

        _assertRingsB(
            refY,
            _landingSlot(),
            0,
            0
        );

        assertEq(
            registry.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refX
        );

        _assertGlobalIdentity();
    }

    // ---- both markers standing ----

    function test_move_bothMarkersStanding_landsUnderOldReferrerAtItsSlotThenPokeMigrates()
        public
    {
        uint256 depositSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            100 * 1e6,
            refY
        );

        _flipUser1ToRefX();

        _expectApplied(
            refY,
            refY,
            STAKE,
            0
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refY
            ),
            STAKE + 100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            0
        );

        _assertRingsB(
            refY,
            _landingSlot(),
            0,
            0
        );

        _assertRingsB(
            refY,
            depositSlot,
            STAKE + 100 * 1e6,
            0
        );

        _assertGlobalIdentity();

        registry.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            STAKE + 100 * 1e6
        );

        _assertLandedTotals(
            vaultB,
            refX,
            STAKE + 100 * 1e6,
            0,
            0
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
            refX
        );

        _assertGlobalIdentity();
    }

    // ---- split markers: every hop keeps the source cover at its own slot ----

    function test_move_splitMarkerRoundTrips_keepSourceCoverAtItsSlot()
        public
    {
        uint256 freshSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _depositWithReferralOn(
            vaultA,
            user2,
            5 * STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
        );

        for (uint256 i; i < 5; ++i) {

            _moveAs(
                user1,
                vaultA,
                vaultB,
                STAKE
            );

            _moveAs(
                user1,
                vaultB,
                vaultA,
                STAKE
            );
        }

        (
            uint64[52] memory ringY,
        ) = _recorderOf(vaultA).getCohortRings(
            refY
        );

        assertEq(
            uint256(ringY[freshSlot]),
            6 * STAKE
        );

        assertEq(
            uint256(ringY[_landingSlot()]),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refY
            ),
            6 * STAKE
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            0
        );

        _assertGlobalIdentity();
    }

    // ---- pair slot saturation ----

    function test_move_saturatedPairSlot_clipsThereNeverReverts()
        public
    {
        uint256 depositSlot = (block.timestamp / 1 weeks) % 52;

        _depositWithReferralOn(
            vaultA,
            user1,
            STAKE,
            refY
        );

        _flipUser1ToRefX();

        _pokeWithDeferredOn(
            vaultA
        );

        uint256 landingSlot = _landingSlot();

        _saturateRingYear1On(
            vaultB,
            refX,
            depositSlot
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultB)
        );

        emit CohortLaneSaturated(
            refX,
            0,
            depositSlot,
            STAKE
        );

        _moveAs(
            user1,
            vaultA,
            vaultB,
            STAKE
        );

        _assertRingsB(
            refX,
            depositSlot,
            type(uint64).max,
            0
        );

        _assertRingsB(
            refX,
            landingSlot,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refX
            ),
            STAKE
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            STAKE
        );

        _assertGlobalIdentity();
    }
}
