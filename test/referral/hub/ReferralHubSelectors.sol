// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {ReferralHubCheckpointsFacet} from "./ReferralHubCheckpointsFacet.sol";
import {ReferralHubCheckpoints} from "./ReferralHubCheckpoints.sol";
import {ReferralHubRates} from "./ReferralHubRates.sol";
import {ReferralHubRatesFacet} from "./ReferralHubRatesFacet.sol";
import {ReferralHubIntakeFacet} from "./ReferralHubIntakeFacet.sol";
import {ReferralHubMailboxFacet} from "./ReferralHubMailboxFacet.sol";
import {ReferralHubPayoutFacet} from "./ReferralHubPayoutFacet.sol";

/// @title ReferralHubSelectors
/// @notice The facet selector groups of the {ReferralHub} diamond, in the
/// shape of the vault's own selector library. The deploy script and the test
/// harness wire these through the proxy before `finalizeSetup`; the hub's
/// routing pin asserts every selector routes to its facet. The storage
/// getters the declarations expose (USD_TOKEN, the score and claimable
/// counters, the source tables) and the ownership plus selector machinery
/// are proxy native and deliberately absent here. Count: intake 10,
/// mailbox 6, payout 5, rates 7, checkpoints 3, total 31.
library ReferralHubSelectors {

    function _intakeSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](10);

        selectors[0] = ReferralHubIntakeFacet.reportSelf.selector;

        selectors[1] = ReferralHubIntakeFacet.deliverCrumbs.selector;

        selectors[2] = ReferralHubIntakeFacet.deliverGap.selector;

        selectors[3] = ReferralHubIntakeFacet.setAllowedReporter.selector;

        selectors[4] = ReferralHubIntakeFacet.sourceKeyOf.selector;

        selectors[5] = ReferralHubIntakeFacet.sourceCountOf.selector;

        selectors[6] = ReferralHubIntakeFacet.sourceOfAt.selector;

        selectors[7] = ReferralHubIntakeFacet.paidCursorAtSource.selector;

        selectors[8] = ReferralHubIntakeFacet.setSourceSystem.selector;

        selectors[9] = ReferralHubIntakeFacet.settleWeeks.selector;
    }

    function _mailboxSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](6);

        selectors[0] = ReferralHubMailboxFacet.ccipReceive.selector;

        selectors[1] = ReferralHubMailboxFacet.applyFlush.selector;

        selectors[2] = ReferralHubMailboxFacet.supportsInterface.selector;

        selectors[3] = ReferralHubMailboxFacet.setCcipRouter.selector;

        selectors[4] = ReferralHubMailboxFacet.setFlushSource.selector;

        selectors[5] = ReferralHubMailboxFacet.setDesignationSource.selector;
    }

    function _payoutSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](5);

        selectors[0] = ReferralHubPayoutFacet.claim.selector;

        selectors[1] = ReferralHubPayoutFacet.claimUpTo.selector;

        selectors[2] = ReferralHubPayoutFacet.setPayoutAddress.selector;

        selectors[3] = ReferralHubPayoutFacet.payoutAddressOf.selector;

        selectors[4] = ReferralHubPayoutFacet.claimAll.selector;
    }

    function _ratesSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](7);

        selectors[0] = ReferralHubRatesFacet.pushRateTable.selector;

        selectors[1] = ReferralHubRates.weeklyRates.selector;

        selectors[2] = ReferralHubRates.rateTableCount.selector;

        selectors[3] = ReferralHubRates.rateTableAt.selector;

        selectors[4] = ReferralHubRatesFacet.setDelivererShareCap.selector;

        selectors[5] = ReferralHubRatesFacet.elevateReferrer.selector;

        selectors[6] = ReferralHubRatesFacet.endElevation.selector;
    }

    function _checkpointsSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](3);

        selectors[0] = ReferralHubCheckpoints.ladderInputsAt.selector;

        selectors[1] = ReferralHubCheckpoints.weekReportOf.selector;

        selectors[2] = ReferralHubCheckpoints.weekSelfOf.selector;
    }
}
