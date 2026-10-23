// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryHelper} from "./ReferralRegistryHelper.sol";

/**
 * @dev ReferralRegistryAdmin: the master lanes of the registry. The CCIP
 * router, the sync peers, the payout hub and the allowed vaults change
 * through propose, timelock and execute; the setup setters stop at
 * `finalizeSyncSetup`. The tracked vault list never shrinks and stays
 * bounded.
 */
abstract contract ReferralRegistryAdmin is ReferralRegistryHelper {

    function latchSeeds()
        external
        onlyMaster
    {
        require(
            seedsLatched == false,
            SeedsAlreadyLatched()
        );

        seedsLatched = true;

        emit SeedsLatched();
    }

    function setCcipRouter(
        address _router
    )
        external
        onlyMaster
    {
        require(
            _router != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            ccipRouter == ZERO_ADDRESS,
            RouterAlreadySet()
        );

        ccipRouter = _router;

        emit CcipRouterSet(
            _router
        );
    }

    function proposeCcipRouter(
        address _router
    )
        external
        onlyMaster
    {
        require(
            _router != ZERO_ADDRESS,
            ZeroAddress()
        );

        proposedCcipRouter = _router;

        ccipRouterChangeQueuedAt = block.timestamp;

        emit CcipRouterProposed(
            _router,
            block.timestamp
        );
    }

    function executeCcipRouterChange()
        external
        onlyMaster
    {
        require(
            ccipRouterChangeQueuedAt > 0,
            NoCcipRouterProposed()
        );

        require(
            _timelockElapsed(
                ccipRouterChangeQueuedAt,
                SYNC_PEER_CHANGE_DELAY
            ),
            CcipRouterTimelockNotElapsed()
        );

        address router = proposedCcipRouter;

        ccipRouter = router;

        proposedCcipRouter = ZERO_ADDRESS;

        ccipRouterChangeQueuedAt = 0;

        emit CcipRouterSet(
            router
        );
    }

    function cancelCcipRouterChange()
        external
        onlyMaster
    {
        require(
            ccipRouterChangeQueuedAt > 0,
            NoCcipRouterProposed()
        );

        address router = proposedCcipRouter;

        proposedCcipRouter = ZERO_ADDRESS;

        ccipRouterChangeQueuedAt = 0;

        emit CcipRouterProposalCancelled(
            router
        );
    }

    function setSyncGasLimit(
        uint64 _gasLimit
    )
        external
        onlyMaster
    {
        require(
            _gasLimit >= SYNC_GAS_LIMIT
                && _gasLimit <= MAX_SYNC_GAS_LIMIT,
            InvalidSyncGasLimit()
        );

        if (_gasLimit == syncGasLimit) {
            return;
        }

        syncGasLimit = _gasLimit;

        emit SyncGasLimitSet(
            _gasLimit
        );
    }

    function raiseMaxSyncRank(
        uint256 _rank
    )
        external
        onlyMaster
    {
        require(
            _rank > maxSyncRank
                && _rank <= MAX_CHAIN_RANK,
            InvalidChainRank()
        );

        maxSyncRank = _rank;

        emit MaxSyncRankRaised(
            _rank
        );
    }

    function proposeSyncPeer(
        uint64 _chainSelector,
        address _peer
    )
        external
        onlyMaster
    {
        require(
            _peer != ZERO_ADDRESS,
            ZeroAddress()
        );

        proposedSyncPeer[_chainSelector] = _peer;

        syncPeerChangeQueuedAt[_chainSelector] = block.timestamp;

        emit SyncPeerProposed(
            _chainSelector,
            _peer,
            block.timestamp
        );
    }

    function executeSyncPeerChange(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address peer = proposedSyncPeer[_chainSelector];

        require(
            peer != ZERO_ADDRESS,
            NoSyncPeerProposed()
        );

        require(
            _timelockElapsed(
                syncPeerChangeQueuedAt[_chainSelector],
                SYNC_PEER_CHANGE_DELAY
            ),
            SyncPeerTimelockNotElapsed()
        );

        syncPeer[_chainSelector] = peer;

        syncPeerEnabled[_chainSelector] = true;

        delete proposedSyncPeer[_chainSelector];

        delete syncPeerChangeQueuedAt[_chainSelector];

        emit SyncPeerSet(
            _chainSelector,
            peer
        );

        if (syncPeerQuarantined[_chainSelector] == true) {

            delete syncPeerQuarantined[_chainSelector];

            emit SyncPeerQuarantineLifted(
                _chainSelector
            );
        }
    }

    function cancelSyncPeerChange(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address peer = proposedSyncPeer[_chainSelector];

        require(
            peer != ZERO_ADDRESS,
            NoSyncPeerProposed()
        );

        delete proposedSyncPeer[_chainSelector];

        delete syncPeerChangeQueuedAt[_chainSelector];

        emit SyncPeerProposalCancelled(
            _chainSelector,
            peer
        );
    }

    function removeSyncPeer(
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        address proposedPeer = proposedSyncPeer[_chainSelector];

        if (proposedPeer != ZERO_ADDRESS) {

            delete proposedSyncPeer[_chainSelector];

            delete syncPeerChangeQueuedAt[_chainSelector];

            emit SyncPeerProposalCancelled(
                _chainSelector,
                proposedPeer
            );
        }

        address peer = syncPeer[_chainSelector];

        if (peer != ZERO_ADDRESS) {

            syncPeerEnabled[_chainSelector] = false;

            delete syncPeer[_chainSelector];

            emit SyncPeerRemoved(
                _chainSelector,
                peer
            );
        }

        if (syncPeerQuarantined[_chainSelector] == true) {
            return;
        }

        syncPeerQuarantined[_chainSelector] = true;

        emit SyncPeerQuarantined(
            _chainSelector
        );
    }

    function finalizeSyncSetup()
        external
        onlyMaster
    {
        require(
            syncInitialized == false,
            SyncSetupAlreadyFinalized()
        );

        _requireRouter();

        syncInitialized = true;

        emit SyncSetupFinalized();
    }

    function proposePayoutHub(
        address _hub,
        uint64 _chainSelector
    )
        external
        onlyMaster
    {
        proposedPayoutHub = _hub;

        proposedPayoutHubChainSelector = _chainSelector;

        payoutHubChangeQueuedAt = block.timestamp;

        emit PayoutHubProposed(
            _hub,
            _chainSelector,
            block.timestamp
        );
    }

    function executePayoutHubChange()
        external
        onlyMaster
    {
        require(
            payoutHubChangeQueuedAt > 0,
            NoPayoutHubProposed()
        );

        require(
            _timelockElapsed(
                payoutHubChangeQueuedAt,
                PAYOUT_HUB_CHANGE_DELAY
            ),
            PayoutHubTimelockNotElapsed()
        );

        address hub = proposedPayoutHub;

        uint64 chainSelector = proposedPayoutHubChainSelector;

        require(
            (hub == ZERO_ADDRESS) == (chainSelector == 0),
            InvalidPayoutHub()
        );

        payoutHub = hub;

        payoutHubChainSelector = chainSelector;

        proposedPayoutHub = ZERO_ADDRESS;

        proposedPayoutHubChainSelector = 0;

        payoutHubChangeQueuedAt = 0;

        emit PayoutHubSet(
            hub,
            chainSelector
        );
    }

    function cancelPayoutHubChange()
        external
        onlyMaster
    {
        require(
            payoutHubChangeQueuedAt > 0,
            NoPayoutHubProposed()
        );

        address hub = proposedPayoutHub;

        proposedPayoutHub = ZERO_ADDRESS;

        proposedPayoutHubChainSelector = 0;

        payoutHubChangeQueuedAt = 0;

        emit PayoutHubProposalCancelled(
            hub
        );
    }

    function setAllowedVault(
        address _vault,
        bool _allowed
    )
        external
        onlyMaster
    {
        require(
            _vault != ZERO_ADDRESS,
            ZeroAddress()
        );

        if (_allowed == false) {

            if (allowedVaultQueuedAt[_vault] > 0) {

                delete allowedVaultQueuedAt[_vault];

                emit VaultAllowProposalCancelled(
                    _vault
                );
            }

            if (allowedVault[_vault] == false) {
                return;
            }

            allowedVault[_vault] = false;

            emit VaultAllowedSet(
                _vault,
                false
            );

            return;
        }

        require(
            everAllowedVault[_vault] == true || syncInitialized == false,
            VaultNotTracked()
        );

        _allowVault(
            _vault
        );
    }

    function proposeAllowedVault(
        address _vault
    )
        external
        onlyMaster
    {
        require(
            _vault != ZERO_ADDRESS,
            ZeroAddress()
        );

        allowedVaultQueuedAt[_vault] = block.timestamp;

        emit VaultAllowProposed(
            _vault,
            block.timestamp
        );
    }

    function executeAllowedVaultChange(
        address _vault
    )
        external
        onlyMaster
    {
        uint256 queuedAt = allowedVaultQueuedAt[_vault];

        require(
            queuedAt > 0,
            NoVaultAllowProposed()
        );

        require(
            _timelockElapsed(
                queuedAt,
                SYNC_PEER_CHANGE_DELAY
            ),
            VaultAllowTimelockNotElapsed()
        );

        delete allowedVaultQueuedAt[_vault];

        if (allowedVault[_vault] == true) {

            emit VaultAllowProposalCancelled(
                _vault
            );

            return;
        }

        _allowVault(
            _vault
        );
    }

    function cancelAllowedVaultChange(
        address _vault
    )
        external
        onlyMaster
    {
        require(
            allowedVaultQueuedAt[_vault] > 0,
            NoVaultAllowProposed()
        );

        delete allowedVaultQueuedAt[_vault];

        emit VaultAllowProposalCancelled(
            _vault
        );
    }

    function trackedVaultCount()
        external
        view
        returns (uint256)
    {
        return trackedVaults.length;
    }
}
