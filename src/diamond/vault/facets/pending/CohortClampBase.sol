// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortLaneBase} from "./CohortLaneBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortClampBase: the one-way clamp of a referee's tracked
 * contribution to the balance it holds. The referrer comes from the
 * registry seam, a guarded 32-byte staticcall; a failed lookup is distinct
 * from no referrer and the caller skips its whole mutation, and an unset
 * registry fails without a call. A clamp charges the book at most
 * min(deficit, attributed), so attributed never exceeds tracked. A sender
 * the hook cannot clamp is parked in one slot, never overwritten, and
 * synced at its park instant by the next entrypoint; under the CCIP router
 * only a park on the landing book itself is resolved. Every self settle
 * piece that crosses a week boundary appends a self log record, whatever
 * the book or flush state of the user, so a
 * closed week's self presence stays readable after the crumb rolls past
 * it. A crumb last settled before the re-arm of a closed disarm span
 * settles at its tracked stake up to the disarm and at zero from there to
 * this settle: a transfer in does not settle
 * the recipient, so its balance between the re-arm and this settle is
 * unknown and counts no presence.
 */
abstract contract CohortClampBase is CohortLaneBase {

    function _cohortReferrerOf(
        address _user
    )
        internal
        returns (
            bool,
            address
        )
    {
        address registry = referralRegistry;

        bool success;
        uint256 word;

        if (registry != ZERO_ADDRESS) {
            (
                success,
                word
            ) = _staticWordCohort(
                registry,
                IReferralRegistry.effectiveReferrerOf.selector,
                uint256(uint160(_user)),
                uint256(uint160(address(this))),
                0x44
            );
        }

        if (success == false || word > type(uint160).max) {

            emit CohortReferrerLookupFailed(
                _user
            );

            return (
                false,
                ZERO_ADDRESS
            );
        }

        return (
            true,
            address(uint160(word))
        );
    }

    function _staticWordCohort(
        address _target,
        bytes4 _selector,
        uint256 _argument0,
        uint256 _argument1,
        uint256 _length
    )
        internal
        view
        returns (
            bool success,
            uint256 word
        )
    {
        (
            bool ok,
            uint256 word0,
            ,
        ) = _staticWordsCohort(
            _target,
            _selector,
            _argument0,
            _argument1,
            _length,
            1
        );

        return (
            ok,
            word0
        );
    }

    function _syncRefereeCohort(
        address _user
    )
        internal
        returns (bool)
    {
        return _syncRefereeCohortAt(
            _user,
            block.timestamp
        );
    }

    function _syncRefereeCohortAt(
        address _user,
        uint256 _to
    )
        internal
        returns (bool)
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return true;
        }

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false) {
            return false;
        }

        _syncRefereeCohortAgainstAt(
            _user,
            referrer,
            _to
        );

        return true;
    }

    function _syncRefereeCohortAgainstAt(
        address _user,
        address _referrer,
        uint256 _to
    )
        internal
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        uint256 delta = tracked - held;

        if (_referrer != ZERO_ADDRESS) {
            _settleBookCohortTo(
                _referrer,
                _to
            );
        }

        _settleSelfCohort(
            _user,
            _to
        );

        trackedContribution[_user] = held;

        uint256 charge = _chargeAttributedCohort(
            _user,
            _referrer,
            delta
        );

        if (_referrer != ZERO_ADDRESS && charge > 0) {
            _reduceBookCohort(
                _referrer,
                charge
            );
        }

        emit CohortContributionSynced(
            _user,
            _referrer,
            tracked,
            held
        );
    }

    function _settleSelfCohort(
        address _user,
        uint256 _to
    )
        internal
    {
        uint256 word = cohortSelfCrumb[_user];

        uint256 tracked = trackedContribution[_user];

        uint256 settled = word;

        uint256 stake = tracked;

        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        if (
            rearmedAt > disarmedAt
                && disarmedAt < _to
                && CohortWeeks._selfCrumbSettledAt(word) < rearmedAt
        ) {

            settled = _settleSelfPieceCohort(
                _user,
                word,
                tracked,
                disarmedAt
            );

            stake = 0;
        }

        settled = _settleSelfPieceCohort(
            _user,
            settled,
            stake,
            _to
        );

        if (settled == word) {
            return;
        }

        cohortSelfCrumb[_user] = settled;

        emit CohortSelfCrumbSettled(
            _user,
            _to,
            CohortWeeks._selfCrumbCurrent(
                settled
            ),
            CohortWeeks._selfCrumbPrevious(
                settled
            )
        );
    }

    function _settleSelfPieceCohort(
        address _user,
        uint256 _word,
        uint256 _stake,
        uint256 _to
    )
        internal
        returns (uint256 settled)
    {
        settled = CohortWeeks._settleSelfCrumb(
            _word,
            _stake,
            _to
        );

        uint256 settledAt = CohortWeeks._selfCrumbSettledAt(
            _word
        );

        if (
            settledAt == 0
                || settledAt >= _to
                || settledAt / CohortWeeks.WEEK == _to / CohortWeeks.WEEK
        ) {
            return settled;
        }

        uint256 fromWeek = settledAt
            / CohortWeeks.WEEK;

        uint256 stake = CohortWeeks._clampLane80(
            _stake
        );

        uint256 completed = CohortWeeks._completedPreviousSeconds(
            CohortWeeks._selfCrumbCurrent(
                _word
            ),
            stake,
            settledAt,
            fromWeek + 1
        );

        cohortSelfLog[_user].push(
            CohortWeeks._packSelfLogRecord(
                fromWeek,
                completed,
                stake
            )
        );

        emit CohortSelfLogged(
            _user,
            fromWeek,
            completed,
            stake
        );
    }

    function _drainPendingDivestCohort()
        internal
        returns (address user)
    {
        user = pendingDivestSync;

        if (user == ZERO_ADDRESS) {
            return ZERO_ADDRESS;
        }

        if (msg.sender == ccipRouter) {
            return ZERO_ADDRESS;
        }

        _resolveParkedCohort(
            user
        );
    }

    function _resolveParkedCohort(
        address _user
    )
        internal
    {
        uint256 parkedAt = pendingDivestParkedAt;

        bool resolved = _syncRefereeCohortAt(
            _user,
            parkedAt
        );

        if (resolved == false) {
            return;
        }

        _clearParkCohort(
            _user
        );
    }

    function _clearParkCohort(
        address _user
    )
        internal
    {
        pendingDivestSync = ZERO_ADDRESS;

        pendingDivestParkedAt = 0;

        emit CohortDivestDrained(
            _user
        );
    }

    function _parkDivestCohort(
        address _user
    )
        internal
    {
        if (trackedContribution[_user] == 0) {
            return;
        }

        address parked = pendingDivestSync;

        if (parked == _user) {
            return;
        }

        if (parked != ZERO_ADDRESS) {

            emit CohortDivestParkSkipped(
                _user,
                parked
            );

            return;
        }

        pendingDivestSync = _user;

        pendingDivestParkedAt = uint64(block.timestamp);

        emit CohortDivestParked(
            _user
        );
    }

    function _syncAfterDrainCohort(
        address _user
    )
        internal
    {
        if (_user != ZERO_ADDRESS && pendingDivestSync == _user) {

            _resolveParkedCohort(
                _user
            );

            return;
        }

        address drained = _drainPendingDivestCohort();

        if (drained == _user) {
            return;
        }

        if (_syncRouterRecipientCohort(_user) == true) {
            return;
        }

        _syncRefereeCohort(
            _user
        );
    }

    function _syncRouterRecipientCohort(
        address _user
    )
        internal
        returns (bool)
    {
        if (
            msg.sender != ccipRouter
                || pendingDivestSync == ZERO_ADDRESS
                || balanceOf(_user) >= trackedContribution[_user]
        ) {
            return false;
        }

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false) {
            return true;
        }

        if (referrer != ZERO_ADDRESS) {
            _resolveLandingParkCohort(
                referrer
            );
        }

        _syncRefereeCohortAgainstAt(
            _user,
            referrer,
            block.timestamp
        );

        return true;
    }

    function _chargeAttributedCohort(
        address _user,
        address _referrer,
        uint256 _delta
    )
        internal
        returns (uint256 charge)
    {
        uint256 attributed = attributedContribution[_user];

        charge = attributed < _delta
            ? attributed
            : _delta;

        if (charge > 0) {

            attributedContribution[_user] = attributed - charge;

            emit CohortAttributionCharged(
                _user,
                _referrer,
                charge,
                _delta - charge
            );
        }
    }

    function _splitClampCohort(
        address _user,
        address _referrer,
        uint256 _delta,
        uint256 _burnedAmount
    )
        internal
        returns (ClampSplit memory split)
    {
        split.carryDelta = _delta < _burnedAmount
            ? _delta
            : _burnedAmount;

        uint256 charge = _chargeAttributedCohort(
            _user,
            _referrer,
            _delta
        );

        split.saleLike = charge < _delta - split.carryDelta
            ? charge
            : _delta - split.carryDelta;

        split.carryCharge = charge
            - split.saleLike;
    }

    function _clampForCarryCohort(
        address _user,
        address _referrer,
        uint256 _delta,
        uint256 _burnedAmount
    )
        internal
        returns (ClampSplit memory split)
    {
        split = _splitClampCohort(
            _user,
            _referrer,
            _delta,
            _burnedAmount
        );

        if (_referrer == ZERO_ADDRESS) {
            return split;
        }

        _settleBookCohort(
            _referrer
        );

        if (split.saleLike > 0) {
            _reduceBookCohort(
                _referrer,
                split.saleLike
            );
        }
    }

    function _creditContributionCohort(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            return;
        }

        (
            ,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (referrer != ZERO_ADDRESS) {

            _settleBookCohort(
                referrer
            );

            _creditRingCohort(
                referrer,
                _amount
            );

            attributedContribution[_user] += _amount;
        }

        _settleSelfCohort(
            _user,
            block.timestamp
        );

        trackedContribution[_user] += _amount;

        emit CohortContributionCredited(
            _user,
            referrer,
            _amount
        );
    }

    function _resolveLandingParkCohort(
        address _referrer
    )
        internal
    {
        address parked = pendingDivestSync;

        if (
            msg.sender != ccipRouter
                || parked == ZERO_ADDRESS
        ) {
            return;
        }

        (
            bool lookupOk,
            address parkedReferrer
        ) = _cohortReferrerOf(
            parked
        );

        if (lookupOk == false || parkedReferrer != _referrer) {
            return;
        }

        _resolveParkedCohort(
            parked
        );
    }
}
