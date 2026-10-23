// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IReferralHub} from "./IReferralHub.sol";
import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubReader: a stateless read companion of the hub, built
 * only from its primitive getters, so it can be redeployed at any time. It
 * batches the week bucket reads (a referrer's ladder inputs per week and a
 * source's reported referred average and paid units per week), the paid
 * cursors, the claimables and the weekly rates, and serves two account
 * views for a dashboard: one referrer's claimables over several source
 * chains with the payout address each would pay, and one referrer's
 * standing on the ladder of a week (both inputs, the tier each reaches,
 * the next threshold of each and the rates). The tier walk mirrors the
 * hub's rate computation over the same table the hub picks for the week.
 */
contract ReferralHubReader {

    IReferralHub public immutable HUB;

    error ZeroAddress();

    struct LadderStanding {
        uint256 referredInput;
        uint256 selfInput;
        uint256 referredTierBps;
        uint256 selfTierBps;
        uint256 nextReferredThreshold;
        uint256 nextSelfThreshold;
        uint256 y1Bps;
        uint256 y2Bps;
        uint256 mBps;
        uint256 elevatedFromWeek;
        uint256 elevatedUntilWeek;
        bool elevated;
    }

    constructor(
        address _hub
    ) {
        require(
            _hub != address(0),
            ZeroAddress()
        );

        HUB = IReferralHub(
            _hub
        );
    }

    function ladderInputsRange(
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (
            uint256[] memory referredInputs,
            uint256[] memory selfInputs
        )
    {
        referredInputs = new uint256[](
            _count
        );

        selfInputs = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {
            (
                referredInputs[i],
                selfInputs[i]
            ) = HUB.ladderInputsAt(
                _referrer,
                _fromWeek + i
            );
        }
    }

    function weekReportsAtSource(
        bytes32 _source,
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (
            uint256[] memory referredAverages,
            uint256[] memory paidUnits
        )
    {
        referredAverages = new uint256[](
            _count
        );

        paidUnits = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {
            (
                referredAverages[i],
                paidUnits[i]
            ) = HUB.weekReportOf(
                _source,
                _referrer,
                _fromWeek + i
            );
        }
    }

    function paidCursorAt(
        address _reporter,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        )
    {
        return HUB.paidCursorAtSource(
            HUB.sourceKeyOf(
                block.chainid,
                _reporter
            ),
            _referrer,
            _week
        );
    }

    function paidCursorsAtSource(
        bytes32 _source,
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (uint256[] memory cursorWords)
    {
        cursorWords = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {

            (
                uint256 y1Cursor,
                uint256 y2Cursor,
                uint256 mCursor
            ) = HUB.paidCursorAtSource(
                _source,
                _referrer,
                _fromWeek + i
            );

            cursorWords[i] = CohortWeeks._packLanes(
                y1Cursor,
                y2Cursor,
                mCursor
            );
        }
    }

    function claimableOf(
        uint256 _chainId,
        address[] calldata _referrers
    )
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](
            _referrers.length
        );

        for (uint256 i; i < _referrers.length; ++i) {
            amounts[i] = HUB.claimable(
                _chainId,
                _referrers[i]
            );
        }
    }

    function weeklyRatesRange(
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (
            uint256[] memory y1Bps,
            uint256[] memory y2Bps,
            uint256[] memory mBps
        )
    {
        y1Bps = new uint256[](
            _count
        );

        y2Bps = new uint256[](
            _count
        );

        mBps = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {
            (
                y1Bps[i],
                y2Bps[i],
                mBps[i]
            ) = HUB.weeklyRates(
                _referrer,
                _fromWeek + i
            );
        }
    }

    /**
     * @dev Per source chain id: the claimable amount and the address a
     * claim would pay, zero while that chain's payout designation has not
     * reached the hub (such a bucket cannot be claimed yet). `total` sums
     * every amount, `claimableNow` only the designated ones; both are
     * before the payout pool's funding.
     */
    function claimablesOf(
        address _referrer,
        uint256[] calldata _chainIds
    )
        external
        view
        returns (
            uint256[] memory amounts,
            address[] memory payouts,
            uint256 total,
            uint256 claimableNow
        )
    {
        amounts = new uint256[](
            _chainIds.length
        );

        payouts = new address[](
            _chainIds.length
        );

        for (uint256 i; i < _chainIds.length; ++i) {
            amounts[i] = HUB.claimable(
                _chainIds[i],
                _referrer
            );

            payouts[i] = HUB.payoutAddressOf(
                _chainIds[i],
                _referrer
            );

            total += amounts[i];

            if (payouts[i] != address(0)) {
                claimableNow += amounts[i];
            }
        }
    }

    /**
     * @dev A week's inputs are its sources' reports for that closed week,
     * so the current week reads zero until it closes and reports land. A
     * next threshold of zero means the input sits on the top tier. The
     * tiers are the natural ones; `elevated` says whether the week is
     * priced as at the cap instead (the rates reported are the effective
     * ones), with the hub's latest window beside it. A week the latest
     * window holds is elevated; so is a week of an earlier window of the
     * referrer's history, read from its effective rate standing at the cap
     * while the natural ladder does not reach it (a week whose ladder
     * reaches the cap on its own is priced the same either way).
     */
    function ladderStandingOf(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (LadderStanding memory standing)
    {
        (
            standing.referredInput,
            standing.selfInput
        ) = HUB.ladderInputsAt(
            _referrer,
            _week
        );

        (
            standing.y1Bps,
            standing.y2Bps,
            standing.mBps
        ) = HUB.weeklyRates(
            _referrer,
            _week
        );

        ReferralHubDeclarations.RateTable memory table = _tableFor(
            _week
        );

        (
            standing.referredTierBps,
            standing.nextReferredThreshold
        ) = _tierOf(
            table,
            standing.referredInput
        );

        (
            standing.selfTierBps,
            standing.nextSelfThreshold
        ) = _tierOf(
            table,
            standing.selfInput
        );

        standing.elevatedFromWeek = HUB.elevatedFromWeek(
            _referrer
        );

        standing.elevatedUntilWeek = HUB.elevatedUntilWeek(
            _referrer
        );

        standing.elevated = (
            standing.elevatedFromWeek != 0
                && _week >= standing.elevatedFromWeek
                && (standing.elevatedUntilWeek == 0 || _week < standing.elevatedUntilWeek)
        ) || (
            standing.y1Bps == table.capBps
                && standing.referredTierBps + standing.selfTierBps < table.capBps
        );
    }

    function _tableFor(
        uint256 _week
    )
        internal
        view
        returns (ReferralHubDeclarations.RateTable memory table)
    {
        uint256 index = HUB.rateTableCount();

        while (index > 1) {
            --index;

            table = HUB.rateTableAt(
                index
            );

            if (table.effectiveFromWeek <= _week) {
                return table;
            }
        }

        return HUB.rateTableAt(
            0
        );
    }

    function _tierOf(
        ReferralHubDeclarations.RateTable memory _table,
        uint256 _value
    )
        internal
        pure
        returns (
            uint256 tierBps,
            uint256 nextThreshold
        )
    {
        for (uint256 i = 8; i > 0; --i) {

            if (_value >= _table.thresholds[i - 1]) {

                if (i < 8) {
                    nextThreshold = _table.thresholds[i];
                }

                return (
                    _table.tierBps[i - 1],
                    nextThreshold
                );
            }
        }

        nextThreshold = _table.thresholds[0];
    }
}
