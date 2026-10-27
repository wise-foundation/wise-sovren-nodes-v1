// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesDeclarations} from "../declarations/WiseSovrenNodesDeclarations.sol";
import {IReferralRegistry} from "../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev Base helper layer: access modifiers (`supplyChangeAllowed`),
 * small validators, field setters, and the interest-rate-proxy
 * validation gate.
 */
abstract contract WiseSovrenNodesBaseHelper is WiseSovrenNodesDeclarations {

    modifier supplyChangeAllowed() {
        _supplyChangeAllowed();
        _;
    }

    function _supplyChangeAllowed()
        internal
        view
    {
        require(
            supplyChangeByOwnerNotAllowed == false,
            SupplyChangeNotAllowed()
        );
    }

    function _validateInterestRateProxy()
        internal
        view
    {
        require(
            msg.sender == InterestRateProxy,
            NotInterestRateProxy()
        );
    }

    function _updateProxyBenefactor(
        address _proxyBeneFactor
    )
        internal
    {
        currentProxyBenefactor = _proxyBeneFactor;

        emit ProxyBenefactorSet(
            _proxyBeneFactor
        );
    }

    function _updateInterestRate(
        uint256 _interestRate
    )
        internal
    {
        require(
            _interestRate <= MAX_INTEREST_RATE,
            InterestRateTooHigh()
        );

        interestRate = _interestRate;

        emit InterestRateSet(
            _interestRate
        );

        if (_interestRate > bufferInterestRate) {
            bufferInterestRate = _interestRate;

            emit BufferInterestRateRaised(
                _interestRate
            );
        }
    }

    function _updateThirdPartyAddress(
        address _thirdPartyAddress
    )
        internal
    {
        thirdPartyAddress = _thirdPartyAddress;

        emit ThirdPartyAddressSet(
            _thirdPartyAddress
        );
    }

    function _proposeThirdPartyAddress(
        address _thirdPartyAddress
    )
        internal
    {
        require(
            _thirdPartyAddress != ZERO_ADDRESS,
            InvalidValue()
        );

        proposedThirdPartyAddress = _thirdPartyAddress;
        thirdPartyChangeQueuedAt = block.timestamp;

        emit ThirdPartyAddressProposed(
            _thirdPartyAddress,
            block.timestamp + THIRD_PARTY_CHANGE_DELAY
        );
    }

    function _applyThirdPartyAddressChange()
        internal
    {
        require(
            thirdPartyChangeQueuedAt > 0,
            NoThirdPartyChangeProposed()
        );

        require(
            block.timestamp >= thirdPartyChangeQueuedAt + THIRD_PARTY_CHANGE_DELAY,
            ThirdPartyTimelockNotElapsed()
        );

        address newThirdParty = proposedThirdPartyAddress;

        proposedThirdPartyAddress = ZERO_ADDRESS;
        thirdPartyChangeQueuedAt = 0;

        _updateThirdPartyAddress(
            newThirdParty
        );
    }

    function _cancelThirdPartyAddressChange()
        internal
    {
        address cancelled = proposedThirdPartyAddress;

        proposedThirdPartyAddress = ZERO_ADDRESS;
        thirdPartyChangeQueuedAt = 0;

        emit ThirdPartyAddressProposalCancelled(
            cancelled
        );
    }

    function _updateTransferHookFacet(
        address _facet
    )
        internal
    {
        transferHookFacet = _facet;

        emit TransferHookFacetSet(
            _facet
        );
    }

    function _proposeTransferHookFacet(
        address _facet
    )
        internal
    {
        proposedTransferHookFacet = _facet;
        transferHookChangeQueuedAt = block.timestamp;

        emit TransferHookFacetProposed(
            _facet,
            block.timestamp + TRANSFER_HOOK_CHANGE_DELAY
        );
    }

    function _applyTransferHookFacetChange()
        internal
    {
        require(
            transferHookChangeQueuedAt > 0,
            NoTransferHookChangeProposed()
        );

        if (initialized) {
            require(
                block.timestamp >= transferHookChangeQueuedAt + TRANSFER_HOOK_CHANGE_DELAY,
                TransferHookTimelockNotElapsed()
            );
        }

        address newFacet = proposedTransferHookFacet;

        require(
            newFacet == ZERO_ADDRESS
                || newFacet.code.length > 0,
            InvalidValue()
        );

        proposedTransferHookFacet = ZERO_ADDRESS;
        transferHookChangeQueuedAt = 0;

        _updateTransferHookFacet(
            newFacet
        );
    }

    function _cancelTransferHookFacetChange()
        internal
    {
        address cancelled = proposedTransferHookFacet;

        proposedTransferHookFacet = ZERO_ADDRESS;
        transferHookChangeQueuedAt = 0;

        emit TransferHookFacetProposalCancelled(
            cancelled
        );
    }

    function _updateDepositHookFacet(
        address _facet
    )
        internal
    {
        depositHookFacet = _facet;

        emit DepositHookFacetSet(
            _facet
        );
    }

    function _proposeDepositHookFacet(
        address _facet
    )
        internal
    {
        proposedDepositHookFacet = _facet;
        depositHookChangeQueuedAt = block.timestamp;

        emit DepositHookFacetProposed(
            _facet,
            block.timestamp + DEPOSIT_HOOK_CHANGE_DELAY
        );
    }

    function _applyDepositHookFacetChange()
        internal
    {
        require(
            depositHookChangeQueuedAt > 0,
            NoDepositHookChangeProposed()
        );

        if (initialized) {
            require(
                block.timestamp >= depositHookChangeQueuedAt + DEPOSIT_HOOK_CHANGE_DELAY,
                DepositHookTimelockNotElapsed()
            );
        }

        address newFacet = proposedDepositHookFacet;

        require(
            newFacet == ZERO_ADDRESS
                || newFacet.code.length > 0,
            InvalidValue()
        );

        proposedDepositHookFacet = ZERO_ADDRESS;
        depositHookChangeQueuedAt = 0;

        _updateDepositHookFacet(
            newFacet
        );
    }

    function _cancelDepositHookFacetChange()
        internal
    {
        address cancelled = proposedDepositHookFacet;

        proposedDepositHookFacet = ZERO_ADDRESS;
        depositHookChangeQueuedAt = 0;

        emit DepositHookFacetProposalCancelled(
            cancelled
        );
    }

    function _updateReferralRegistry(
        address _registry
    )
        internal
    {
        referralRegistry = _registry;

        emit ReferralRegistrySet(
            _registry
        );
    }

    function _proposeReferralRegistry(
        address _registry
    )
        internal
    {
        proposedReferralRegistry = _registry;
        referralRegistryChangeQueuedAt = block.timestamp;

        emit ReferralRegistryProposed(
            _registry,
            block.timestamp + REFERRAL_REGISTRY_CHANGE_DELAY
        );
    }

    function _applyReferralRegistryChange()
        internal
    {
        require(
            referralRegistryChangeQueuedAt > 0,
            NoReferralRegistryChangeProposed()
        );

        if (initialized) {
            require(
                block.timestamp >= referralRegistryChangeQueuedAt + REFERRAL_REGISTRY_CHANGE_DELAY,
                ReferralRegistryTimelockNotElapsed()
            );
        }

        address newRegistry = proposedReferralRegistry;

        require(
            newRegistry == ZERO_ADDRESS
                || _probeReferralRegistry(newRegistry),
            InvalidValue()
        );

        proposedReferralRegistry = ZERO_ADDRESS;
        referralRegistryChangeQueuedAt = 0;

        _updateReferralRegistry(
            newRegistry
        );
    }

    function _cancelReferralRegistryChange()
        internal
    {
        address cancelled = proposedReferralRegistry;

        proposedReferralRegistry = ZERO_ADDRESS;
        referralRegistryChangeQueuedAt = 0;

        emit ReferralRegistryProposalCancelled(
            cancelled
        );
    }

    function _probeReferralRegistry(
        address _registry
    )
        internal
        view
        returns (bool)
    {
        if (_registry.code.length == 0) {
            return false;
        }

        (
            bool success,
            bytes memory returnData
        ) = _registry.staticcall(
            abi.encodeWithSelector(
                IReferralRegistry.referrerOf.selector,
                address(this)
            )
        );

        return success
            && returnData.length == 32;
    }

    function _updateFlushHub(
        address _hub,
        uint64 _chainSelector
    )
        internal
    {
        flushHub = _hub;
        flushHubChainSelector = _chainSelector;

        emit FlushHubSet(
            _hub,
            _chainSelector
        );
    }

    function _proposeFlushHub(
        address _hub,
        uint64 _chainSelector
    )
        internal
    {
        proposedFlushHub = _hub;
        proposedFlushHubChainSelector = _chainSelector;
        flushHubChangeQueuedAt = block.timestamp;

        emit FlushHubProposed(
            _hub,
            _chainSelector,
            block.timestamp + FLUSH_HUB_CHANGE_DELAY
        );
    }

    function _applyFlushHubChange()
        internal
    {
        require(
            flushHubChangeQueuedAt > 0,
            NoFlushHubChangeProposed()
        );

        if (initialized) {
            require(
                block.timestamp >= flushHubChangeQueuedAt + FLUSH_HUB_CHANGE_DELAY,
                FlushHubTimelockNotElapsed()
            );
        }

        address newHub = proposedFlushHub;

        uint64 newSelector = proposedFlushHubChainSelector;

        require(
            newHub != ZERO_ADDRESS
                || newSelector == 0,
            InvalidValue()
        );

        proposedFlushHub = ZERO_ADDRESS;
        proposedFlushHubChainSelector = 0;
        flushHubChangeQueuedAt = 0;

        _updateFlushHub(
            newHub,
            newSelector
        );
    }

    function _cancelFlushHubChange()
        internal
    {
        address cancelled = proposedFlushHub;

        proposedFlushHub = ZERO_ADDRESS;
        proposedFlushHubChainSelector = 0;
        flushHubChangeQueuedAt = 0;

        emit FlushHubProposalCancelled(
            cancelled
        );
    }

    function _proposeWorkerAddress(
        address _worker
    )
        internal
    {
        require(
            _worker != ZERO_ADDRESS,
            InvalidValue()
        );

        proposedWorkerAddress = _worker;
        workerChangeQueuedAt = block.timestamp;

        emit WorkerAddressProposed(
            _worker,
            block.timestamp + WORKER_CHANGE_DELAY
        );
    }

    function _applyWorkerAddressChange()
        internal
    {
        require(
            workerChangeQueuedAt > 0,
            NoWorkerChangeProposed()
        );

        require(
            block.timestamp >= workerChangeQueuedAt + WORKER_CHANGE_DELAY,
            WorkerTimelockNotElapsed()
        );

        address newWorker = proposedWorkerAddress;

        workerAddress = newWorker;

        proposedWorkerAddress = ZERO_ADDRESS;
        workerChangeQueuedAt = 0;

        emit WorkerAddressSet(
            newWorker
        );
    }

    function _cancelWorkerAddressChange()
        internal
    {
        address cancelled = proposedWorkerAddress;

        proposedWorkerAddress = ZERO_ADDRESS;
        workerChangeQueuedAt = 0;

        emit WorkerAddressProposalCancelled(
            cancelled
        );
    }

    function _updateTotalDepositCap(
        uint256 _totalDepositCap
    )
        internal
    {
        require(
            _totalDepositCap >= totalSupply(),
            DepositCapBelowSupply()
        );

        totalDepositCap = _totalDepositCap;

        emit TotalDepositCapSet(
            _totalDepositCap
        );
    }

    function _checkDepositCap(
        uint256 _amount
    )
        internal
        view
    {
        if (totalSupply() + _amount > totalDepositCap) {
            revert DepositExceedCap();
        }
    }

    /**
     * @dev Relocation-out cap transfer: the burned relocation amount takes
     * its deposit-cap budget with it, keeping local room
     * (`totalDepositCap - totalSupply()`) unchanged. The checked subtraction
     * cannot underflow because `totalSupply() <= totalDepositCap` holds
     * globally (genesis mint is cap-checked, local mints are cap-checked,
     * relocations shift cap and supply equally and the cap setter floors at
     * the live supply) and the burn of `_amount <= totalSupply()` precedes
     * every call. A Panic here is a corrupted-state canary — do not replace
     * the subtraction with a saturating clamp.
     */
    function _reduceDepositCap(
        uint256 _amount
    )
        internal
    {
        totalDepositCap -= _amount;

        emit DepositCapRelocated(
            totalDepositCap
        );
    }

    /**
     * @dev Relocation-in cap transfer: the imported amount brings its
     * deposit-cap budget along, so the subsequent uncapped mint can never
     * push `totalSupply()` above `totalDepositCap`. Must be called before
     * the paired `_mint`.
     */
    function _raiseDepositCap(
        uint256 _amount
    )
        internal
    {
        totalDepositCap += _amount;

        emit DepositCapRelocated(
            totalDepositCap
        );
    }

    function _disableSupplyChangeByOwner()
        internal
    {
        supplyChangeByOwnerNotAllowed = true;

        emit SupplyChangeByOwnerNotAllowedSet(
            true
        );
    }

    function _updateWiseToken(
        address _wiseToken
    )
        internal
    {
        WISE_TOKEN = _wiseToken;

        emit WiseTokenSet(
            _wiseToken
        );
    }

    function _setDepositsDisabled(
        bool _disabled
    )
        internal
    {
        depositsDisabled = _disabled;

        emit DepositsDisabledSet(
            _disabled
        );
    }

    function _setGracePeriodDuration(
        uint256 _duration
    )
        internal
    {
        require(
            _duration <= MAX_GRACE_PERIOD,
            GracePeriodTooLong()
        );

        gracePeriodDuration = _duration;

        emit GracePeriodDurationSet(
            _duration
        );
    }

    function _setGraceThresholdAmount(
        uint256 _amount
    )
        internal
    {
        if (_amount > 0) {
            require(
                _amount >= 10 ** decimalsSet,
                GraceThresholdTooLow()
            );
        }

        graceThresholdAmount = _amount;

        emit GraceThresholdAmountSet(
            _amount
        );
    }

    function _setGraceFreezeEnabled(
        bool _enabled
    )
        internal
    {
        graceFreezeEnabled = _enabled;

        emit GraceFreezeEnabledSet(
            _enabled
        );
    }

    function _setCohortSyncEnabled(
        bool _enabled
    )
        internal
    {
        if (_enabled == true) {

            require(
                transferHookFacet != ZERO_ADDRESS,
                CohortHookNotInstalled()
            );

            require(
                referralRegistry != ZERO_ADDRESS,
                ReferralRegistryNotSet()
            );

            cohortSyncEnabled = true;

            _cohortSync(
                ZERO_ADDRESS
            );
        } else {
            cohortSyncEnabled = false;
        }

        emit CohortSyncEnabledSet(
            _enabled
        );
    }

    function _cohortSync(
        address _user
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_SYNC_SELECTOR,
                _user
            )
        );
    }

    function _cohortCredit(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_CREDIT_SELECTOR,
                _user,
                _amount
            )
        );
    }

    function _cohortAdvance(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_ADVANCE_SELECTOR,
                _referrer,
                _maxBoundaries
            )
        );
    }

    function _cohortSettle(
        address _referrer
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_SETTLE_SELECTOR,
                _referrer
            )
        );
    }

    function _cohortMoveOut(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_MOVE_OUT_SELECTOR,
                _user,
                _dstVault,
                _burnedAmount,
                _scaleNumerator,
                _scaleDenominator
            )
        );
    }

    function _cohortMoveIn(
        address _user,
        address _srcVault
    )
        internal
    {
        if (cohortSyncEnabled == false) {
            return;
        }

        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_MOVE_IN_SELECTOR,
                _user,
                _srcVault
            )
        );
    }

    function _cohortFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        internal
    {
        require(
            selectorToFacet[COHORT_FLIP_SELECTOR] != ZERO_ADDRESS,
            CohortSyncDisabled()
        );

        _runRoutedCohortHook(
            COHORT_FLIP_SELECTOR,
            abi.encodeWithSelector(
                COHORT_FLIP_SELECTOR,
                _user,
                _oldReferrer,
                _newReferrer
            )
        );
    }

    function _cohortBridgeOut(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
        returns (bytes memory)
    {
        if (cohortSyncEnabled == false) {
            return "";
        }

        (
            bool ran,
            bytes memory returnData
        ) = _runRoutedCohortHook(
            COHORT_BRIDGE_OUT_SELECTOR,
            abi.encodeWithSelector(
                COHORT_BRIDGE_OUT_SELECTOR,
                _user,
                _dstChainSelector,
                _burnedAmount,
                _scaleNumerator,
                _scaleDenominator
            )
        );

        if (ran == false) {

            _cohortSync(
                _user
            );

            return "";
        }

        return abi.decode(
            returnData,
            (bytes)
        );
    }

    function _cohortBridgeIn(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes memory _payload
    )
        internal
        returns (bool)
    {
        if (cohortSyncEnabled == false) {
            return false;
        }

        address facet = selectorToFacet[COHORT_BRIDGE_IN_SELECTOR];

        if (facet == ZERO_ADDRESS) {
            return false;
        }

        hookExecuting = true;

        uint256 gasForwarded = gasleft();

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            abi.encodeWithSelector(
                COHORT_BRIDGE_IN_SELECTOR,
                _user,
                _srcChainSelector,
                _mintedAmount,
                _payload
            )
        );

        hookExecuting = false;

        if (success == false || returnData.length != 32) {

            if (gasleft() <= gasForwarded / 64) {
                revert CohortBridgeInOutOfGas(
                    _user,
                    _srcChainSelector
                );
            }

            emit CohortBridgeHookFailed(
                _user,
                _srcChainSelector
            );

            return false;
        }

        return abi.decode(
            returnData,
            (bool)
        );
    }

    function _runRoutedCohortHook(
        bytes4 _selector,
        bytes memory _callData
    )
        internal
        returns (
            bool,
            bytes memory
        )
    {
        address facet = selectorToFacet[_selector];

        bytes memory empty;

        if (facet == ZERO_ADDRESS) {
            return (
                false,
                empty
            );
        }

        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            _callData
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return (
            true,
            returnData
        );
    }

    function _runCohortHook(
        bytes memory _callData
    )
        internal
    {
        address facet = transferHookFacet;

        if (facet == ZERO_ADDRESS) {
            return;
        }

        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            _callData
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _setSweeper(
        address _sweeper,
        bool _allowed
    )
        internal
    {
        if (_sweeper == ZERO_ADDRESS) {
            revert InvalidValue();
        }

        isSweeper[_sweeper] = _allowed;

        emit SweeperSet(
            _sweeper,
            _allowed
        );
    }

    function _setDepositAccumWindow(
        uint256 _window
    )
        internal
    {
        require(
            _window <= MAX_GRACE_PERIOD,
            DepositAccumWindowTooLong()
        );

        depositAccumWindow = _window;

        emit DepositAccumWindowSet(
            _window
        );
    }
}
