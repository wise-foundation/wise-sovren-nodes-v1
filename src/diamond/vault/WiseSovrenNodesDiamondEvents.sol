// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Event signatures for the WiseSovrenNodes diamond. The legacy-
 * parity block is byte-equivalent to the legacy event ABI so
 * off-chain consumers decode unchanged; diamond-specific events
 * are appended at the end.
 */
abstract contract WiseSovrenNodesDiamondEvents {

    // ---- Legacy parity events ----

    event ProxyBenefactorSet(
        address proxyBeneFactor
    );

    event InterestMoved(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event InterestRateProxySet(
        address interestRateProxy
    );

    event SupplyChangeByOwnerNotAllowedSet(
        bool supplyChangeByOwnerNotAllowed
    );

    event MintSupply(
        address indexed to,
        uint256 amount
    );

    event BurnSupply(
        address indexed from,
        uint256 amount
    );

    event Deposited(
        address indexed user,
        uint256 amount
    );

    event ThirdPartyAddressSet(
        address thirdPartyAddress
    );

    event ThirdPartyAddressProposed(
        address indexed proposedThirdParty,
        uint256 executableAt
    );

    event ThirdPartyAddressProposalCancelled(
        address indexed cancelledThirdParty
    );

    event TransferHookFacetSet(
        address transferHookFacet
    );

    event TransferHookFacetProposed(
        address indexed proposedTransferHookFacet,
        uint256 executableAt
    );

    event TransferHookFacetProposalCancelled(
        address indexed cancelledTransferHookFacet
    );

    event DepositHookFacetSet(
        address depositHookFacet
    );

    event DepositHookFacetProposed(
        address indexed proposedDepositHookFacet,
        uint256 executableAt
    );

    event DepositHookFacetProposalCancelled(
        address indexed cancelledDepositHookFacet
    );

    event InterestRateSet(
        uint256 interestRate
    );

    event TotalDepositCapSet(
        uint256 totalDepositCap
    );

    event DepositCapRelocated(
        uint256 newTotalDepositCap
    );

    event DepositsDisabledSet(
        bool depositsDisabled
    );

    event GracePeriodDurationSet(
        uint256 gracePeriodDuration
    );

    event GraceThresholdAmountSet(
        uint256 graceThresholdAmount
    );

    event GraceFreezeEnabledSet(
        bool graceFreezeEnabled
    );

    event LargeDepositRegistered(
        address indexed user,
        uint256 balanceIncrease,
        uint256 graceEndsAt
    );

    event DepositAccumWindowSet(
        uint256 depositAccumWindow
    );

    event DepositWindowAccumulated(
        address indexed user,
        uint256 windowTotal,
        uint256 windowEndsAt
    );

    event ClaimInterestSimple(
        address indexed user,
        uint256 interest
    );

    event CompoundInterest(
        address indexed user,
        uint256 interest
    );

    event ClaimInterestExactAmount(
        address indexed user,
        uint256 amount
    );

    event ProxyBalanceIncreased(
        address indexed proxyUser,
        uint256 amount
    );

    event ProxyBalanceDecreased(
        address indexed proxyUser,
        uint256 amount
    );

    event ProxyBeneFactorSet(
        address indexed proxyBeneFactor
    );

    event InterestRateProxyProposal(
        address indexed proxy,
        bool isProposing
    );

    event InterestRateProxyClaimed(
        address indexed proxy,
        bool isClaimed
    );

    event WorkerAddressSet(
        address indexed worker
    );

    event WorkerAddressProposed(
        address indexed proposedWorker,
        uint256 executableAt
    );

    event WorkerAddressProposalCancelled(
        address indexed cancelledWorker
    );

    event BufferInterestRateRaised(
        uint256 newBufferInterestRate
    );

    event OverhangSwept(
        address indexed worker,
        address indexed caller,
        uint256 amount
    );

    event TotalCashedInterestChanged(
        uint256 totalCashedInterest
    );

    event CashedInterestSet(
        address indexed user,
        uint256 previousAmount,
        uint256 newAmount
    );

    event InterestSynced(
        address indexed user,
        uint256 syncedAt
    );

    event TokenRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event SweeperSet(
        address indexed sweeper,
        bool allowed
    );

    event WiseBurned(
        address indexed caller,
        uint256 amount,
        uint256 percentageBps
    );

    event WiseTokenSet(
        address wiseToken
    );

    event PeerVaultSet(
        address indexed peer,
        bool enabled
    );

    event PeerVaultProposed(
        address indexed peer,
        uint256 executableAt
    );

    event PeerVaultProposalCancelled(
        address indexed peer
    );

    event MovedOut(
        address indexed user,
        address indexed dstVault,
        uint256 srcAmount,
        uint256 dstAmount
    );

    event MovedIn(
        address indexed user,
        address indexed srcVault,
        uint256 amount
    );

    event MoveDust(
        address indexed user,
        address indexed dstVault,
        uint256 dustAmount
    );

    // ---- Cross-chain bridge ----

    event CcipRouterSet(
        address indexed router
    );

    event CrossChainPeerProposed(
        uint64 indexed chainSelector,
        address indexed peer,
        uint256 executableAt
    );

    event CrossChainPeerSet(
        uint64 indexed chainSelector,
        address indexed peer,
        bool enabled
    );

    event CrossChainPeerProposalCancelled(
        uint64 indexed chainSelector
    );

    event BridgeSent(
        address indexed user,
        uint64 indexed destChainSelector,
        uint256 srcAmount,
        uint256 dstAmount,
        bytes32 messageId
    );

    event BridgeReceived(
        address indexed user,
        uint64 indexed srcChainSelector,
        uint256 amount,
        bytes32 messageId
    );

    event BridgeReferral(
        address indexed user,
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        bytes referralData
    );

    event ReferralEnabledSet(
        bool enabled
    );

    event BridgeGasLimitSet(
        uint256 gasLimit
    );

    // ---- Referral registry ----

    event ReferralRegistrySet(
        address referralRegistry
    );

    event ReferralRegistryProposed(
        address indexed proposedReferralRegistry,
        uint256 executableAt
    );

    event ReferralRegistryProposalCancelled(
        address indexed cancelledReferralRegistry
    );

    // ---- Cohort recorder ----

    event CohortContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    event CohortContributionSeeded(
        address indexed user,
        uint256 amount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortAttributionCharged(
        address indexed user,
        address indexed referrer,
        uint256 charged,
        uint256 uncharged
    );

    event CohortDivestParked(
        address indexed user
    );

    event CohortDivestDrained(
        address indexed user
    );

    event CohortDivestParkSkipped(
        address indexed user,
        address indexed parked
    );

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortBookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    event CohortGapRecorded(
        address indexed referrer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 maturePrincipal
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    event CohortSyncEnabledSet(
        bool enabled
    );

    event CohortCarryStaged(
        address indexed user,
        address indexed dstVault,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

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

    event CohortCarrySkipped(
        address indexed user,
        address indexed dstVault
    );

    event CohortCarryDiscarded(
        address indexed user,
        address indexed srcVault,
        uint256 stagedAt
    );

    event CohortCarryBookDropped(
        address indexed user,
        address indexed srcVault,
        address carriedReferrer,
        uint256 trackedDelta,
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

    event CohortBridgeCarrySent(
        address indexed user,
        uint64 indexed dstChainSelector,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        address bookReferrer
    );

    event CohortBridgeCarryApplied(
        address indexed user,
        uint64 indexed srcChainSelector,
        address indexed effectiveReferrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarryDiscarded(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortBridgeCarryBookDropped(
        address indexed user,
        uint64 indexed srcChainSelector,
        address carriedReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarrySkipped(
        address indexed user,
        uint64 indexed dstChainSelector
    );

    event CohortBridgeHookFailed(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortSelfCrumbSettled(
        address indexed user,
        uint256 settledAt,
        uint256 currentWeekSeconds,
        uint256 previousWeekSeconds
    );

    event CohortDisarmSpanSet(
        uint256 disarmedAt,
        uint256 rearmedAt
    );

    event CohortQuarantineReadFailed(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    // ---- Queue surface ----

    event JoinQue(
        address indexed member,
        uint256 amount,
        int256 incentive,
        uint256 queMemberId
    );

    event LeaveQue(
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 amount
    );

    event ReduceQueAmount(
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 reduceBy
    );

    event OrderProcessed(
        address indexed fulfiller,
        address indexed member,
        uint256 queMemberId,
        int256 incentive,
        uint256 amount,
        bool isFullFulfill
    );

    event CompoundViaQueue(
        address indexed user,
        uint256 interestConsumed,
        uint256 vaultTokensReceived,
        uint256 remainderCompounded
    );

    event SwitchQueIncentive(
        address indexed member,
        uint256 fromId,
        int256 fromIncentive,
        uint256 toId,
        int256 toIncentive,
        uint256 amount
    );

    event SwitchQueIncentivePartial(
        address indexed member,
        uint256 fromId,
        int256 fromIncentive,
        uint256 toId,
        int256 toIncentive,
        uint256 amount
    );

    // ---- Diamond machinery ----

    event SetupFinalized();

    event SelectorProposed(
        bytes4 indexed selector,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorsProposed(
        bytes4[] selectors,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorUpdated(
        bytes4 indexed selector,
        address indexed facet
    );

    event SelectorProposalCancelled(
        bytes4 indexed selector
    );

    event MinDepositAmountChanged(
        uint256 minDepositAmount
    );

    event NegativeIncentivesNotAllowedSet(
        bool negativeIncentivesNotAllowed
    );

    event IncentiveAllowedSet(
        int256 indexed incentive,
        bool allowed
    );

    // ---- Auto-compound ----

    event CompoundInterestOnBehalf(
        address indexed user,
        address indexed bot,
        uint256 netAmount,
        uint256 feeAmount
    );

    event AutoCompoundBotSet(
        address indexed bot,
        bool allowed
    );

    event AutoCompoundAllowedSet(
        address indexed user,
        bool allowed
    );

    event AutoCompoundFeeBpsSet(
        uint256 autoCompoundFeeBps
    );

    // ---- Cohort flush ----

    event FlushHubSet(
        address flushHub,
        uint64 flushHubChainSelector
    );

    event FlushHubProposed(
        address indexed proposedFlushHub,
        uint64 proposedFlushHubChainSelector,
        uint256 executableAt
    );

    event FlushHubProposalCancelled(
        address indexed cancelledFlushHub
    );

    event FlushBotAllowedSet(
        address indexed bot,
        bool allowed
    );

    event PublicFlushEnabledSet(
        bool enabled
    );

    event FlushGasLimitSet(
        uint64 flushGasLimit
    );

    event CohortFlushSent(
        bytes32 indexed messageId,
        uint64 indexed destChainSelector,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortFlushDelivered(
        address indexed flushHub,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortReferrerFlushed(
        address indexed referrer,
        uint256 flushedThroughWeek,
        uint256 flushedGapIndex,
        uint256 gapResumeWeek
    );
}
