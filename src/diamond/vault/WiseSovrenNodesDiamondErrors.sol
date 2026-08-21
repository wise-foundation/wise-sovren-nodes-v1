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
}
