// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesDeclarations} from "../declarations/WiseSovrenNodesDeclarations.sol";

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
