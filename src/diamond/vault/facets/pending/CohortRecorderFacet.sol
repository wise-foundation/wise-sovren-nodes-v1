// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortRecorderFacet: the routed public surface of the cohort
 * recorder. Its mutations carry no engine code; they reach an engine slice
 * through the helper chain stubs, so the routed path and the hook path
 * cannot diverge. `syncReferee` (the one-way clamp poke) and `advanceBook`
 * (a bounded pre-walk of a dormant book) are permissionless no-ops while
 * the recorder is disarmed. `receiveReferrerFlip` is callable by the
 * registry only; while disarmed it returns when the user holds no
 * attributed contribution here and otherwise reverts, so the registry
 * defers the flip. `seedCohortContribution` is the master-only retroactive
 * credit of untracked balance, bounded by min(amount, held minus tracked),
 * and dies with the registry's one-way seed latch.
 */
contract CohortRecorderFacet is FacetBase {

    function syncReferee(
        address _user
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _cohortSync(
            _user
        );
    }

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        require(
            msg.sender == referralRegistry,
            NotReferralRegistry()
        );

        if (cohortSyncEnabled == false && attributedContribution[_user] == 0) {
            return;
        }

        require(
            cohortSyncEnabled,
            CohortSyncDisabled()
        );

        _cohortFlip(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    function advanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _cohortAdvance(
            _referrer,
            _maxBoundaries
        );
    }

    function seedCohortContribution(
        address _user,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
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
            IReferralRegistry(referralRegistry).seedsLatched() == false,
            SeedingLatched()
        );

        _cohortSync(
            _user
        );

        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        require(
            held > tracked,
            NothingToSeed()
        );

        uint256 delta = held - tracked;

        if (_amount < delta) {
            delta = _amount;
        }

        require(
            delta > 0,
            NothingToSeed()
        );

        _cohortCredit(
            _user,
            delta
        );

        emit CohortContributionSeeded(
            _user,
            delta
        );
    }

    function getCohortSyncEnabled()
        external
        view
        returns (bool)
    {
        return cohortSyncEnabled;
    }

    function getTrackedContribution(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return trackedContribution[_user];
    }

    function getAttributedContribution(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return attributedContribution[_user];
    }

    function getCohortSelfCrumb(
        address _user
    )
        external
        view
        returns (
            uint256 settledAt,
            uint256 currentWeekSeconds,
            uint256 previousWeekSeconds
        )
    {
        uint256 word = cohortSelfCrumb[_user];

        return (
            CohortWeeks._selfCrumbSettledAt(
                word
            ),
            CohortWeeks._selfCrumbCurrent(
                word
            ),
            CohortWeeks._selfCrumbPrevious(
                word
            )
        );
    }

    function getCohortBook(
        address _referrer
    )
        external
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettleTimestamp
        )
    {
        uint256 book = cohortBook[_referrer];

        return (
            CohortWeeks._laneY1(
                book
            ),
            CohortWeeks._laneY2(
                book
            ),
            CohortWeeks._laneM(
                book
            ),
            cohortLastSettle[_referrer]
        );
    }

    function getCohortScore(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        uint256 book = cohortBook[_referrer];

        return CohortWeeks._laneY1(
            book
        )
            + CohortWeeks._laneY2(
                book
            )
            + CohortWeeks._laneM(
                book
            );
    }

    function getCohortRings(
        address _referrer
    )
        external
        view
        returns (
            uint64[52] memory year1,
            uint64[52] memory year2
        )
    {
        return (
            cohortRingYear1[_referrer],
            cohortRingYear2[_referrer]
        );
    }

    function getCohortWeekCrumb(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return cohortWeekLog[_referrer][_week];
    }

    function getCohortWeekCrumbs(
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (uint256[] memory crumbs)
    {
        crumbs = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {
            crumbs[i] = cohortWeekLog[_referrer][_fromWeek + i];
        }
    }

    function getCohortGapLogLength(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer].length;
    }

    function getCohortGapLogEntry(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer][_index];
    }
}
