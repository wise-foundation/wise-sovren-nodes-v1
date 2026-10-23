// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {UpgradeReferralRegistry} from "../../script/diamond/UpgradeReferralRegistry.s.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {IReferralRegistry} from "../../src/diamond/vault/interfaces/pending/IReferralRegistry.sol";

/**
 * @dev Pins the registry seam probe that the registry upgrade
 * script's `proposePointer()` and `executePointer()` run against the
 * config registry before a vault's registry pointer is proposed and
 * again before it executes. Inherits the upgrade
 * script so the tests exercise the very helper the production script
 * uses. The probe staticcalls every read the vault makes on the
 * registry (`referrerOf`, `effectiveReferrerOf`, `getReferrerPair`,
 * `getPayoutDesignation`, `seedsLatched` and `syncPeerQuarantined`
 * per lane), holds each answer to the size and bounds the vault's own
 * decoders apply, and reads `allowedVault(diamond)` in place of the
 * four write seams (`assignReferrer`, `mergeReferrer`, `stageCarry`,
 * `consumeCarry`) that a staticcall cannot probe, since each is gated
 * to an allowlisted vault. The real {ReferralRegistry} passes, a
 * quarantined lane included (a raised flag is a clean bool); an
 * unallowlisted diamond, a dirty bool, a short answer, a pair rank
 * above one byte, a reverting probe and a codeless target each
 * revert the script.
 */
contract UpgradeReferralRegistrySeamProbeTest is Test, UpgradeReferralRegistry {

    address internal constant DIAMOND = address(0xD1A);

    uint64 internal constant LANE_A = 1_001;

    uint64 internal constant LANE_B = 1_002;

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        registry = new ReferralRegistry(
            address(this),
            1
        );
    }

    function exposedAssertRegistrySeams(
        address _registry,
        address _diamond,
        uint64[] memory _laneSelectors
    )
        external
        view
    {
        _assertRegistrySeams(
            _registry,
            _diamond,
            _laneSelectors
        );
    }

    function _lanes()
        internal
        pure
        returns (uint64[] memory lanes)
    {
        lanes = new uint64[](2);
        lanes[0] = LANE_A;
        lanes[1] = LANE_B;
    }

    function test_assertRegistrySeams_realRegistry_passes()
        public
    {
        registry.setAllowedVault(
            DIAMOND,
            true
        );

        registry.removeSyncPeer(
            LANE_B
        );

        assertTrue(registry.syncPeerQuarantined(LANE_B));
        assertFalse(registry.syncPeerQuarantined(LANE_A));

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenDiamondNotAllowlisted()
        public
    {
        vm.expectRevert(
            bytes("UpgradeReferralRegistry: diamond not allowlisted on the registry, so assignReferrer, mergeReferrer, stageCarry and consumeCarry would refuse it")
        );

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenQuarantineBoolDirty()
        public
    {
        registry.setAllowedVault(
            DIAMOND,
            true
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IReferralRegistry.syncPeerQuarantined.selector,
                LANE_A
            ),
            abi.encode(
                uint256(2)
            )
        );

        vm.expectRevert(
            bytes("UpgradeReferralRegistry: syncPeerQuarantined answer is not a clean bool")
        );

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenPairAnswerShort()
        public
    {
        registry.setAllowedVault(
            DIAMOND,
            true
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IReferralRegistry.getReferrerPair.selector,
                DIAMOND
            ),
            abi.encode(
                uint256(0),
                uint256(0)
            )
        );

        vm.expectRevert(
            bytes("UpgradeReferralRegistry: registry seam probe failed or returned the wrong size")
        );

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenPairRankAboveByte()
        public
    {
        registry.setAllowedVault(
            DIAMOND,
            true
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IReferralRegistry.getReferrerPair.selector,
                DIAMOND
            ),
            abi.encode(
                uint256(0),
                uint256(0),
                uint256(256)
            )
        );

        vm.expectRevert(
            bytes("UpgradeReferralRegistry: getReferrerPair answer outside the vault's decode bounds")
        );

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenProbeReverts()
        public
    {
        registry.setAllowedVault(
            DIAMOND,
            true
        );

        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSelector(
                IReferralRegistry.seedsLatched.selector
            ),
            bytes("")
        );

        vm.expectRevert(
            bytes("UpgradeReferralRegistry: registry seam probe failed or returned the wrong size")
        );

        this.exposedAssertRegistrySeams(
            address(registry),
            DIAMOND,
            _lanes()
        );
    }

    function test_assertRegistrySeams_revertsWhenTargetCodeless()
        public
    {
        vm.expectRevert(
            bytes("UpgradeReferralRegistry: config registry has no code")
        );

        this.exposedAssertRegistrySeams(
            address(0xBEEF),
            DIAMOND,
            _lanes()
        );
    }
}
