// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {CohortFlushPlanner} from "./CohortFlushPlanner.sol";
import {CohortFlushCodec} from "../../../shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralFlushHub} from "../../interfaces/pending/IReferralFlushHub.sol";

/**
 * @dev CohortFlushTransport: the flush guards, the cursor writes and the
 * hub send. A flush reverts FlushHubNotSet while the hub pointer is unset
 * and needs an armed recorder, an installed hook and a set registry. Only
 * the referrer's own flush writes its cursors, which only advance; a third
 * party waits for the first own flush, starts above both stored cursors and
 * is refused inside the outage grace that follows a reopen. The envelope
 * goes to the hub over CCIP, or directly on the hub chain, where a batch
 * takes at most LOCAL_FLUSH_ENTRIES referrers because the same transaction
 * pays the hub intake; any unused
 * fee is refunded. The deliverer the hub sees is the caller only when the
 * caller is an allowed flush bot; otherwise it
 * is zero in a CCIP header and the referrer itself on the hub chain, whose
 * intake refuses a zero deliverer. Either way only an allowlisted bot can
 * earn the courier fee, and a referrer that flushes its own book from a
 * second address earns nothing.
 */
abstract contract CohortFlushTransport is CohortFlushPlanner {

    function _courierOf()
        internal
        view
        returns (address)
    {
        return allowedFlushBot[msg.sender] == true
            ? msg.sender
            : ZERO_ADDRESS;
    }

    function _settleBeforePlan(
        address _referrer
    )
        internal
    {
        _cohortSettle(
            _referrer
        );
    }

    function _checkFlushBatch(
        uint256 _count
    )
        internal
        view
    {
        require(
            flushHub != ZERO_ADDRESS,
            FlushHubNotSet()
        );

        require(
            _count > 0,
            NothingToFlush()
        );

        require(
            _count <= CohortFlushCodec.MAX_FLUSH_ENTRIES
                && (flushHubChainSelector > 0 || _count <= LOCAL_FLUSH_ENTRIES),
            FlushBatchTooLarge()
        );
    }

    function _checkBookAdvanced(
        address _referrer
    )
        internal
        view
    {
        uint256 last = cohortLastSettle[_referrer];

        if (last == 0) {
            return;
        }

        uint256 target = _parkedAtDisarmCohort(
            last,
            cohortDisarmedAt,
            cohortRearmedAt
        )
            ? cohortDisarmedAt
            : block.timestamp;

        require(
            last / CohortWeeks.WEEK == target / CohortWeeks.WEEK,
            FlushBookNotAdvanced()
        );
    }

    function _checkFlushArmed()
        internal
        view
    {
        require(
            cohortSyncEnabled,
            CohortSyncDisabled()
        );

        require(
            transferHookFacet != ZERO_ADDRESS,
            CohortHookNotInstalled()
        );

        require(
            referralRegistry != ZERO_ADDRESS,
            ReferralRegistryNotSet()
        );
    }

    function _checkFlushCaller(
        address _referrer
    )
        internal
        view
    {
        require(
            _referrer != ZERO_ADDRESS,
            InvalidValue()
        );

        if (_referrer == msg.sender) {
            return;
        }

        require(
            publicFlushEnabled == true
                || allowedFlushBot[msg.sender] == true,
            NotFlushBot()
        );
    }

    function _checkFlushOutageGate(
        address _referrer,
        uint256 _firstWeek,
        uint256 _gapIndex,
        uint256 _gapResumeWeek
    )
        internal
        view
    {
        if (_referrer == msg.sender) {
            return;
        }

        uint256 unpause = referralReopenStamp;

        uint256 rearm = cohortRearmedAt;

        uint256 reopen = unpause;

        if (
            rearm > cohortDisarmedAt
                && rearm > reopen
        ) {
            reopen = rearm;
        }

        uint256 earliest = _firstWeek;

        if (_gapIndex < cohortGapLog[_referrer].length) {

            uint256 gapFirstWeek = CohortWeeks._gapRecordFromWeek(
                cohortGapLog[_referrer][_gapIndex]
            );

            if (_gapResumeWeek > gapFirstWeek) {
                gapFirstWeek = _gapResumeWeek;
            }

            if (gapFirstWeek < earliest) {
                earliest = gapFirstWeek;
            }
        }

        uint256 pauseDeadline = unpause
            + FLUSH_OUTAGE_GRACE
            + unpause
            - referralPauseStamp;

        if (referralPauseGraceEnd > pauseDeadline) {
            pauseDeadline = referralPauseGraceEnd;
        }

        uint256 disarmDeadline = rearm
            + FLUSH_OUTAGE_GRACE
            + rearm
            - cohortDisarmedAt;

        if (referralDisarmGraceEnd > disarmDeadline) {
            disarmDeadline = referralDisarmGraceEnd;
        }

        require(
            (earliest + 1) * CohortWeeks.WEEK > reopen
                || (block.timestamp >= pauseDeadline
                    && block.timestamp >= disarmDeadline),
            FlushOutageGraceActive()
        );
    }

    function _checkWindowStart(
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        internal
        view
    {
        if (_referrer == msg.sender) {
            return;
        }

        require(
            _fromWeek > flushedThroughWeek[_referrer],
            FlushWindowInvalid()
        );

        uint256 storedIndex = flushGapCursor[_referrer] & CohortWeeks.CARRY_HALF_MASK;

        require(
            _fromGapIndex >= storedIndex,
            FlushWindowInvalid()
        );
    }

    function _commitFlush(
        FlushEntryData[] memory _entries
    )
        internal
    {
        _requireThirdPartyLanesClear(
            _entries
        );

        for (uint256 i; i < _entries.length; ++i) {

            if (_entries[i].referrer == msg.sender) {
                _advanceFlushCursors(
                    _entries[i]
                );
            }
        }

        _dispatchFlush(
            _entries
        );
    }

    function _requireThirdPartyLanesClear(
        FlushEntryData[] memory _entries
    )
        internal
        view
    {
        for (uint256 i; i < _entries.length; ++i) {

            if (_entries[i].referrer == msg.sender) {
                continue;
            }

            require(
                flushedThroughWeek[_entries[i].referrer] != 0,
                FlushCursorVirgin()
            );
        }
    }

    function _advanceFlushCursors(
        FlushEntryData memory _entry
    )
        internal
    {
        bool changed;

        if (_entry.throughWeek > flushedThroughWeek[_entry.referrer]) {
            flushedThroughWeek[_entry.referrer] = _entry.throughWeek;
            changed = true;
        }

        uint256 stored = flushGapCursor[_entry.referrer];

        uint256 storedIndex = stored & CohortWeeks.CARRY_HALF_MASK;

        uint256 storedResume = stored >> FLUSH_GAP_CURSOR_WEEK_SHIFT;

        if (
            _entry.gapIndex > storedIndex
                || (
                    _entry.gapIndex == storedIndex
                        && _entry.gapResumeWeek > storedResume
                )
        ) {
            flushGapCursor[_entry.referrer] = _entry.gapIndex
                | (_entry.gapResumeWeek << FLUSH_GAP_CURSOR_WEEK_SHIFT);

            changed = true;
        }

        if (changed == false) {
            return;
        }

        uint256 cursor = flushGapCursor[_entry.referrer];

        emit CohortReferrerFlushed(
            _entry.referrer,
            flushedThroughWeek[_entry.referrer],
            cursor & CohortWeeks.CARRY_HALF_MASK,
            cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT
        );
    }

    function _dispatchFlush(
        FlushEntryData[] memory _entries
    )
        internal
    {
        address hub = flushHub;

        uint64 destChainSelector = flushHubChainSelector;

        if (destChainSelector == 0) {

            _deliverFlushLocal(
                hub,
                _entries
            );

            _refundExcessFlushFee(
                0
            );

            emit CohortFlushDelivered(
                hub,
                msg.sender,
                _entries.length
            );

            return;
        }

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        Client.EVM2AnyMessage memory message = _buildFlushMessage(
            hub,
            _packFlushEnvelope(
                _entries
            )
        );

        uint256 fee = IRouterClient(ccipRouter).getFee(
            destChainSelector,
            message
        );

        require(
            msg.value >= fee,
            InsufficientFlushFee()
        );

        bytes32 messageId = IRouterClient(ccipRouter).ccipSend{value: fee}(
            destChainSelector,
            message
        );

        _refundExcessFlushFee(
            fee
        );

        emit CohortFlushSent(
            messageId,
            destChainSelector,
            msg.sender,
            _entries.length
        );
    }

    function _deliverFlushLocal(
        address _hub,
        FlushEntryData[] memory _entries
    )
        internal
    {
        address courier = _courierOf();

        for (uint256 i; i < _entries.length; ++i) {

            address deliverer = courier == ZERO_ADDRESS
                ? _entries[i].referrer
                : courier;

            if (_entries[i].selfRuns.length > 0) {
                IReferralFlushHub(_hub).reportSelf(
                    _entries[i].referrer,
                    _entries[i].selfRuns
                );
            }

            if (_entries[i].crumbWeeks.length > 0) {
                IReferralFlushHub(_hub).deliverCrumbs(
                    _entries[i].referrer,
                    deliverer,
                    _entries[i].crumbWeeks,
                    _entries[i].crumbWords
                );
            }

            for (uint256 k; k < _entries[i].gapSlices.length; ++k) {

                uint256 slice = _entries[i].gapSlices[k];

                IReferralFlushHub(_hub).deliverGap(
                    _entries[i].referrer,
                    deliverer,
                    slice,
                    CohortWeeks._gapRecordFromWeek(
                        slice
                    ),
                    CohortWeeks._gapRecordToWeek(
                        slice
                    )
                        - CohortWeeks._gapRecordFromWeek(
                            slice
                        )
                );
            }
        }
    }

    function _packFlushEnvelope(
        FlushEntryData[] memory _entries
    )
        internal
        view
        returns (bytes memory)
    {
        uint256 total = 1;

        for (uint256 i; i < _entries.length; ++i) {
            total += 1
                + (_entries[i].designationWord != 0 ? 1 : 0)
                + _entries[i].selfRuns.length
                + _entries[i].crumbWeeks.length * 2
                + _entries[i].gapSlices.length;
        }

        uint256[] memory out = new uint256[](total);

        out[0] = CohortFlushCodec._packFlushHeader(
            _courierOf(),
            _entries.length,
            block.timestamp
        );

        uint256 cursor = 1;

        for (uint256 i; i < _entries.length; ++i) {

            FlushEntryData memory entry = _entries[i];

            uint256 flags = entry.designationWord != 0
                ? CohortFlushCodec.FLUSH_FLAG_DESIGNATION
                : 0;

            out[cursor] = CohortFlushCodec._packFlushEntry(
                entry.referrer,
                entry.crumbWeeks.length,
                entry.gapSlices.length,
                flags,
                entry.selfRuns.length
            );

            ++cursor;

            if (flags != 0) {
                out[cursor] = entry.designationWord;
                ++cursor;
            }

            for (uint256 k; k < entry.selfRuns.length; ++k) {
                out[cursor] = entry.selfRuns[k];
                ++cursor;
            }

            for (uint256 k; k < entry.crumbWeeks.length; ++k) {
                out[cursor] = entry.crumbWeeks[k];
                out[cursor + 1] = entry.crumbWords[k];
                cursor += 2;
            }

            for (uint256 k; k < entry.gapSlices.length; ++k) {
                out[cursor] = entry.gapSlices[k];
                ++cursor;
            }
        }

        return abi.encodePacked(
            out
        );
    }

    function _buildFlushMessage(
        address _hub,
        bytes memory _payload
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        uint64 gasLimit = flushGasLimit == 0
            ? FLUSH_GAS_LIMIT
            : flushGasLimit;

        return Client.EVM2AnyMessage({
            receiver: abi.encode(
                _hub
            ),
            data: _payload,
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

    function _refundExcessFlushFee(
        uint256 _fee
    )
        internal
    {
        uint256 refund = msg.value
            - _fee;

        if (refund == 0) {
            return;
        }

        (
            bool ok,
        ) = payable(msg.sender).call{value: refund}(
            ""
        );

        require(
            ok,
            FlushRefundFailed()
        );
    }
}
