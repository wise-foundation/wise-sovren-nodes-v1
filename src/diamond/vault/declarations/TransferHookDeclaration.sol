// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Swappable transfer-hook shard. `transferHookFacet` is an
 * optional facet the ERC20 `transfer`/`transferFrom` (and the queue
 * internal move) DELEGATECALL as a transfer-time policy hook. When it
 * is `ZERO_ADDRESS` — the shipped default — the inline hook is a
 * no-op, so a bare transfer moves tokens only and interest is
 * reassigned exclusively through the explicit `moveMyInterestTo`; the
 * swap capability is latent and off unless a master opts in.
 * `proposedTransferHookFacet` + `transferHookChangeQueuedAt`
 * back the propose/execute flow: instant while the diamond is still in
 * setup (before `finalizeSetup`, like the selector routing and
 * cross-chain peers) so the deploy can install the initial hook at
 * genesis, then 3-day timelocked afterwards (same shape as the
 * third-party rotation) so a compromised master cannot instantly
 * repoint the most sensitive path; proposing `ZERO_ADDRESS` reverts
 * back to the inline default. Appended last as a tail shard so it takes
 * fresh slots and moves no pre-existing slot.
 */
abstract contract TransferHookDeclaration {

    address public transferHookFacet;

    address public proposedTransferHookFacet;

    uint256 public transferHookChangeQueuedAt;

    uint256 internal constant TRANSFER_HOOK_CHANGE_DELAY = 3 days;

    bytes4 internal constant TRANSFER_HOOK_SELECTOR = bytes4(
        keccak256(
            "applyTransferHook(address,address)"
        )
    );
}
