// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Custom errors for the WiseSovrenNodes diamond. Selectors match
 * the legacy error ABI so reverts decode identically.
 */
abstract contract WiseSovrenNodesDiamondErrors {

    error NoRewards();

    error NoInterest();

    error InvalidValue();

    error InvalidPosition();

    error DepositExceedCap();

    error DepositCapBelowSupply();

    error DepositsDisabled();

    error InterestRateTooHigh();

    error OldVaultNoCode();

    error OldVaultBadResponse();

    error InsufficientBalance();

    error SupplyChangeNotAllowed();

    error InsufficientInterest();

    error InterestRateProxyAlreadySet();

    error NotInterestRateProxy();

    error NotHookExecution();

    error NoOverhang();

    error NotSweeper();

    error NoWorkerChangeProposed();

    error WorkerTimelockNotElapsed();

    error NoThirdPartyChangeProposed();

    error ThirdPartyTimelockNotElapsed();

    error NoTransferHookChangeProposed();

    error TransferHookTimelockNotElapsed();

    error NoDepositHookChangeProposed();

    error DepositHookTimelockNotElapsed();

    error NoWiseToBurn();

    error WiseTokenNotSet();

    error WiseBurnCooldownNotElapsed();

    error GracePeriodNotElapsed();

    error GracePeriodTooLong();

    error GraceThresholdTooLow();

    error DepositAccumWindowTooLong();

    error Permit2NotDeployed();

    error PeerVaultNotEnabled();

    error NotPeerVault();

    error MoveAmountTooSmall();

    error SelfPeerNotAllowed();

    error InterestRateProxyCannotMove();

    error NoPeerVaultChangeProposed();

    error PeerVaultTimelockNotElapsed();

    // ---- Cross-chain bridge ----

    error RouterNotSet();

    error RouterAlreadySet();

    error NotCcipRouter();

    error CrossChainPeerNotEnabled();

    error CrossChainPeerMismatch();

    error NoCrossChainPeerChangeProposed();

    error CrossChainPeerTimelockNotElapsed();

    error InsufficientBridgeFee();

    error BridgeRefundFailed();

    error MessageAlreadyProcessed();

    error ReferralDataTooLong();

    error InvalidBridgeGasLimit();

    // ---- Referral registry ----

    error SelfReferral();

    error ReferralRegistryNotSet();

    error NoReferralRegistryChangeProposed();

    error ReferralRegistryTimelockNotElapsed();

    error NotReferralRegistry();

    error CohortSyncDisabled();

    error ReferralDataReserved();

    error ReferralRegistryChangeWhileArmed();

    // ---- Cohort recorder ----

    error CohortHookNotInstalled();

    error NothingToSeed();

    error SeedingLatched();

    // ---- Queue surface ----

    error ZeroAmount();

    error NotMember();

    error MemberAlreadyLeft();

    error IncentiveMismatch();

    error QueMemberIdTooHigh();

    error OrderNotReady();

    error AmountTooHigh();

    error IncentiveNotAllowed();

    error AmountTooLow();

    error NotProxyBenefactor();

    error AmountReceivedTooLow();

    error AmountSpentTooHigh();

    error NoOrdersPresent();

    error NegativeIncentiveNotAllowed();

    error SameIncentive();

    error ProtectedToken();

    // ---- Auto-compound ----

    error NotAutoCompoundBot();

    error AutoCompoundNotAllowed();

    error AutoCompoundFeeTooHigh();

    error ExceedsPendingPayout();

    // ---- Cohort flush ----

    error FlushHubNotSet();

    error NoFlushHubChangeProposed();

    error FlushHubTimelockNotElapsed();

    error NotFlushBot();

    error NothingToFlush();

    error FlushBatchTooLarge();

    error FlushWindowInvalid();

    error InsufficientFlushFee();

    error FlushRefundFailed();

    error InvalidFlushGasLimit();

    error CohortBridgeInOutOfGas(
        address user,
        uint64 srcChainSelector
    );

    error FlushOutageGraceActive();

    error FlushCursorVirgin();

    error FlushCadenceActive();

    error FlushBookNotAdvanced();
}
