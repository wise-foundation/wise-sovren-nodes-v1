// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {CohortRecorderBase} from "../../../src/diamond/vault/facets/pending/CohortRecorderBase.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Sibling of {CohortLaneHarness}, dedicated to the same-chain
 * move-carry engine internals: the captured reduction walk and the
 * capture→stage→apply seam. A SEPARATE harness because the combined
 * exposure surface plus {CohortLaneHarness}'s embedded lazy
 * {ReferralRegistry} creation code pushed one contract past the
 * EIP-170 runtime limit; this one therefore takes its registry as an
 * address through `harnessSetRegistry` (tests deploy and allowlist
 * the shared registry themselves, matching the per-chain production
 * topology) and embeds no creation code. Same standalone-deployment
 * rules as the sibling: no diamond, no DELEGATECALL, storage layout
 * identical to the diamond's via {CohortPinnedBase}, every
 * `exposed*` forwarding verbatim into the inherited engine internal
 * and every `harnessSet*` writer touching exactly one declared field
 * except `harnessSetTracked`, the one writer that mirrors the tracked
 * amount into the attributed amount, so a seeded referee starts fully
 * attributed exactly as a referred credit leaves it; a test that needs
 * another attributed amount calls `harnessSetAttributed` afterwards.
 */
contract CohortCarryHarness is CohortRecorderBase {

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

    function exposedReduceBookCaptured(
        address _referrer,
        uint256 _delta
    )
        external
        returns (
            uint256[] memory pairs,
            uint256 pairCount,
            uint256 fromYear1,
            uint256 fromYear2,
            uint256 fromMature
        )
    {
        return _reduceBookCohortCaptured(
            _referrer,
            _delta
        );
    }

    function exposedCaptureMoveOut(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
    {
        _captureMoveOutCohort(
            _user,
            _dstVault,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function exposedApplyMoveIn(
        address _user,
        address _srcVault
    )
        external
    {
        _applyMoveInCohort(
            _user,
            _srcVault
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

    function harnessSetRegistry(
        address _registry
    )
        external
    {
        referralRegistry = _registry;
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

    function harnessMintBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            + _amount;
    }

    function harnessBurnBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            - _amount;
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
}
