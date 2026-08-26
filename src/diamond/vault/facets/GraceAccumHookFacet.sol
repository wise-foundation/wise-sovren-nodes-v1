// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Swappable deposit-hook policy that accumulates share-balance
 * increases per user across two adjacent fixed-length buckets so
 * split deposits can no longer dodge the large-deposit grace stamp —
 * not even by straddling a bucket boundary. Installed as the
 * `depositHookFacet`, it is DELEGATECALLed by `_registerLargeDeposit`
 * with the decorated call's positive balance delta after the inline
 * `graceThresholdAmount == 0` and non-positive-delta guards have
 * already returned.
 *
 * The accumulator is a master switch: while `depositAccumWindow` is
 * `0` — the shipped default — the hook reproduces the inline
 * single-call semantics exactly (a delta at or above the threshold
 * stamps, anything smaller is ignored, window records untouched), so
 * a genesis diamond with the facet installed behaves like one
 * without it until master arms the window (instant, no timelock,
 * `setDepositAccumWindow`).
 *
 * Armed, each user has consecutive buckets of `depositAccumWindow`
 * seconds anchored at `depositWindowStart`; deltas sum in
 * `depositWindowTotal`, and when a delta lands one bucket further
 * the total rolls into `depositWindowPrevTotal` and the anchor
 * advances exactly one window. After the adjustment the timestamp
 * always sits inside the current bucket, so a single advance per
 * call suffices; a delta arriving two or more windows past the
 * anchor is provably more than one window after the last recorded
 * delta, so both totals reset and the window restarts at
 * `block.timestamp` — stale records from an earlier armed epoch are
 * harmless. Every delta is tested against `graceThresholdAmount` as
 * previous plus current bucket, so deposits within one window of
 * each other always sum (boundary-straddling cannot split them)
 * while co-counting never reaches back two full windows; shrinking
 * an armed window below half its current value in one step opens a
 * one-shot straddle around the admin call, so ops shrink in at most
 * halving steps. The moment the combined total reaches the
 * threshold the user is stamped via the shared `_stampLargeDeposit`
 * (event carries the combined total) and all three window records
 * reset — clearing the previous bucket too, so nothing co-counts
 * into the next epoch and post-stamp dust cannot re-stamp while
 * another full cumulative threshold does. Sub-threshold writes emit
 * `DepositWindowAccumulated` with the combined total, which can
 * decrease between emissions when an advance drops an aged previous
 * bucket, and with the current bucket's end, before which the
 * previous bucket also still counts.
 *
 * Holds no state of its own; reads and writes only tail-shard
 * storage through DELEGATECALL. Entered only via `_runDepositHook`'s
 * internal delegatecall with `DEPOSIT_HOOK_SELECTOR`: `onlyDelegateCall`
 * rejects a direct facet call, and the transient `hookExecuting`
 * guard (set only by `_runDepositHook`) rejects a top-level call even
 * if the selector is ever routed into the diamond — so this
 * state-writing, caller-supplied-`_user` hook can never stamp an
 * arbitrary user from outside the decorated path. Deliberately not
 * `nonReentrant`: every decorated entrypoint already holds the
 * shared guard, so the modifier here would revert every armed call.
 */
contract GraceAccumHookFacet is FacetBase {

    function applyDepositAccumHook(
        address _user,
        uint256 _balanceIncrease
    )
        external
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        uint256 threshold = graceThresholdAmount;

        uint256 window = depositAccumWindow;

        if (window == 0) {
            if (_balanceIncrease < threshold) {
                return;
            }

            _stampLargeDeposit(
                _user,
                _balanceIncrease
            );

            return;
        }

        uint256 windowStart = depositWindowStart[_user];

        uint256 prevTotal = depositWindowPrevTotal[_user];

        uint256 windowTotal = depositWindowTotal[_user];

        if (windowStart == 0) {
            windowStart = block.timestamp;
        } else if (block.timestamp >= windowStart + window) {
            if (block.timestamp < windowStart + 2 * window) {
                prevTotal = windowTotal;
                windowStart = windowStart + window;
            } else {
                prevTotal = 0;
                windowStart = block.timestamp;
            }

            windowTotal = 0;
        }

        windowTotal = windowTotal
            + _balanceIncrease;

        uint256 countedTotal = prevTotal
            + windowTotal;

        if (countedTotal < threshold) {
            depositWindowStart[_user] = windowStart;
            depositWindowPrevTotal[_user] = prevTotal;
            depositWindowTotal[_user] = windowTotal;

            emit DepositWindowAccumulated(
                _user,
                countedTotal,
                windowStart + window
            );

            return;
        }

        depositWindowStart[_user] = 0;
        depositWindowPrevTotal[_user] = 0;
        depositWindowTotal[_user] = 0;

        _stampLargeDeposit(
            _user,
            countedTotal
        );
    }
}
