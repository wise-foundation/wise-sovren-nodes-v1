// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryDeclarations} from "./ReferralRegistryDeclarations.sol";
import {IVaultCohortFlip} from "./IVaultCohortFlip.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

/**
 * @dev ReferralRegistryHelper: the internal checks and transport of the
 * chain referral registry. A referrer can never be the registry, the
 * payout hub or any vault ever allowed, and an assignment never closes a
 * cycle. The min-merge accepts a remote pair only under the mirror floor,
 * the drift bound and the rank bound. A flip marker is deleted before its
 * vault is poked and restored only when the poke reverts, so each vault
 * migrates a user at most once, and a poke never calls an address without
 * code. A mutual dissolve that clears a user's record also drops that
 * user's pending correction proposal, so no proposal revives on a key
 * that returns to zero.
 */
abstract contract ReferralRegistryHelper is ReferralRegistryDeclarations {

    modifier onlyAllowedVault() {
        _onlyAllowedVault();
        _;
    }

    function _onlyAllowedVault()
        private
        view
    {
        if (allowedVault[msg.sender]) {
            return;
        }

        revert NotAllowedVault();
    }

    function _requireReferrerIdentity(
        address _referrer
    )
        internal
        view
    {
        require(
            _referrer != address(this)
                && _referrer != payoutHub
                && everAllowedVault[_referrer] == false,
            InvalidReferrer()
        );
    }

    function _requireNoReferralCycle(
        address _user,
        address _referrer
    )
        internal
        view
    {
        address walker = referrerOf[_referrer];

        while (walker != ZERO_ADDRESS) {

            require(
                walker != _user,
                InvalidReferrer()
            );

            require(
                gasleft() >= CYCLE_WALK_GAS_FLOOR,
                ReferralWalkGasCap()
            );

            walker = referrerOf[walker];
        }
    }

    function _dropCorrectionProposal(
        address _user,
        address _cancelledBy
    )
        internal
    {
        address dropped = proposedCorrection[_user];

        delete proposedCorrection[_user];

        delete correctionQueuedAt[_user];

        delete proposedCorrectionKey[_user];

        emit ReferralCorrectionCancelled(
            _user,
            dropped,
            _cancelledBy
        );
    }

    function _mergeReferrerPair(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
    {
        require(
            _user != ZERO_ADDRESS
                && _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != _user,
            SelfReferral()
        );

        require(
            _assignedAt > 0
                && _assignedAt <= block.timestamp + MAX_SYNC_FUTURE_DRIFT
                && _assignedAt
                    + block.timestamp
                    + MAX_SYNC_FUTURE_DRIFT >= SYNC_KEY_MIRROR
                && _rank <= maxSyncRank,
            SyncKeyInvalid()
        );

        uint256 incomingKey = _packSyncKey(
            _assignedAt,
            _rank
        );

        uint256 localKey = referrerKey[_user];

        _requireReferrerIdentity(
            _referrer
        );

        if (referrerOf[_referrer] == _user) {

            if (incomingKey >= referrerKey[_referrer]) {
                return;
            }

            if (localKey != 0 && incomingKey >= localKey) {
                return;
            }

            referrerOf[_referrer] = ZERO_ADDRESS;

            referrerKey[_referrer] = 0;

            if (correctionQueuedAt[_referrer] > 0) {
                _dropCorrectionProposal(
                    _referrer,
                    address(this)
                );
            }

            _markPendingFlips(
                _referrer,
                _user
            );

            emit ReferralMutualDissolved(
                _referrer,
                _user,
                incomingKey
            );
        }

        _requireNoReferralCycle(
            _user,
            _referrer
        );

        address localReferrer = referrerOf[_user];

        if (localKey == 0) {

            referrerOf[_user] = _referrer;

            referrerKey[_user] = incomingKey;

            emit ReferralSyncAdopted(
                _user,
                _referrer,
                incomingKey
            );

            return;
        }

        if (incomingKey >= localKey) {

            if (incomingKey == localKey && _referrer != localReferrer) {
                emit SyncKeyCollision(
                    _user,
                    localReferrer,
                    _referrer,
                    incomingKey
                );
            }

            return;
        }

        referrerKey[_user] = incomingKey;

        if (_referrer == localReferrer) {

            emit ReferralSyncKeyLowered(
                _user,
                _referrer,
                localKey,
                incomingKey
            );

            return;
        }

        referrerOf[_user] = _referrer;

        _markPendingFlips(
            _user,
            localReferrer
        );

        emit ReferralSyncFlipped(
            _user,
            localReferrer,
            _referrer,
            incomingKey
        );
    }

    function _pokeVault(
        address _vault,
        address _user
    )
        internal
    {
        address current = referrerOf[_user];

        address old = pendingFlip[_vault][_user];

        if (old == ZERO_ADDRESS) {
            return;
        }

        delete pendingFlip[_vault][_user];

        if (old == current || _vault.code.length == 0) {

            emit FlipCleared(
                _vault,
                _user,
                old
            );

            return;
        }

        try IVaultCohortFlip(_vault).receiveReferrerFlip(
            _user,
            old,
            current
        ) {
            emit FlipMigrated(
                _vault,
                _user,
                old,
                current
            );
        } catch {

            pendingFlip[_vault][_user] = old;

            emit FlipMigrationDeferred(
                _vault,
                _user,
                old,
                current
            );
        }
    }

    function _markPendingFlips(
        address _user,
        address _oldReferrer
    )
        internal
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            address vault = trackedVaults[i];

            if (pendingFlip[vault][_user] != ZERO_ADDRESS) {
                continue;
            }

            if (vault.code.length != 0) {
                try IVaultCohortFlip(vault).getAttributedContribution(
                    _user
                ) returns (uint256 attributed) {
                    if (attributed == 0) {
                        continue;
                    }
                } catch {}
            }

            pendingFlip[vault][_user] = _oldReferrer;

            emit FlipMarked(
                vault,
                _user,
                _oldReferrer
            );
        }
    }

    function _syncLanePrelude(
        address _user,
        uint64[] calldata _selectors
    )
        internal
        view
        returns (
            uint256 key,
            address router,
            address referrer
        )
    {
        require(
            _selectors.length > 0,
            NothingToSync()
        );

        require(
            _selectors.length <= MAX_SYNC_LANES,
            TooManySyncLanes()
        );

        key = referrerKey[_user];

        require(
            key != 0,
            NothingToSync()
        );

        router = _requireRouter();

        referrer = referrerOf[_user];
    }

    function _syncLaneMessage(
        uint64 _selector,
        address _user,
        address _referrer,
        uint256 _key
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        require(
            syncPeerEnabled[_selector] == true,
            SyncPeerNotEnabled()
        );

        return _buildCcipMessage(
            syncPeer[_selector],
            SYNC_VERSION,
            _user,
            _referrer,
            _key
        );
    }

    function _payoutPushMessage(
        address _hub,
        address _owner,
        uint256 _stamp
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return _buildCcipMessage(
            _hub,
            PAYOUT_PUSH_VERSION,
            _owner,
            payoutAddress[_owner],
            _stamp
        );
    }

    function _routerFee(
        address _router,
        uint64 _selector,
        Client.EVM2AnyMessage memory _message
    )
        internal
        view
        returns (uint256)
    {
        return IRouterClient(_router).getFee(
            _selector,
            _message
        );
    }

    function _routerSend(
        address _router,
        uint64 _selector,
        Client.EVM2AnyMessage memory _message,
        uint256 _fee
    )
        internal
        returns (bytes32)
    {
        return IRouterClient(_router).ccipSend{value: _fee}(
            _selector,
            _message
        );
    }

    function _requireRouter()
        internal
        view
        returns (address router)
    {
        router = ccipRouter;

        require(
            router != ZERO_ADDRESS,
            RouterNotSet()
        );
    }

    function _payoutPushPrelude(
        address _owner
    )
        internal
        view
        returns (
            uint256 stamp,
            address hub,
            address router
        )
    {
        stamp = payoutStamp[_owner];

        require(
            stamp != 0,
            NothingToPush()
        );

        hub = payoutHub;

        require(
            hub != ZERO_ADDRESS,
            PayoutHubNotSet()
        );

        router = _requireRouter();
    }

    function _buildCcipMessage(
        address _receiver,
        uint256 _version,
        address _first,
        address _second,
        uint256 _stamp
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        uint64 gasLimit = syncGasLimit == 0
            ? SYNC_GAS_LIMIT
            : syncGasLimit;

        return Client.EVM2AnyMessage({
            receiver: abi.encode(
                _receiver
            ),
            data: abi.encode(
                _version,
                _first,
                _second,
                _stamp >> KEY_RANK_SHIFT,
                _stamp & KEY_RANK_MASK
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: ZERO_ADDRESS,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: true
                })
            )
        });
    }

    function _refundExcess(
        uint256 _spentFee,
        bool _push
    )
        internal
    {
        if (msg.value <= _spentFee) {
            return;
        }

        (
            bool ok,
        ) = msg.sender.call{
            value: msg.value - _spentFee
        }(
            ""
        );

        if (ok) {
            return;
        }

        if (_push) {
            revert PushRefundFailed();
        }

        revert SyncRefundFailed();
    }

    function _timelockElapsed(
        uint256 _queuedAt,
        uint256 _delay
    )
        internal
        view
        returns (bool)
    {
        return syncInitialized == false
            || block.timestamp >= _queuedAt + _delay;
    }

    function _allowVault(
        address _vault
    )
        internal
    {
        if (allowedVault[_vault] == true) {
            return;
        }

        allowedVault[_vault] = true;

        _trackVault(
            _vault
        );

        emit VaultAllowedSet(
            _vault,
            true
        );
    }

    function _trackVault(
        address _vault
    )
        internal
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            if (trackedVaults[i] == _vault) {
                return;
            }
        }

        require(
            count < MAX_TRACKED_VAULTS,
            TooManyTrackedVaults()
        );

        everAllowedVault[_vault] = true;

        trackedVaults.push(
            _vault
        );
    }

    function _packSyncKey(
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_assignedAt << KEY_RANK_SHIFT) | _rank;
    }
}
