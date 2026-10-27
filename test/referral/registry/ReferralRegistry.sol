// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryAdmin} from "./ReferralRegistryAdmin.sol";
import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev ReferralRegistry: the write-once referrer registry of one chain.
 * An allowed vault assigns a user's referrer once; afterwards only the
 * strictly decreasing cross-chain min-merge and the dual consent
 * correction lane can change it. The correction lane also assigns a
 * referrer to a user who has none: master proposes on any chain of the
 * mesh, the user may cancel for three days, and the execute mints the
 * same mirrored key a correction mints, so a master assignment wins
 * every later merge and marks no flip (there is no old book to move).
 * A mutual dissolve that clears a user's record drops that user's
 * pending correction proposal with it, so no proposal revives on a key
 * that returns to zero. Sync keys travel over CCIP to the peer
 * registries, a flip is marked per tracked vault and delivered by a
 * permissionless poke, payout designations are set by the referrer and
 * pushed to the hub, and the same-chain carry mailbox is keyed by the
 * staging vault. Assign, merge, stage and consume make no external call,
 * and the read paths never revert.
 */
contract ReferralRegistry is
    ReferralRegistryAdmin,
    IAny2EVMMessageReceiver,
    IERC165
{

    uint256 public immutable LOCAL_CHAIN_RANK;

    constructor(
        address _master,
        uint256 _localChainRank
    )
        OwnableMaster(
            _master
        )
    {
        require(
            _localChainRank <= MAX_CHAIN_RANK,
            InvalidChainRank()
        );

        LOCAL_CHAIN_RANK = _localChainRank;

        maxSyncRank = _localChainRank > DEFAULT_MAX_SYNC_RANK
            ? _localChainRank
            : DEFAULT_MAX_SYNC_RANK;

        emit MaxSyncRankRaised(
            maxSyncRank
        );
    }

    function assignReferrer(
        address _user,
        address _referrer
    )
        external
        onlyAllowedVault
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

        if (referrerOf[_user] != ZERO_ADDRESS) {
            return;
        }

        _requireReferrerIdentity(
            _referrer
        );

        _requireNoReferralCycle(
            _user,
            _referrer
        );

        referrerOf[_user] = _referrer;

        referrerKey[_user] = _localSyncKey();

        emit ReferralAssigned(
            _user,
            _referrer,
            msg.sender
        );
    }

    function getReferrerPair(
        address _user
    )
        external
        view
        returns (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        )
    {
        referrer = referrerOf[_user];

        uint256 key = referrerKey[_user];

        assignedAt = key >> KEY_RANK_SHIFT;

        rank = key & KEY_RANK_MASK;
    }

    function effectiveReferrerOf(
        address _user,
        address _vault
    )
        external
        view
        returns (address)
    {
        address old = pendingFlip[_vault][_user];

        if (old != ZERO_ADDRESS) {
            return old;
        }

        return referrerOf[_user];
    }

    function mergeReferrer(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        external
        onlyAllowedVault
    {
        _mergeReferrerPair(
            _user,
            _referrer,
            _assignedAt,
            _rank
        );
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
    {
        require(
            msg.sender == ccipRouter,
            NotCcipRouter()
        );

        uint64 srcChainSelector = _message.sourceChainSelector;

        address srcPeer = abi.decode(
            _message.sender,
            (address)
        );

        require(
            syncPeerEnabled[srcChainSelector] == true,
            SyncPeerNotEnabled()
        );

        require(
            syncPeer[srcChainSelector] == srcPeer,
            SyncPeerMismatch()
        );

        require(
            processedSyncMessageId[_message.messageId] == false,
            SyncAlreadyProcessed()
        );

        processedSyncMessageId[_message.messageId] = true;

        require(
            _message.data.length == SYNC_PAYLOAD_LENGTH,
            SyncPayloadInvalid()
        );

        (
            uint256 version,
            address user,
            address referrer,
            uint256 assignedAt,
            uint256 rank
        ) = abi.decode(
            _message.data,
            (
                uint256,
                address,
                address,
                uint256,
                uint256
            )
        );

        require(
            version == SYNC_VERSION,
            SyncPayloadInvalid()
        );

        _mergeReferrerPair(
            user,
            referrer,
            assignedAt,
            rank
        );

        emit SyncReceived(
            srcChainSelector,
            _message.messageId,
            user
        );
    }

    function supportsInterface(
        bytes4 _interfaceId
    )
        external
        pure
        returns (bool)
    {
        return _interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }

    function broadcastSync(
        address _user,
        uint64[] calldata _selectors
    )
        external
        payable
    {
        (
            uint256 key,
            address router,
            address referrer
        ) = _syncLanePrelude(
            _user,
            _selectors
        );

        uint256 spentFee;

        for (uint256 i; i < _selectors.length; ++i) {

            uint64 selector = _selectors[i];

            Client.EVM2AnyMessage memory message = _syncLaneMessage(
                selector,
                _user,
                referrer,
                key
            );

            uint256 fee = _routerFee(
                router,
                selector,
                message
            );

            spentFee += fee;

            require(
                msg.value >= spentFee,
                InsufficientSyncFee()
            );

            bytes32 messageId = _routerSend(
                router,
                selector,
                message,
                fee
            );

            emit SyncBroadcast(
                _user,
                selector,
                referrer,
                key,
                messageId
            );
        }

        _refundExcess(
            spentFee,
            false
        );
    }

    function quoteSyncFee(
        address _user,
        uint64[] calldata _selectors
    )
        external
        view
        returns (uint256 totalFee)
    {
        (
            uint256 key,
            address router,
            address referrer
        ) = _syncLanePrelude(
            _user,
            _selectors
        );

        for (uint256 i; i < _selectors.length; ++i) {
            totalFee += _routerFee(
                router,
                _selectors[i],
                _syncLaneMessage(
                    _selectors[i],
                    _user,
                    referrer,
                    key
                )
            );
        }
    }

    function setPayoutAddress(
        address _payout
    )
        external
    {
        require(
            everAllowedVault[msg.sender] == false,
            InvalidPayoutOwner()
        );

        uint256 stamp = _localSyncKey();

        require(
            stamp > payoutStamp[msg.sender],
            PayoutStampNotNewer()
        );

        payoutAddress[msg.sender] = _payout;

        payoutStamp[msg.sender] = stamp;

        emit PayoutAddressSet(
            msg.sender,
            _payout,
            stamp
        );
    }

    function pushPayoutAddress(
        address _owner
    )
        external
        payable
    {
        (
            uint256 stamp,
            address hub,
            address router
        ) = _payoutPushPrelude(
            _owner
        );

        uint64 destChainSelector = payoutHubChainSelector;

        address payout = payoutAddress[_owner];

        Client.EVM2AnyMessage memory message = _payoutPushMessage(
            hub,
            _owner,
            stamp
        );

        uint256 fee = _routerFee(
            router,
            destChainSelector,
            message
        );

        require(
            msg.value >= fee,
            InsufficientPushFee()
        );

        bytes32 messageId = _routerSend(
            router,
            destChainSelector,
            message,
            fee
        );

        emit PayoutPushed(
            _owner,
            destChainSelector,
            payout,
            stamp,
            messageId
        );

        _refundExcess(
            fee,
            true
        );
    }

    function quotePushPayoutFee(
        address _owner
    )
        external
        view
        returns (uint256)
    {
        (
            uint256 stamp,
            address hub,
            address router
        ) = _payoutPushPrelude(
            _owner
        );

        return _routerFee(
            router,
            payoutHubChainSelector,
            _payoutPushMessage(
                hub,
                _owner,
                stamp
            )
        );
    }

    function getPayoutDesignation(
        address _owner
    )
        external
        view
        returns (
            address payout,
            uint256 stamp
        )
    {
        return (
            payoutAddress[_owner],
            payoutStamp[_owner]
        );
    }

    function pokeMigration(
        address _user
    )
        external
    {
        uint256 count = trackedVaults.length;

        for (uint256 i; i < count; ++i) {

            _pokeVault(
                trackedVaults[i],
                _user
            );
        }
    }

    function pokeMigrationAt(
        address _user,
        address _vault
    )
        external
    {
        _pokeVault(
            _vault,
            _user
        );
    }

    function proposeCorrectReferrer(
        address _user,
        address _newReferrer
    )
        external
        onlyMaster
    {
        require(
            correctionsLatched == false,
            CorrectionsDisabled()
        );

        require(
            _newReferrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _newReferrer != _user,
            SelfReferral()
        );

        _requireReferrerIdentity(
            _newReferrer
        );

        _requireNoReferralCycle(
            _user,
            _newReferrer
        );

        address current = referrerOf[_user];

        require(
            _newReferrer != current,
            NothingToCorrect()
        );

        require(
            current == ZERO_ADDRESS
                || (referrerKey[_user] & KEY_RANK_MASK) == LOCAL_CHAIN_RANK,
            WrongCorrectionChain()
        );

        proposedCorrection[_user] = _newReferrer;

        correctionQueuedAt[_user] = block.timestamp;

        proposedCorrectionKey[_user] = referrerKey[_user];

        emit ReferralCorrectionProposed(
            _user,
            current,
            _newReferrer,
            block.timestamp
        );
    }

    function cancelCorrectReferrer(
        address _user
    )
        external
    {
        require(
            msg.sender == _user || msg.sender == master,
            NotCorrectionParty()
        );

        require(
            correctionQueuedAt[_user] > 0,
            NoCorrectionProposed()
        );

        _dropCorrectionProposal(
            _user,
            msg.sender
        );
    }

    function executeCorrectReferrer(
        address _user
    )
        external
        onlyMaster
    {
        require(
            correctionsLatched == false,
            CorrectionsDisabled()
        );

        uint256 queuedAt = correctionQueuedAt[_user];

        require(
            queuedAt > 0,
            NoCorrectionProposed()
        );

        require(
            block.timestamp >= queuedAt + REFERRER_CORRECTION_DELAY,
            CorrectionTimelockNotElapsed()
        );

        address newReferrer = proposedCorrection[_user];

        _requireReferrerIdentity(
            newReferrer
        );

        _requireNoReferralCycle(
            _user,
            newReferrer
        );

        uint256 currentKey = referrerKey[_user];

        require(
            currentKey == proposedCorrectionKey[_user],
            NothingToCorrect()
        );

        uint256 correctedKey = block.timestamp < SYNC_KEY_MIRROR
            ? _packSyncKey(
                SYNC_KEY_MIRROR - block.timestamp,
                LOCAL_CHAIN_RANK
            )
            : 0;

        require(
            correctedKey != 0
                && (currentKey == 0 || correctedKey < currentKey),
            CorrectionKeyNotLower()
        );

        address oldReferrer = referrerOf[_user];

        delete proposedCorrection[_user];

        delete correctionQueuedAt[_user];

        delete proposedCorrectionKey[_user];

        referrerOf[_user] = newReferrer;

        referrerKey[_user] = correctedKey;

        if (oldReferrer != ZERO_ADDRESS) {
            _markPendingFlips(
                _user,
                oldReferrer
            );
        }

        emit ReferralCorrectionExecuted(
            _user,
            oldReferrer,
            newReferrer,
            correctedKey
        );
    }

    function latchCorrections()
        external
        onlyMaster
    {
        require(
            correctionsLatched == false,
            CorrectionsAlreadyLatched()
        );

        correctionsLatched = true;

        emit CorrectionsLatched();
    }

    function stageCarry(
        address _dstVault,
        address _user,
        uint256[] calldata _payload
    )
        external
        onlyAllowedVault
    {
        require(
            _dstVault != ZERO_ADDRESS
                && _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _dstVault != msg.sender
                && _payload.length > 0
                && _payload.length <= CohortWeeks.MAX_CARRY_WORDS,
            CarryPayloadInvalid()
        );

        carryPayload[msg.sender][_dstVault][_user] = _payload;

        carryStagedAt[msg.sender][_dstVault][_user] = block.timestamp;

        emit CarryStaged(
            msg.sender,
            _dstVault,
            _user,
            _payload.length
        );
    }

    function consumeCarry(
        address _srcVault,
        address _user
    )
        external
        onlyAllowedVault
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][msg.sender][_user];

        if (stagedAt == 0) {
            return (
                0,
                payload
            );
        }

        payload = carryPayload[_srcVault][msg.sender][_user];

        delete carryPayload[_srcVault][msg.sender][_user];

        delete carryStagedAt[_srcVault][msg.sender][_user];

        emit CarryConsumed(
            _srcVault,
            msg.sender,
            _user,
            stagedAt
        );
    }

    function getCarry(
        address _srcVault,
        address _dstVault,
        address _user
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][_dstVault][_user];

        payload = carryPayload[_srcVault][_dstVault][_user];
    }

    function _localSyncKey()
        internal
        view
        returns (uint256)
    {
        return _packSyncKey(
            block.timestamp,
            LOCAL_CHAIN_RANK
        );
    }
}
