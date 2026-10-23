// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {CohortRecorderBase} from "../../../src/diamond/vault/facets/pending/CohortRecorderBase.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../referral/registry/ReferralRegistry.sol";

/**
 * @dev Narrow-writer harness over {CohortRecorderBase}, following the
 * kontrol {InterestProofHarness} pattern (see
 * test/diamond/kontrol/InterestProofHarness.sol): deployed STANDALONE,
 * no diamond and no DELEGATECALL. Because {CohortPinnedBase} pins
 * every slot the engine touches at its diamond position (the slim
 * mirror checked by script/check_storage_layout.sh), this harness's
 * own storage IS the diamond layout for those slots, so the packed cohort book (slot 70), ring arrays
 * (slots 72-73), crumb words (slot 74) and gap log (slot 75) live at
 * the exact slots a facet would see under DELEGATECALL from the live
 * diamond. Every `exposed*` function forwards verbatim into the
 * inherited engine internal under test; nothing here alters engine
 * logic. Every `harnessSet*` writer touches exactly one declared
 * storage field, with two named exceptions: `harnessSetTracked` is the
 * one writer that mirrors the tracked amount into the attributed
 * amount, so a seeded referee starts fully attributed exactly as a
 * referred credit leaves it, and `harnessSetReferrer` writes no field
 * of this harness at all (it forwards an assignment into the wired
 * registry). The narrow writers let a fuzz or unit driver seed
 * near-saturation magnitudes the public deposit-cap API (1e9 * 1e6)
 * can never reach.
 * The per-account self crumb (slot 92) is reached the same way: the
 * settle-to exposers drive the book, referee and self settles to an
 * explicit target instant, `harnessSetSelfCrumb` seeds a raw word
 * and `viewSelfCrumb` reads it back undecoded.
 */
contract CohortLaneHarness is CohortRecorderBase {

    // ---- exposed engine internals (real code under test) ----

    function exposedCreditContribution(
        address _user,
        uint256 _amount
    )
        external
    {
        _creditContributionCohort(
            _user,
            _amount
        );
    }

    function exposedCreditRing(
        address _referrer,
        uint256 _amount
    )
        external
    {
        _creditRingCohort(
            _referrer,
            _amount
        );
    }

    function exposedWriteCrumb(
        address _referrer,
        uint256 _week,
        uint256 _y1Seconds,
        uint256 _y2Seconds,
        uint256 _mSeconds
    )
        external
    {
        _writeCrumbCohort(
            _referrer,
            _week,
            _y1Seconds,
            _y2Seconds,
            _mSeconds
        );
    }

    function exposedRotate(
        address _referrer,
        uint256 _boundaryWeek
    )
        external
    {
        _rotateCohort(
            _referrer,
            _boundaryWeek
        );
    }

    function exposedReduceBook(
        address _referrer,
        uint256 _delta
    )
        external
        returns (
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        return _reduceBookCohort(
            _referrer,
            _delta
        );
    }

    function exposedSettleBook(
        address _referrer
    )
        external
    {
        _settleBookCohort(
            _referrer
        );
    }

    function exposedSettleBookTo(
        address _referrer,
        uint256 _to
    )
        external
    {
        _settleBookCohortTo(
            _referrer,
            _to
        );
    }

    function exposedSyncReferee(
        address _user
    )
        external
    {
        _syncRefereeCohort(
            _user
        );
    }

    function exposedSyncRefereeAt(
        address _user,
        uint256 _to
    )
        external
    {
        _syncRefereeCohortAt(
            _user,
            _to
        );
    }

    function exposedSettleSelf(
        address _user,
        uint256 _to
    )
        external
    {
        _settleSelfCohort(
            _user,
            _to
        );
    }

    function exposedMigrateReferrer(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
    {
        _migrateReferrerCohort(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    // ---- narrow storage writers (harness scaffolding only) ----

    function harnessSetRingYear1(
        address _referrer,
        uint256 _slot,
        uint64 _value
    )
        external
    {
        cohortRingYear1[_referrer][_slot] = _value;
    }

    function harnessSetRingYear2(
        address _referrer,
        uint256 _slot,
        uint64 _value
    )
        external
    {
        cohortRingYear2[_referrer][_slot] = _value;
    }

    function harnessSetBookLanes(
        address _referrer,
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
    {
        cohortBook[_referrer] = CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        );
    }

    function harnessSetCrumb(
        address _referrer,
        uint256 _week,
        uint256 _word
    )
        external
    {
        cohortWeekLog[_referrer][_week] = _word;
    }

    function harnessSetLastSettle(
        address _referrer,
        uint256 _timestamp
    )
        external
    {
        cohortLastSettle[_referrer] = _timestamp;
    }

    function harnessSetTracked(
        address _user,
        uint256 _amount
    )
        external
    {
        trackedContribution[_user] = _amount;

        attributedContribution[_user] = _amount;
    }

    function harnessSetAttributed(
        address _user,
        uint256 _amount
    )
        external
    {
        attributedContribution[_user] = _amount;
    }

    function harnessSetSelfCrumb(
        address _user,
        uint256 _word
    )
        external
    {
        cohortSelfCrumb[_user] = _word;
    }

    function harnessSetRegistry(
        address _registry
    )
        external
    {
        referralRegistry = _registry;
    }

    /**
     * @dev The engine resolves referrers through the registry pointer
     * into a standalone {ReferralRegistry} wired via
     * {harnessSetRegistry}: embedding the registry creation code in
     * a lazy deploy here would push the harness past the EIP-170
     * runtime limit, so tests deploy and allowlist the registry
     * themselves. The forward runs with the harness as the
     * allowlisted writer, so the engine under test reads the
     * assignment through the exact guarded-staticcall path
     * production uses.
     */
    function harnessSetReferrer(
        address _user,
        address _referrer
    )
        external
    {
        ReferralRegistry(referralRegistry).assignReferrer(
            _user,
            _referrer
        );
    }

    function harnessMintBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            + _amount;
    }

    // ---- view helpers ----

    function viewRingYear1(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear1[_referrer][_slot];
    }

    function viewRingYear2(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear2[_referrer][_slot];
    }

    function viewBookWord(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortBook[_referrer];
    }

    function viewCrumb(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return cohortWeekLog[_referrer][_week];
    }

    function viewLastSettle(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortLastSettle[_referrer];
    }

    function viewTracked(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return trackedContribution[_user];
    }

    function viewAttributed(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return attributedContribution[_user];
    }

    function viewSelfCrumb(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return cohortSelfCrumb[_user];
    }
}
