// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {CohortFlushCodec} from "../../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubMailbox: the CCIP intake of flush envelopes and payout
 * designations. A commitment binds selector, chain id, vault and payload,
 * so applying an envelope twice pays nothing twice. Each entry reports its
 * self runs before its crumbs and gap weeks, all for closed weeks only,
 * into the week buckets, whatever the envelope's build stamp. A zero header
 * deliverer means no courier (a vault packs one for any caller that is not
 * an allowed flush bot), so such an envelope pays no courier fee. A
 * malformed envelope reverts as a whole; a bad designation is skipped with
 * an event. Every path that stamps a designation releases the bucket's
 * backlog into `totalPayable`, the amount the hub's pot owes.
 */
abstract contract ReferralHubMailbox is ReferralHubIntake {

    struct FlushApplyContext {
        bytes32 source;
        uint256 chainId;
        address deliverer;
        uint256 cursor;
        uint256 work;
        bytes32 messageId;
    }

    function _receiveFlush(
        bytes32 _messageId,
        uint64 _srcChainSelector,
        address _vault,
        uint256 _chainId,
        bytes calldata _payload
    )
        internal
    {
        require(
            flushCommitment[_messageId] == bytes32(0),
            FlushAlreadyReceived()
        );

        flushCommitment[_messageId] = _flushCommitmentOf(
            _srcChainSelector,
            _chainId,
            _vault,
            _payload
        );

        emit FlushReceived(
            _messageId,
            _srcChainSelector,
            _vault,
            _chainId,
            _payload
        );
    }

    function _applyFlushEnvelope(
        bytes32 _messageId,
        uint64 _srcChainSelector,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        internal
    {
        require(
            flushCommitment[_messageId] == _flushCommitmentOf(
                _srcChainSelector,
                _chainId,
                _vault,
                _payload
            ),
            UnknownFlushCommitment()
        );

        require(
            flushSourceChainId[_srcChainSelector][_vault] == _chainId,
            UnknownFlushSource()
        );

        uint256 header = _flushWordAt(
            _payload,
            0
        );

        require(
            CohortFlushCodec._flushHeaderVersion(header) == CohortFlushCodec.FLUSH_VERSION
                && CohortFlushCodec._flushHeaderCrumbVersion(header) == CohortWeeks.CRUMB_VERSION
                && header >> CohortFlushCodec.FLUSH_HEADER_RESERVED_SHIFT == 0,
            FlushPayloadInvalid()
        );

        uint256 entryCount = CohortFlushCodec._flushHeaderEntryCount(
            header
        );

        require(
            entryCount > 0
                && entryCount <= CohortFlushCodec.MAX_FLUSH_ENTRIES,
            FlushPayloadInvalid()
        );

        FlushApplyContext memory context = FlushApplyContext({
            source: keccak256(
                abi.encode(
                    _chainId,
                    _vault
                )
            ),
            chainId: _chainId,
            deliverer: CohortFlushCodec._flushHeaderDeliverer(
                header
            ),
            cursor: 1,
            work: 0,
            messageId: _messageId
        });

        for (uint256 i; i < entryCount; ++i) {
            _applyFlushEntry(
                context,
                _payload
            );
        }

        require(
            context.cursor * 32 == _payload.length,
            FlushPayloadInvalid()
        );

        require(
            context.work <= CohortFlushCodec.MAX_FLUSH_WORK,
            FlushPayloadInvalid()
        );

        emit FlushApplied(
            _messageId,
            context.source,
            entryCount
        );
    }

    function _applyFlushEntry(
        FlushApplyContext memory _context,
        bytes calldata _payload
    )
        internal
    {
        uint256 entryWord = _flushWordAt(
            _payload,
            _context.cursor
        );

        require(
            entryWord >> CohortFlushCodec.FLUSH_ENTRY_RESERVED_SHIFT == 0,
            FlushPayloadInvalid()
        );

        address referrer = CohortFlushCodec._flushEntryReferrer(
            entryWord
        );

        require(
            referrer != ZERO_ADDRESS,
            FlushPayloadInvalid()
        );

        uint256 flags = CohortFlushCodec._flushEntryFlags(
            entryWord
        );

        require(
            flags & ~CohortFlushCodec.FLUSH_FLAG_DESIGNATION == 0,
            FlushPayloadInvalid()
        );

        ++_context.cursor;

        if (flags & CohortFlushCodec.FLUSH_FLAG_DESIGNATION != 0) {

            uint256 designationWord = _flushWordAt(
                _payload,
                _context.cursor
            );

            require(
                designationWord >> CohortFlushCodec.FLUSH_DESIGNATION_RESERVED_SHIFT == 0,
                FlushPayloadInvalid()
            );

            ++_context.cursor;

            _applyDesignationPair(
                _context.chainId,
                referrer,
                CohortFlushCodec._flushDesignationPayout(
                    designationWord
                ),
                CohortFlushCodec._flushDesignationSetAt(
                    designationWord
                ),
                CohortFlushCodec._flushDesignationRank(
                    designationWord
                )
            );
        }

        _applyFlushSelfRuns(
            _context,
            _payload,
            referrer,
            CohortFlushCodec._flushEntrySelfRunCount(
                entryWord
            )
        );

        _applyFlushCrumbs(
            _context,
            _payload,
            referrer,
            CohortFlushCodec._flushEntryCrumbCount(
                entryWord
            )
        );

        _applyFlushGaps(
            _context,
            _payload,
            referrer,
            CohortFlushCodec._flushEntryGapCount(
                entryWord
            )
        );
    }

    function _applyFlushSelfRuns(
        FlushApplyContext memory _context,
        bytes calldata _payload,
        address _referrer,
        uint256 _runCount
    )
        internal
    {
        for (uint256 k; k < _runCount; ++k) {

            _context.work += _applySelfRun(
                _context.source,
                _referrer,
                _flushWordAt(
                    _payload,
                    _context.cursor
                ),
                _context.chainId
            );

            ++_context.cursor;
        }
    }

    function _applyFlushCrumbs(
        FlushApplyContext memory _context,
        bytes calldata _payload,
        address _referrer,
        uint256 _crumbCount
    )
        internal
    {
        for (uint256 k; k < _crumbCount; ++k) {

            uint256 week = _flushWordAt(
                _payload,
                _context.cursor
            );

            uint256 word = _flushWordAt(
                _payload,
                _context.cursor + 1
            );

            _deliverCrumb(
                _context.source,
                _referrer,
                week,
                word,
                _deliveryOrigin(
                    _context
                )
            );

            _context.cursor += 2;

            ++_context.work;
        }
    }

    function _applyFlushGaps(
        FlushApplyContext memory _context,
        bytes calldata _payload,
        address _referrer,
        uint256 _gapCount
    )
        internal
    {
        for (uint256 k; k < _gapCount; ++k) {

            uint256 record = _flushWordAt(
                _payload,
                _context.cursor
            );

            _applyFlushGap(
                _context,
                _referrer,
                record
            );

            ++_context.cursor;
        }
    }

    function _applyFlushGap(
        FlushApplyContext memory _context,
        address _referrer,
        uint256 _record
    )
        internal
    {
        uint256 fromWeek = CohortWeeks._gapRecordFromWeek(
            _record
        );

        uint256 toWeek = CohortWeeks._gapRecordToWeek(
            _record
        );

        require(
            toWeek > fromWeek
                && toWeek - fromWeek <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            FlushPayloadInvalid()
        );

        _deliverGap(
            _context.source,
            _referrer,
            _record,
            fromWeek,
            toWeek - fromWeek,
            _deliveryOrigin(
                _context
            )
        );

        _context.work += toWeek - fromWeek;
    }

    function _receiveDesignationPush(
        uint64 _srcChainSelector,
        uint256 _chainId,
        bytes calldata _data
    )
        internal
    {
        require(
            _data.length == DESIGNATION_PAYLOAD_LENGTH,
            FlushPayloadInvalid()
        );

        (
            uint256 version,
            address owner,
            address payout,
            uint256 setAt,
            uint256 rank
        ) = abi.decode(
            _data,
            (
                uint256,
                address,
                address,
                uint256,
                uint256
            )
        );

        require(
            version == DESIGNATION_VERSION,
            FlushPayloadInvalid()
        );

        require(
            owner != ZERO_ADDRESS,
            FlushPayloadInvalid()
        );

        emit DesignationPushReceived(
            _srcChainSelector,
            _chainId,
            owner
        );

        _applyDesignationPair(
            _chainId,
            owner,
            payout,
            setAt,
            rank
        );
    }

    function _applyDesignationPair(
        uint256 _chainId,
        address _owner,
        address _payout,
        uint256 _setAt,
        uint256 _rank
    )
        internal
    {
        uint256 stamp = (_setAt << PAYOUT_STAMP_SHIFT) | _rank;

        if (
            _setAt == 0
                || _setAt > block.timestamp + MAX_DESIGNATION_FUTURE_DRIFT
                || _rank > type(uint8).max
        ) {

            emit FlushDesignationSkipped(
                _chainId,
                _owner,
                stamp
            );

            return;
        }

        uint256 stored = payoutStamp[_chainId][_owner];

        if (stamp <= stored) {
            return;
        }

        _stampPayout(
            _chainId,
            _owner,
            stamp
        );

        payoutAddress[_chainId][_owner] = _payout;

        emit PayoutAddressSet(
            _chainId,
            _owner,
            _payout
        );
    }

    function _deliveryOrigin(
        FlushApplyContext memory _context
    )
        internal
        pure
        returns (DeliveryOrigin memory)
    {
        return DeliveryOrigin({
            chainId: _context.chainId,
            deliverer: _context.deliverer,
            messageId: _context.messageId
        });
    }

    function _flushCommitmentOf(
        uint64 _srcChainSelector,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _srcChainSelector,
                _chainId,
                _vault,
                _payload
            )
        );
    }

    function _flushWordAt(
        bytes calldata _payload,
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        require(
            (_index + 1) * 32 <= _payload.length,
            FlushPayloadInvalid()
        );

        return abi.decode(
            _payload[_index * 32:_index * 32 + 32],
            (uint256)
        );
    }
}
