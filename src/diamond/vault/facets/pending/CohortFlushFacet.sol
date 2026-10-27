// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {CohortFlushTransport} from "./CohortFlushTransport.sol";
import {CohortFlushCodec} from "../../../shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortFlushFacet: the referral flush entrypoints of a vault. A batch
 * flush or a single referrer window settles the books, plans the entries
 * and sends one envelope to the referral hub. A batch of more than one
 * referrer takes only books whose settle would cross no week boundary
 * (settled to the current week, or to the disarm instant while the book is
 * parked; anyone advances a book with the permissionless `advanceBook`), so
 * one call never walks more than one book's week boundaries; a single
 * referrer settles inline. The quote and preview views are no-settle lower bounds and stay
 * ungated.
 */
contract CohortFlushFacet is CohortFlushTransport {

    function flushReferrals(
        address[] calldata _referrers
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
    {
        _checkFlushBatch(
            _referrers.length
        );

        _checkFlushArmed();

        uint256 currentWeek = block.timestamp
            / CohortWeeks.WEEK;

        for (uint256 i; i < _referrers.length; ++i) {

            _checkFlushCaller(
                _referrers[i]
            );

            if (_referrers.length > 1) {
                _checkBookAdvanced(
                    _referrers[i]
                );
            }

            _settleBeforePlan(
                _referrers[i]
            );

            uint256 gapCursor = flushGapCursor[_referrers[i]];

            _checkFlushOutageGate(
                _referrers[i],
                _cursorFromWeek(
                    _referrers[i],
                    currentWeek
                ),
                gapCursor & CohortWeeks.CARRY_HALF_MASK,
                gapCursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT
            );
        }

        FlushEntryData[] memory entries = _planFlushBatch(
            _referrers
        );

        _commitFlush(
            entries
        );
    }

    function flushReferralWindow(
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
    {
        require(
            flushHub != ZERO_ADDRESS,
            FlushHubNotSet()
        );

        _checkFlushArmed();

        _checkFlushCaller(
            _referrer
        );

        require(
            _fromWeek <= block.timestamp / CohortWeeks.WEEK,
            FlushWindowInvalid()
        );

        require(
            _fromGapIndex <= cohortGapLog[_referrer].length,
            FlushWindowInvalid()
        );

        _checkWindowStart(
            _referrer,
            _fromWeek,
            _fromGapIndex
        );

        _settleBeforePlan(
            _referrer
        );

        uint256 windowGapResume = _windowGapResumeWeek(
            _referrer,
            _fromGapIndex
        );

        _checkFlushOutageGate(
            _referrer,
            _fromWeek,
            _fromGapIndex,
            windowGapResume
        );

        FlushEntryData[] memory entries = new FlushEntryData[](1);

        entries[0] = _planFlushEntry(
            _referrer,
            _fromWeek,
            _fromGapIndex,
            windowGapResume,
            _flushWorkBudget()
        );

        _commitFlush(
            entries
        );
    }

    function quoteFlushFee(
        address[] calldata _referrers
    )
        external
        view
        returns (uint256)
    {
        _checkFlushBatch(
            _referrers.length
        );

        if (flushHubChainSelector == 0) {
            return 0;
        }

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        FlushEntryData[] memory entries = _planFlushBatch(
            _referrers
        );

        return IRouterClient(ccipRouter).getFee(
            flushHubChainSelector,
            _buildFlushMessage(
                flushHub,
                _packFlushEnvelope(
                    entries
                )
            )
        );
    }

    function previewFlushEnvelope(
        address[] calldata _referrers
    )
        external
        view
        returns (bytes memory)
    {
        _checkFlushBatch(
            _referrers.length
        );

        return _packFlushEnvelope(
            _planFlushBatch(
                _referrers
            )
        );
    }
}
