// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Configuration surface. Every function is master-gated except
 * `setProxyBenefactor`, which is restricted to the interest-rate
 * proxy. Each function is a thin wrapper around an internal helper.
 * `executeTransferHookFacetChange` adds one guard before its helper:
 * it refuses a pending zero hook while the cohort recorder is armed;
 * `executeReferralRegistryChange` adds one guard before its helper:
 * it refuses any pending registry change while the cohort recorder is
 * armed; `setCohortSyncEnabled` records an actual disarm in the
 * slot-93 disarm shard before its helper runs, `pauseDeposits`
 * stamps the same shard's `referralPauseStamp` with the block time
 * on every actual pause, and `unpauseDeposits` stamps the shard's
 * `referralReopenStamp` with the block time on every actual unpause
 * and raises the slot-94 `referralPauseGraceEnd` tail word to the
 * grace end the closed span earned, the pause pair and its tail the
 * flush facet's courier gate reads beside the disarm stamps and
 * their own tail.
 */
contract AdminFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function disAllowSupplyChangeByOwner()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _disableSupplyChangeByOwner();
    }

    function mintSupply(
        address _to,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        assignInterest(_to)
        nonReentrant
        supplyChangeAllowed
    {
        _executeMintSupply(
            _to,
            _amount
        );
    }

    function burnSupply(
        address _from,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        assignInterest(_from)
        nonReentrant
        supplyChangeAllowed
    {
        _executeBurnSupply(
            _from,
            _amount
        );
    }

    function pauseDeposits()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _pause();

        referralPauseStamp = uint64(
            block.timestamp
        );
    }

    function unpauseDeposits()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _unpause();

        if (referralPauseStamp == 0) {
            referralPauseStamp = uint64(
                block.timestamp
            );
        }

        referralReopenStamp = uint64(
            block.timestamp
        );

        uint256 graceEnd = referralReopenStamp
            + FLUSH_OUTAGE_GRACE
            + referralReopenStamp
            - referralPauseStamp;

        if (graceEnd > referralPauseGraceEnd) {
            referralPauseGraceEnd = uint64(
                graceEnd
            );
        }
    }

    function proposeThirdPartyAddress(
        address _thirdPartyAddress
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeThirdPartyAddress(
            _thirdPartyAddress
        );
    }

    function executeThirdPartyAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyThirdPartyAddressChange();
    }

    function cancelThirdPartyAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelThirdPartyAddressChange();
    }

    function proposeTransferHookFacet(
        address _facet
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeTransferHookFacet(
            _facet
        );
    }

    /**
     * @dev While the cohort recorder is armed this refuses to execute a
     * pending zero hook ({CohortHookNotInstalled}): every cohort stub
     * would skip silently while the switch stays on, a state the flush
     * facet refuses as well. A pending cohort hook swap still executes
     * while armed, a zero hook executes once the recorder is disarmed,
     * and an execute with nothing pending still reverts
     * {NoTransferHookChangeProposed} from the helper. The armed refusal
     * is checked before the helper's timelock, so an armed execute of a
     * pending zero hook reverts {CohortHookNotInstalled} whether or not
     * the delay has elapsed.
     */
    function executeTransferHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            cohortSyncEnabled == false
                || proposedTransferHookFacet != ZERO_ADDRESS
                || transferHookChangeQueuedAt == 0,
            CohortHookNotInstalled()
        );

        _applyTransferHookFacetChange();
    }

    function cancelTransferHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelTransferHookFacetChange();
    }

    function proposeDepositHookFacet(
        address _facet
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeDepositHookFacet(
            _facet
        );
    }

    function executeDepositHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyDepositHookFacetChange();
    }

    function cancelDepositHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelDepositHookFacetChange();
    }

    function proposeReferralRegistry(
        address _registry
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeReferralRegistry(
            _registry
        );
    }

    /**
     * @dev While the cohort recorder is armed this refuses to execute
     * any pending registry change ({ReferralRegistryChangeWhileArmed}).
     * A replacement registry that answers no referrer for an account
     * assigned before the swap would make every later clamp of that
     * account lower its attributed contribution while skipping the old
     * book, so the old referrer would keep credit for departed principal
     * for good and the old registry's pending flip markers would never
     * migrate; a zero pointer would leave an armed recorder that defers
     * every clamp. A registry change is therefore a disarmed operation:
     * disarm, execute, re-arm (arming needs a nonzero pointer), and a
     * replacement must already carry every assignment made before the
     * swap. An execute with nothing pending still reverts
     * {NoReferralRegistryChangeProposed} from the helper. The armed
     * refusal is checked before the helper's timelock, so an armed
     * execute of a pending change reverts
     * {ReferralRegistryChangeWhileArmed} whether or not the delay has
     * elapsed.
     */
    function executeReferralRegistryChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            cohortSyncEnabled == false
                || referralRegistryChangeQueuedAt == 0,
            ReferralRegistryChangeWhileArmed()
        );

        _applyReferralRegistryChange();
    }

    function cancelReferralRegistryChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelReferralRegistryChange();
    }

    function getReferralRegistry()
        external
        view
        returns (address)
    {
        return referralRegistry;
    }

    function getProposedReferralRegistry()
        external
        view
        returns (address)
    {
        return proposedReferralRegistry;
    }

    function getReferralRegistryChangeQueuedAt()
        external
        view
        returns (uint256)
    {
        return referralRegistryChangeQueuedAt;
    }

    function proposeFlushHub(
        address _hub,
        uint64 _chainSelector
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeFlushHub(
            _hub,
            _chainSelector
        );
    }

    function executeFlushHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyFlushHubChange();
    }

    function cancelFlushHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelFlushHubChange();
    }

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        )
    {
        return (
            flushHub,
            flushHubChainSelector
        );
    }

    function getProposedFlushHub()
        external
        view
        returns (
            address,
            uint64
        )
    {
        return (
            proposedFlushHub,
            proposedFlushHubChainSelector
        );
    }

    function getFlushHubChangeQueuedAt()
        external
        view
        returns (uint256)
    {
        return flushHubChangeQueuedAt;
    }

    function proposeWorkerAddress(
        address _worker
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeWorkerAddress(
            _worker
        );
    }

    function executeWorkerAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyWorkerAddressChange();
    }

    function cancelWorkerAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelWorkerAddressChange();
    }

    function setInterestRate(
        uint256 _interestRate
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateInterestRate(
            _interestRate
        );
    }

    function setTotalDepositCap(
        uint256 _totalDepositCap
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateTotalDepositCap(
            _totalDepositCap
        );
    }

    function setProxyBenefactor(
        address _proxyBeneFactor
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _validateInterestRateProxy();

        _updateProxyBenefactor(
            _proxyBeneFactor
        );
    }

    function setWiseToken(
        address _wiseToken
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateWiseToken(
            _wiseToken
        );
    }

    function setDepositsDisabled(
        bool _disabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setDepositsDisabled(
            _disabled
        );
    }

    function setGracePeriodDuration(
        uint256 _duration
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGracePeriodDuration(
            _duration
        );
    }

    function setGraceThresholdAmount(
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGraceThresholdAmount(
            _amount
        );
    }

    function setGraceFreezeEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGraceFreezeEnabled(
            _enabled
        );
    }

    /**
     * @dev An actual disarm (an armed recorder switched off) stamps its
     * instant into the slot-93 disarm shard and clears the re-arm stamp
     * ({CohortDisarmSpanSet}), so the engine can zero-weight the span
     * once the arming call stamps its end; a disarm of a disarmed
     * recorder and every arm call leave the shard untouched here.
     */
    function setCohortSyncEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        if (_enabled == false && cohortSyncEnabled == true) {

            cohortDisarmedAt = uint64(block.timestamp);

            cohortRearmedAt = 0;

            emit CohortDisarmSpanSet(
                block.timestamp,
                0
            );
        }

        _setCohortSyncEnabled(
            _enabled
        );
    }

    function setSweeper(
        address _sweeper,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setSweeper(
            _sweeper,
            _allowed
        );
    }

    function setDepositAccumWindow(
        uint256 _window
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setDepositAccumWindow(
            _window
        );
    }
}
