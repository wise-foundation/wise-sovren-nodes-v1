// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Worker-role shard. `workerAddress` receives the overhang
 * sweep. `bufferInterestRate` is a ratchet-up shadow of
 * `interestRate` used only for `_calculateNeededBuffer`: master can
 * lower the user-facing rate but the buffer requirement only grows,
 * never shrinks. `proposedWorkerAddress` + `workerChangeQueuedAt`
 * back a 3-day propose/execute flow for rotating the worker (same
 * shape as the selector-routing timelock) so a compromised master
 * can't instantly redirect the sweep recipient.
 */
abstract contract WorkerDeclaration {

    address public workerAddress;

    uint256 public bufferInterestRate;

    address public proposedWorkerAddress;

    uint256 public workerChangeQueuedAt;

    uint256 internal constant SECONDS_IN_TWO_WEEKS = 14 days;

    uint256 internal constant WORKER_CHANGE_DELAY = 3 days;
}
