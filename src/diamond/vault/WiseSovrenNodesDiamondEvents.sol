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
}
