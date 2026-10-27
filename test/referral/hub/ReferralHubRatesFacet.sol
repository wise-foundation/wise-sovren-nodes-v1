// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubRates} from "./ReferralHubRates.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubRatesFacet: the rate reads and the master levers
 * `pushRateTable` (append only and future only), `setDelivererShareCap`
 * (zero means no cap) and the elevation whitelist: `elevateReferrer`
 * prices a referrer as at the cap from a future week on, open ended, and
 * is a grant (it runs only as the exact call master queued through
 * `proposeLeverChange` at least the lever delay earlier); `endElevation`
 * closes the window at a future week at once. Both act on future weeks
 * only, so a closed week keeps its verdict and a week already paid at the
 * elevated rate is never clawed back. A new grant after an end appends a
 * window to the referrer's history instead of replacing the ended one, so
 * every window keeps its verdict for good: a week of an ended window is
 * priced as at the cap whenever it is settled, before or after the
 * re-grant. The history holds at most MAX_ELEVATION_WINDOWS windows and a
 * further grant reverts `ElevationHistoryFull`; the mirrored
 * `elevatedFromWeek` and `elevatedUntilWeek` report the latest window.
 * The inputs are recorded regardless, so the natural rate stays
 * derivable.
 */
contract ReferralHubRatesFacet is
    ReferralHubRates,
    ReferralHubFacetBase
{

    function pushRateTable(
        RateTable calldata _table
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        _pushRateTable(
            _table
        );
    }

    function setDelivererShareCap(
        uint256 _cap
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        if (delivererShareCap == _cap) {
            return;
        }

        delivererShareCap = _cap;

        emit DelivererShareCapSet(
            _cap
        );
    }

    function elevateReferrer(
        address _referrer,
        uint256 _fromWeek
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        _consumeLeverChange(
            keccak256(
                abi.encodeCall(
                    this.elevateReferrer,
                    (
                        _referrer,
                        _fromWeek
                    )
                )
            )
        );

        _requireWithinHorizon(
            _fromWeek
        );

        require(
            _fromWeek > block.timestamp / CohortWeeks.WEEK,
            ElevationNotFuture()
        );

        require(
            elevatedFromWeek[_referrer] == 0
                || elevatedUntilWeek[_referrer] != 0,
            AlreadyElevated()
        );

        require(
            elevationWindowsOf[_referrer].length < MAX_ELEVATION_WINDOWS,
            ElevationHistoryFull()
        );

        elevationWindowsOf[_referrer].push(
            _fromWeek
        );

        elevatedFromWeek[_referrer] = _fromWeek;

        elevatedUntilWeek[_referrer] = 0;

        emit ReferrerElevated(
            _referrer,
            _fromWeek
        );
    }

    function endElevation(
        address _referrer,
        uint256 _untilWeek
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        uint256 fromWeek = elevatedFromWeek[_referrer];

        require(
            fromWeek != 0
                && elevatedUntilWeek[_referrer] == 0,
            NotElevated()
        );

        _requireWithinHorizon(
            _untilWeek
        );

        require(
            _untilWeek > block.timestamp / CohortWeeks.WEEK
                && _untilWeek >= fromWeek,
            ElevationNotFuture()
        );

        uint256[] storage windows = elevationWindowsOf[_referrer];

        windows[windows.length - 1] = fromWeek
            | (_untilWeek << WEEK_HALF_SHIFT);

        elevatedUntilWeek[_referrer] = _untilWeek;

        emit ReferrerElevationEnded(
            _referrer,
            _untilWeek
        );
    }
}
