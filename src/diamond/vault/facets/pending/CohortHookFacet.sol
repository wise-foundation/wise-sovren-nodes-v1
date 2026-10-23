// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortRecorderBase} from "./CohortRecorderBase.sol";

/**
 * @dev CohortHookFacet: the transfer hook slice of the cohort engine,
 * installed as `transferHookFacet` in place of GraceFreezeHookFacet. The
 * grace freeze check runs first and keeps its revert; everything after it
 * is the revert-free recorder, and with `cohortSyncEnabled` false the
 * facet behaves exactly like the grace freeze hook. The `applyCohort*`
 * entrypoints are the targets of the helper chain stubs under the
 * transient `hookExecuting` bracket, and each drains a parked sender
 * first. The two move entrypoints forward by selector to the routed
 * CohortMoveHookFacet; an unrouted move slice degrades a move to
 * attribution loss and never blocks it. `applyCohortSync(address(0))` is
 * the arming call and stamps the re-arm instant. `applyCohortSettle` (the
 * flush's pre-plan settle) settles a referrer's book only once the book
 * exists, so it never anchors an empty book for a referrer who only holds
 * a self stake, and only such a book can be parked at a disarm. It always
 * settles the self crumb to now, even while the book is parked at the
 * disarm, so the flush ends the zero presence a disarm span leaves until
 * the next settle; the settle logs every week the crumb rolls past. It
 * then syncs the referrer's tracked stake down to its balance, so a stake
 * that left during a disarm span is never logged again at its old size by
 * a later flush. Every entrypoint is
 * payable because a delegatecall from the bridge entrypoints inherits
 * `msg.value`; no ETH moves.
 */
contract CohortHookFacet is CohortRecorderBase {

    function applyTransferHook(
        address _from,
        address _to
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        if (graceFreezeEnabled == true) {
            _checkGracePeriod(
                _from
            );
        }

        if (cohortSyncEnabled == false) {
            return;
        }

        address drained = _drainPendingDivestCohort();

        if (drained != _from) {
            _syncRefereeCohort(
                _from
            );
        }

        if (drained != _to) {
            _syncRefereeCohort(
                _to
            );
        }

        _parkDivestCohort(
            _from
        );
    }

    function applyCohortSync(
        address _user
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        if (_user == ZERO_ADDRESS) {
            _stampRearmCohort();
        }

        _syncAfterDrainCohort(
            _user
        );
    }

    function applyCohortCredit(
        address _user,
        uint256 _amount
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        _drainPendingDivestCohort();

        _creditContributionCohort(
            _user,
            _amount
        );
    }

    function applyCohortAdvance(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        _drainPendingDivestCohort();

        _advanceBookCohort(
            _referrer,
            _maxBoundaries
        );
    }

    function applyCohortSettle(
        address _referrer
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        _drainPendingDivestCohort();

        uint256 disarmedAt = cohortDisarmedAt;

        uint256 rearmedAt = cohortRearmedAt;

        uint256 last = cohortLastSettle[_referrer];

        uint256 target = block.timestamp;

        if (last != 0) {

            if (
                _parkedAtDisarmCohort(
                    last,
                    disarmedAt,
                    rearmedAt
                )
            ) {
                target = disarmedAt;
            }

            _settleBookCohortTo(
                _referrer,
                target
            );
        }

        _settleSelfCohort(
            _referrer,
            block.timestamp
        );

        _syncRefereeCohortAt(
            _referrer,
            target
        );
    }

    function applyCohortMoveOut(
        address _user,
        address _dstVault,
        uint256,
        uint256,
        uint256
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        if (_forwardCohortMoveHook() == true) {
            return;
        }

        _syncAfterDrainCohort(
            _user
        );

        emit CohortCarrySkipped(
            _user,
            _dstVault
        );
    }

    function applyCohortMoveIn(
        address _user,
        address _srcVault
    )
        external
        payable
        onlyDelegateCall
        onlyHookExecution
    {
        if (_forwardCohortMoveHook() == true) {
            return;
        }

        _drainPendingDivestCohort();

        emit CohortCarryDiscarded(
            _user,
            _srcVault,
            0
        );
    }

    function _forwardCohortMoveHook()
        internal
        returns (bool)
    {
        address facet = selectorToFacet[msg.sig];

        if (facet == ZERO_ADDRESS) {
            return false;
        }

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            msg.data
        );

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return true;
    }

    function _stampRearmCohort()
        internal
    {
        uint256 disarmedAt = cohortDisarmedAt;

        if (disarmedAt == 0 || cohortRearmedAt != 0) {
            return;
        }

        cohortRearmedAt = uint64(block.timestamp);

        uint256 graceEnd = cohortRearmedAt
            + FLUSH_OUTAGE_GRACE
            + cohortRearmedAt
            - disarmedAt;

        if (graceEnd > referralDisarmGraceEnd) {
            referralDisarmGraceEnd = uint64(
                graceEnd
            );
        }

        emit CohortDisarmSpanSet(
            disarmedAt,
            block.timestamp
        );
    }
}
