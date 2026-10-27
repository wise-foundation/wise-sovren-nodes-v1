// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubCheckpoints: the week buckets the ladder reads. Week W is
 * priced only from W's own bucket, the realised averages its sources
 * reported for W: no sample of another week, no carried score and no
 * freshness window. A bucket only rises (every source report is final for
 * its closed week and merged by maximum), so W's rates never fall and,
 * after a later report, `settleWeeks` tops up what W already paid.
 */
abstract contract ReferralHubCheckpoints is ReferralHubDeclarations {

    function ladderInputsAt(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredInput,
            uint256 selfInput
        )
    {
        return _ladderInputsAt(
            _referrer,
            _week
        );
    }

    function weekReportOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredAverage,
            uint256 paidUnits
        )
    {
        uint256 word = sourceWeekOf[_source][_referrer][_week];

        return (
            word & WEEK_HALF_MASK,
            word >> WEEK_HALF_SHIFT
        );
    }

    function weekSelfOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return sourceSelfOf[_source][_referrer][_week];
    }

    function _ladderInputsAt(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 referredInput,
            uint256 selfInput
        )
    {
        uint256 word = weekInputsOf[_referrer][_week];

        return (
            word & WEEK_HALF_MASK,
            word >> WEEK_HALF_SHIFT
        );
    }

    function _requireWithinHorizon(
        uint256 _week
    )
        internal
        view
    {
        require(
            _week <= block.timestamp / CohortWeeks.WEEK + MAX_SCHEDULE_HORIZON_WEEKS,
            WeekOutOfRange()
        );
    }

    function _lastAtOrBefore(
        uint256 _length,
        uint256 _week,
        function(uint256) internal view returns (uint256) _weekAt
    )
        internal
        view
        returns (uint256 low)
    {
        uint256 high = _length - 1;

        while (low < high) {

            uint256 mid = (low + high + 1) / 2;

            if (_weekAt(mid) <= _week) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
    }
}
