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
 * Counts: admin=27, proxy=3, user=8, sweep=2, cashedInterest=1,
 * queueForecast=1, interestAdmin=3, rescue=1, burnWise=3, move=7,
 * bridge=14, permit2=3, multicall=1, queueAdmin=3, queueJoinLeave=5,
 * queueFulfill=4, queueView=10 — 96 wired at genesis;
 * autoCompound=7 (4 functions + the 3 shard getters, which the
 * frozen live dispatcher cannot serve) routed post-genesis via the
 * selector timelock — total 103.
 */
library WiseSovrenNodesDiamondSelectors {

    function adminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](27);
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
    }

    function proxySelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = ProxyFacet.triggerAssignInterest.selector;
        sels[1] = ProxyFacet.increaseProxyBalance.selector;
        sels[2] = ProxyFacet.decreaseProxyBalance.selector;
    }

    function userSelectors()
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

    function sweepSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = SweepFacet.sweepOverhang.selector;
        sels[1] = SweepFacet.getOverhang.selector;
    }

    function cashedInterestSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = CashedInterestFacet.getTotalCashedInterest.selector;
    }

    function queueForecastSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = QueueForecastFacet.solveForAmountAfterFulfill.selector;
    }

    function interestAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = InterestAdminFacet.setCashedInterest.selector;
        sels[1] = InterestAdminFacet.setCashedInterestBulk.selector;
        sels[2] = InterestAdminFacet.syncInterestBulk.selector;
    }

    function rescueSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = RescueFacet.rescueToken.selector;
    }

    function burnWiseSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = BurnWiseFacet.burnWise.selector;
        sels[1] = BurnWiseFacet.getBurnableWise.selector;
        sels[2] = BurnWiseFacet.getNextBurnPercentage.selector;
    }

    function moveSelectors()
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

    function bridgeSelectors()
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

    function permit2Selectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = Permit2UserFacet.depositWithPermit2.selector;
        sels[1] = Permit2UserFacet.depositAndClaimInterestWithPermit2.selector;
        sels[2] = Permit2UserFacet.depositAndCompoundInterestWithPermit2.selector;
    }

    function multicallSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = MulticallFacet.multicall.selector;
    }

    function queueAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = QueueAdminFacet.changeMinDepositAmount.selector;
        sels[1] = QueueAdminFacet.setNegativeIncentivesNotAllowed.selector;
        sels[2] = QueueAdminFacet.setIncentivesAllowed.selector;
    }

    function queueJoinLeaveSelectors()
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

    function queueFulfillSelectors()
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

    function queueViewSelectors()
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

    function autoCompoundSelectors()
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
}
