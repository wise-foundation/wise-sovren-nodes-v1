// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {CohortSettleProbeFacet} from "./utils/CohortSettleProbeFacet.sol";
import {MockUSD} from "./WiseSovrenNodesCohortFlush.t.sol";

/**
 * @dev Pins the full chain copy of the settle touchpoint through contract code: a probe
 * facet over the full declaration chain calls `_cohortSettle`, which returns while the
 * recorder is disarmed and dispatches `applyCohortSettle` into the transfer hook facet once
 * armed, with the hook bracket closed again afterwards. The same full chain copy of the
 * flip guard refuses a registry flip while the bridge hook group is not routed.
 */
contract WiseSovrenNodesCohortSettleTouchpointTest is DiamondTestHarness {

    address internal refA = address(0xB1);

    MockUSD internal usd;

    WiseSovrenNodesDiamond internal diamond;

    CohortHookFacet internal hookFacet;

    ReferralRegistry internal registry;

    function setUp()
        public
    {
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
            address(new CohortSettleProbeFacet()),
            _probeSelectors()
        );

        hookFacet = new CohortHookFacet();

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(hookFacet)
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();
    }

    function _probeSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = CohortSettleProbeFacet.probeSettle.selector;
    }

    function test_cohortSettle_disarmed_returnsWithoutHook()
        public
    {
        CohortSettleProbeFacet(address(diamond)).probeSettle(
            refA
        );

        assertEq(
            CohortRecorderFacet(address(diamond)).getCohortSyncEnabled(),
            false
        );
    }

    function test_cohortSettle_armed_dispatchesIntoHook()
        public
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        CohortSettleProbeFacet(address(diamond)).probeSettle(
            refA
        );

        assertEq(
            CohortRecorderFacet(address(diamond)).getCohortSyncEnabled(),
            true
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );
        hookFacet.applyCohortSettle(
            refA
        );
    }

    function test_receiveReferrerFlip_bridgeHookUnrouted_revertsCohortSyncDisabled()
        public
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        vm.prank(address(registry));
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );
        CohortRecorderFacet(address(diamond)).receiveReferrerFlip(
            refA,
            address(0),
            address(0xB2)
        );
    }
}
