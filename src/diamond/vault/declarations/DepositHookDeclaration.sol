// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Swappable deposit-hook shard. `depositHookFacet` is an
 * optional facet `_registerLargeDeposit` DELEGATECALLs with the
 * decorated call's positive share-balance delta as the large-deposit
 * detection policy. When it is `ZERO_ADDRESS` the inline single-call
 * threshold check runs unchanged, so an already-deployed diamond
 * that upgrades the interest helper without installing the facet
 * behaves exactly as before. `proposedDepositHookFacet` +
 * `depositHookChangeQueuedAt` back the propose/execute flow: instant
 * while the diamond is still in setup (before `finalizeSetup`, like
 * the transfer hook) so the deploy can install the initial hook at
 * genesis, then 3-day timelocked afterwards so a compromised master
 * cannot instantly repoint the stamping path; proposing
 * `ZERO_ADDRESS` reverts back to the inline default. The deposit hook
 * writes accumulator state, so it guards on the transient
 * `hookExecuting` flag (`HookGuardDeclaration`) that only
 * `_runDepositHook` sets: routing `DEPOSIT_HOOK_SELECTOR` into the
 * diamond is therefore harmless — an external caller cannot satisfy
 * the flag and can never stamp arbitrary users. Appended as a tail
 * shard: `depositHookFacet` packs into the
 * free bytes of the `graceFreezeEnabled` slot and the remaining
 * fields take fresh slots, so no pre-existing slot moves.
 */
abstract contract DepositHookDeclaration {

    address public depositHookFacet;

    address public proposedDepositHookFacet;

    uint256 public depositHookChangeQueuedAt;

    uint256 internal constant DEPOSIT_HOOK_CHANGE_DELAY = 3 days;

    bytes4 internal constant DEPOSIT_HOOK_SELECTOR = bytes4(
        keccak256(
            "applyDepositAccumHook(address,uint256)"
        )
    );
}
