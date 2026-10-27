// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortFlushPolicyFacet: the master levers of the flush transport
 * (flush bot allowlist, public flush switch, CCIP gas limit of the flush
 * message, each emitting only on an actual change) and the read views the
 * couriers plan with.
 */
contract CohortFlushPolicyFacet is FacetBase {

    function setAllowedFlushBot(
        address _bot,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _bot != ZERO_ADDRESS,
            InvalidValue()
        );

        if (allowedFlushBot[_bot] == _allowed) {
            return;
        }

        allowedFlushBot[_bot] = _allowed;

        emit FlushBotAllowedSet(
            _bot,
            _allowed
        );
    }

    function setPublicFlushEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        if (publicFlushEnabled == _enabled) {
            return;
        }

        publicFlushEnabled = _enabled;

        emit PublicFlushEnabledSet(
            _enabled
        );
    }

    function setFlushGasLimit(
        uint64 _gasLimit
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _gasLimit >= FLUSH_GAS_LIMIT
                && _gasLimit <= MAX_FLUSH_GAS_LIMIT,
            InvalidFlushGasLimit()
        );

        if (flushGasLimit == _gasLimit) {
            return;
        }

        flushGasLimit = _gasLimit;

        emit FlushGasLimitSet(
            _gasLimit
        );
    }

    function getFlushedThroughWeek(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return flushedThroughWeek[_referrer];
    }

    function getFlushGapCursor(
        address _referrer
    )
        external
        view
        returns (
            uint256 gapIndex,
            uint256 gapResumeWeek
        )
    {
        uint256 cursor = flushGapCursor[_referrer];

        return (
            cursor & CohortWeeks.CARRY_HALF_MASK,
            cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT
        );
    }

    function getFlushCursors(
        address[] calldata _referrers
    )
        external
        view
        returns (
            uint256[] memory throughWeeks,
            uint256[] memory gapIndexes,
            uint256[] memory gapResumeWeeks
        )
    {
        uint256 count = _referrers.length;

        throughWeeks = new uint256[](
            count
        );

        gapIndexes = new uint256[](
            count
        );

        gapResumeWeeks = new uint256[](
            count
        );

        for (uint256 i; i < count; ++i) {

            uint256 cursor = flushGapCursor[_referrers[i]];

            throughWeeks[i] = flushedThroughWeek[_referrers[i]];

            gapIndexes[i] = cursor & CohortWeeks.CARRY_HALF_MASK;

            gapResumeWeeks[i] = cursor >> FLUSH_GAP_CURSOR_WEEK_SHIFT;
        }
    }

    function getAllowedFlushBot(
        address _bot
    )
        external
        view
        returns (bool)
    {
        return allowedFlushBot[_bot];
    }

    function getPublicFlushEnabled()
        external
        view
        returns (bool)
    {
        return publicFlushEnabled;
    }

    function getFlushGasLimit()
        external
        view
        returns (uint64)
    {
        return flushGasLimit;
    }
}
