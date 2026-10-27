// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {RescueFacet} from "../../src/diamond/vault/facets/RescueFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {WiseSovrenNodesQueueUIHelper} from "../../src/diamond/vault/helpers/WiseSovrenNodesQueueUIHelper.sol";
import {WiseSovrenNodesQueueHelper} from "../../src/diamond/vault/helpers/WiseSovrenNodesQueueHelper.sol";

/**
 * @dev Getter mirror of the auto-compound tail shard: Solidity
 * exposes no `.selector` for public state variables, so the routed
 * getter selectors come from here. Signature parity is asserted by
 * the facet tests and the live-fork getter reads.
 */
interface IAutoCompoundGetters {

    function isAutoCompoundBot(
        address _bot
    )
        external
        view
        returns (bool);

    function autoCompoundAllowed(
        address _user
    )
        external
        view
        returns (bool);

    function autoCompoundFeeBps()
        external
        view
        returns (uint256);
}

/**
 * @dev Single source of truth for WiseSovrenNodes facet selectors.
 * Deploy scripts and tests both import this library so the wiring
 * cannot drift.
 *
 * Counts: admin=40, proxy=3, user=8, sweep=2, cashedInterest=1,
 * queueForecast=1, interestAdmin=3, rescue=1, burnWise=3, move=7,
 * bridge=14, permit2=3, referral=4, permit2Referral=3,
 * cohortRecorder=15, cohortBridgeHook=3, cohortMoveHook=2,
 * cohortFlush=4, cohortFlushPolicy=9, multicall=1, queueAdmin=3,
 * queueJoinLeave=5, queueFulfill=4, queueView=10, autoCompound=7
 * (4 functions + the 3 shard getters, which the frozen live
 * dispatcher cannot serve); total 156, of which 96 are wired at
 * genesis (the genesis era admin group had 27; `setCohortSyncEnabled`
 * and the referral registry pointer six, propose/execute/cancel plus
 * the three routed getters backing the slot 77 shard's `internal`
 * fields, ship with the registry round's AdminFacet redeploy, and
 * the flush hub pointer six with the flush round's). The autoCompound
 * group was routed post genesis through the selector timelock and is
 * routed again by the registry round (its thirteenth batch) so the
 * live facet carries the cohort sync and credit stubs.
 * The referral groups (referral=4, permit2Referral=3), the
 * cohortRecorder, cohortBridgeHook and cohortMoveHook groups are
 * post launch: installed exclusively by the registry upgrade script,
 * never by the genesis deploy scripts, so the genesis wiring stays
 * identical to what is live in production.
 * The cohortFlush group is post launch and not yet installed: the
 * flush transport's two payable entrypoints, the fee quote and the
 * envelope preview, shipped by {UpgradeCohortFlush} together with
 * the grown AdminFacet and the settle aware {CohortHookFacet}; the
 * group's policy and read half (the three policy setters behind
 * master, the batched cursor reader and the five routed views
 * backing the slot 83 shard's `internal` fields) rides its own facet
 * ({CohortFlushPolicyFacet}, the cohortFlushPolicy group, same
 * upgrade) so the transport facet stays inside the EIP-170 runtime
 * budget. `applyTransferHook` and the slot 45 `applyCohort*`
 * entrypoints other than the forwarded move pair are deliberately
 * absent from every group: {CohortHookFacet} is reached only through
 * the `transferHookFacet` pointer, never the dispatcher. That pointer
 * only register holds seven entrypoints (the same chain move carry
 * pair `applyCohortMoveOut` / `applyCohortMoveIn` and the flush
 * transport's `applyCohortSettle` among them). The pointer facet
 * keeps forwarders for the move pair whose bodies live in the
 * dispatcher routed {CohortMoveHookFacet}, so the two move selectors
 * also appear in a routed group (cohortMoveHook). The cross chain
 * engine slice ({CohortBridgeHookFacet}: `applyCohortFlip` and the
 * bridge carry pair) is dispatcher routed too (the engine outgrew one
 * EIP-170 deployment), but its three selectors, like the two routed
 * move selectors, still revert on any direct external call (the
 * transient `hookExecuting` bracket only closes around the vault's
 * own internal dispatch), so the externally reachable surface grows
 * only by `receiveReferrerFlip` (registry only caller).
 *
 * `_referralSelectors` includes the routed `getReferrerOf` view (the
 * registry reading replacement for the retired slot 67 auto getter):
 * the live diamond keeps its genesis bytecode, so every post genesis
 * read surface must be routed to a facet explicitly; same story as
 * the six pointer selectors in the admin group.
 *
 * `_legacyReferralBridgeSelectors` is not a routed group but the
 * genesis passthrough pair inside `_bridgeSelectors`
 * (`bridgeToVaultWithReferral`, `quoteBridgeFeeWithReferral`): once
 * the recorder is armed the vault authors the bridge attachment
 * itself and both bridge entrypoints send identical wires, so
 * {UpgradeReferralRegistry} retires the pair to the zero facet after
 * its round through the same timelock; the counts above still
 * include them.
 */
library WiseSovrenNodesDiamondSelectors {

    function _adminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](40);
        sels[0] = AdminFacet.disAllowSupplyChangeByOwner.selector;
        sels[1] = AdminFacet.mintSupply.selector;
        sels[2] = AdminFacet.burnSupply.selector;
        sels[3] = AdminFacet.pauseDeposits.selector;
        sels[4] = AdminFacet.unpauseDeposits.selector;
        sels[5] = AdminFacet.proposeThirdPartyAddress.selector;
        sels[6] = AdminFacet.executeThirdPartyAddressChange.selector;
        sels[7] = AdminFacet.cancelThirdPartyAddressChange.selector;
        sels[8] = AdminFacet.setInterestRate.selector;
        sels[9] = AdminFacet.setTotalDepositCap.selector;
        sels[10] = AdminFacet.setProxyBenefactor.selector;
        sels[11] = AdminFacet.proposeWorkerAddress.selector;
        sels[12] = AdminFacet.executeWorkerAddressChange.selector;
        sels[13] = AdminFacet.cancelWorkerAddressChange.selector;
        sels[14] = AdminFacet.setWiseToken.selector;
        sels[15] = AdminFacet.proposeTransferHookFacet.selector;
        sels[16] = AdminFacet.executeTransferHookFacetChange.selector;
        sels[17] = AdminFacet.cancelTransferHookFacetChange.selector;
        sels[18] = AdminFacet.setDepositsDisabled.selector;
        sels[19] = AdminFacet.setGracePeriodDuration.selector;
        sels[20] = AdminFacet.setGraceThresholdAmount.selector;
        sels[21] = AdminFacet.setGraceFreezeEnabled.selector;
        sels[22] = AdminFacet.proposeDepositHookFacet.selector;
        sels[23] = AdminFacet.executeDepositHookFacetChange.selector;
        sels[24] = AdminFacet.cancelDepositHookFacetChange.selector;
        sels[25] = AdminFacet.setDepositAccumWindow.selector;
        sels[26] = AdminFacet.setSweeper.selector;
        sels[27] = AdminFacet.setCohortSyncEnabled.selector;
        sels[28] = AdminFacet.proposeReferralRegistry.selector;
        sels[29] = AdminFacet.executeReferralRegistryChange.selector;
        sels[30] = AdminFacet.cancelReferralRegistryChange.selector;
        sels[31] = AdminFacet.getReferralRegistry.selector;
        sels[32] = AdminFacet.getProposedReferralRegistry.selector;
        sels[33] = AdminFacet.getReferralRegistryChangeQueuedAt.selector;
        sels[34] = AdminFacet.proposeFlushHub.selector;
        sels[35] = AdminFacet.executeFlushHubChange.selector;
        sels[36] = AdminFacet.cancelFlushHubChange.selector;
        sels[37] = AdminFacet.getFlushHub.selector;
        sels[38] = AdminFacet.getProposedFlushHub.selector;
        sels[39] = AdminFacet.getFlushHubChangeQueuedAt.selector;
    }

    function _cohortRecorderSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](15);
        sels[0] = CohortRecorderFacet.syncReferee.selector;
        sels[1] = CohortRecorderFacet.advanceBook.selector;
        sels[2] = CohortRecorderFacet.getTrackedContribution.selector;
        sels[3] = CohortRecorderFacet.getCohortBook.selector;
        sels[4] = CohortRecorderFacet.getCohortScore.selector;
        sels[5] = CohortRecorderFacet.getCohortRings.selector;
        sels[6] = CohortRecorderFacet.getCohortWeekCrumb.selector;
        sels[7] = CohortRecorderFacet.getCohortGapLogLength.selector;
        sels[8] = CohortRecorderFacet.getCohortGapLogEntry.selector;
        sels[9] = CohortRecorderFacet.getCohortSyncEnabled.selector;
        sels[10] = CohortRecorderFacet.receiveReferrerFlip.selector;
        sels[11] = CohortRecorderFacet.seedCohortContribution.selector;
        sels[12] = CohortRecorderFacet.getCohortWeekCrumbs.selector;
        sels[13] = CohortRecorderFacet.getAttributedContribution.selector;
        sels[14] = CohortRecorderFacet.getCohortSelfCrumb.selector;
    }

    function _cohortBridgeHookSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = CohortBridgeHookFacet.applyCohortFlip.selector;
        sels[1] = CohortBridgeHookFacet.applyCohortBridgeOut.selector;
        sels[2] = CohortBridgeHookFacet.applyCohortBridgeIn.selector;
    }

    function _cohortMoveHookSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = CohortMoveHookFacet.applyCohortMoveOut.selector;
        sels[1] = CohortMoveHookFacet.applyCohortMoveIn.selector;
    }

    function _cohortFlushSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);
        sels[0] = CohortFlushFacet.flushReferrals.selector;
        sels[1] = CohortFlushFacet.flushReferralWindow.selector;
        sels[2] = CohortFlushFacet.quoteFlushFee.selector;
        sels[3] = CohortFlushFacet.previewFlushEnvelope.selector;
    }

    function _cohortFlushPolicySelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](9);
        sels[0] = CohortFlushPolicyFacet.setAllowedFlushBot.selector;
        sels[1] = CohortFlushPolicyFacet.setPublicFlushEnabled.selector;
        sels[2] = CohortFlushPolicyFacet.setFlushGasLimit.selector;
        sels[3] = CohortFlushPolicyFacet.getFlushedThroughWeek.selector;
        sels[4] = CohortFlushPolicyFacet.getFlushGapCursor.selector;
        sels[5] = CohortFlushPolicyFacet.getAllowedFlushBot.selector;
        sels[6] = CohortFlushPolicyFacet.getPublicFlushEnabled.selector;
        sels[7] = CohortFlushPolicyFacet.getFlushGasLimit.selector;
        sels[8] = CohortFlushPolicyFacet.getFlushCursors.selector;
    }

    function _proxySelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = ProxyFacet.triggerAssignInterest.selector;
        sels[1] = ProxyFacet.increaseProxyBalance.selector;
        sels[2] = ProxyFacet.decreaseProxyBalance.selector;
    }

    function _userSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](8);
        sels[0] = UserFacet.deposit.selector;
        sels[1] = UserFacet.claimInterest.selector;
        sels[2] = UserFacet.claimInterestExactAmount.selector;
        sels[3] = UserFacet.claimInterestPartiallyAndCompound.selector;
        sels[4] = UserFacet.compoundInterest.selector;
        sels[5] = UserFacet.depositAndClaimInterest.selector;
        sels[6] = UserFacet.depositAndCompoundInterest.selector;
        sels[7] = UserFacet.moveMyInterestTo.selector;
    }

    function _sweepSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = SweepFacet.sweepOverhang.selector;
        sels[1] = SweepFacet.getOverhang.selector;
    }

    function _cashedInterestSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = CashedInterestFacet.getTotalCashedInterest.selector;
    }

    function _queueForecastSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = QueueForecastFacet.solveForAmountAfterFulfill.selector;
    }

    function _interestAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = InterestAdminFacet.setCashedInterest.selector;
        sels[1] = InterestAdminFacet.setCashedInterestBulk.selector;
        sels[2] = InterestAdminFacet.syncInterestBulk.selector;
    }

    function _rescueSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = RescueFacet.rescueToken.selector;
    }

    function _autoCompoundSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](7);
        sels[0] = AutoCompoundFacet.compoundInterestOnBehalf.selector;
        sels[1] = AutoCompoundFacet.setAutoCompoundAllowed.selector;
        sels[2] = AutoCompoundFacet.setAutoCompoundBot.selector;
        sels[3] = AutoCompoundFacet.setAutoCompoundFeeBps.selector;
        sels[4] = IAutoCompoundGetters.isAutoCompoundBot.selector;
        sels[5] = IAutoCompoundGetters.autoCompoundAllowed.selector;
        sels[6] = IAutoCompoundGetters.autoCompoundFeeBps.selector;
    }

    function _burnWiseSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = BurnWiseFacet.burnWise.selector;
        sels[1] = BurnWiseFacet.getBurnableWise.selector;
        sels[2] = BurnWiseFacet.getNextBurnPercentage.selector;
    }

    function _moveSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](7);
        sels[0] = MoveFacet.proposePeerVault.selector;
        sels[1] = MoveFacet.executePeerVaultChange.selector;
        sels[2] = MoveFacet.cancelPeerVaultChange.selector;
        sels[3] = MoveFacet.removePeerVault.selector;
        sels[4] = MoveFacet.moveBetweenVaults.selector;
        sels[5] = MoveFacet.mintFromPeer.selector;
        sels[6] = MoveFacet.getMoveableBalance.selector;
    }

    function _bridgeSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](14);
        sels[0] = BridgeFacet.setCcipRouter.selector;
        sels[1] = BridgeFacet.proposeCrossChainPeer.selector;
        sels[2] = BridgeFacet.executeCrossChainPeerChange.selector;
        sels[3] = BridgeFacet.cancelCrossChainPeerChange.selector;
        sels[4] = BridgeFacet.removeCrossChainPeer.selector;
        sels[5] = BridgeFacet.bridgeToVault.selector;
        sels[6] = BridgeFacet.ccipReceive.selector;
        sels[7] = BridgeFacet.quoteBridgeFee.selector;
        sels[8] = BridgeFacet.getBridgeableBalance.selector;
        sels[9] = BridgeFacet.supportsInterface.selector;
        sels[10] = BridgeFacet.bridgeToVaultWithReferral.selector;
        sels[11] = BridgeFacet.quoteBridgeFeeWithReferral.selector;
        sels[12] = BridgeFacet.setReferralEnabled.selector;
        sels[13] = BridgeFacet.setBridgeGasLimit.selector;
    }

    function _legacyReferralBridgeSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = BridgeFacet.bridgeToVaultWithReferral.selector;
        sels[1] = BridgeFacet.quoteBridgeFeeWithReferral.selector;
    }

    function _permit2Selectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = Permit2UserFacet.depositWithPermit2.selector;
        sels[1] = Permit2UserFacet.depositAndClaimInterestWithPermit2.selector;
        sels[2] = Permit2UserFacet.depositAndCompoundInterestWithPermit2.selector;
    }

    function _referralSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);
        sels[0] = ReferralFacet.depositWithReferral.selector;
        sels[1] = ReferralFacet.depositAndClaimInterestWithReferral.selector;
        sels[2] = ReferralFacet.depositAndCompoundInterestWithReferral.selector;
        sels[3] = ReferralFacet.getReferrerOf.selector;
    }

    function _permit2ReferralSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = Permit2ReferralFacet.depositWithPermit2WithReferral.selector;
        sels[1] = Permit2ReferralFacet.depositAndClaimInterestWithPermit2WithReferral.selector;
        sels[2] = Permit2ReferralFacet.depositAndCompoundInterestWithPermit2WithReferral.selector;
    }

    function _multicallSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = MulticallFacet.multicall.selector;
    }

    function _queueAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = QueueAdminFacet.changeMinDepositAmount.selector;
        sels[1] = QueueAdminFacet.setNegativeIncentivesNotAllowed.selector;
        sels[2] = QueueAdminFacet.setIncentivesAllowed.selector;
    }

    function _queueJoinLeaveSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](5);
        sels[0] = QueueJoinLeaveFacet.joinQue.selector;
        sels[1] = QueueJoinLeaveFacet.leaveQue.selector;
        sels[2] = QueueJoinLeaveFacet.reduceQueAmount.selector;
        sels[3] = QueueJoinLeaveFacet.switchQueIncentive.selector;
        sels[4] = QueueJoinLeaveFacet.switchQueIncentivePartial.selector;
    }

    function _queueFulfillSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);
        sels[0] = QueueFulfillFacet.fulfillOrder.selector;
        sels[1] = QueueFulfillFacet.partiallyFulfillOrder.selector;
        sels[2] = QueueFulfillFacet.fulfillOrderBulk.selector;
        sels[3] = QueueFulfillFacet.compoundInterestViaFulfillBulk.selector;
    }

    function _queueViewSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](10);
        sels[0] = WiseSovrenNodesQueueUIHelper.getFulfillmentPlanForIncentive.selector;
        sels[1] = WiseSovrenNodesQueueUIHelper.solveForAmount.selector;
        sels[2] = WiseSovrenNodesQueueUIHelper.predictDiscountedAmount.selector;
        sels[3] = WiseSovrenNodesQueueUIHelper.predictCostForTokens.selector;
        sels[4] = WiseSovrenNodesQueueUIHelper.predictTokensForCost.selector;
        sels[5] = WiseSovrenNodesQueueUIHelper.getAllOrdersfromAddress.selector;
        sels[6] = WiseSovrenNodesQueueUIHelper.getAllOrdersOverall.selector;
        sels[7] = WiseSovrenNodesQueueHelper._solveForAmountWithIncentive.selector;
        sels[8] = WiseSovrenNodesQueueUIHelper.getAllOrdersOverallWithId.selector;
        sels[9] = WiseSovrenNodesQueueUIHelper.getAllOrdersfromAddressWithId.selector;
    }
}
