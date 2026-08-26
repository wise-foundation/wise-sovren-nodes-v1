// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Transient re-entrancy-style flag marking that execution is
 * currently inside an internal hook DELEGATECALL (`_runDepositHook`
 * or `_runTransferHook`). Both hook facets require it, so a hook can
 * only ever run as part of the decorated internal path and never as a
 * standalone external call — even if its selector is deliberately
 * routed into the diamond. Held in transient storage, so it costs no
 * persistent slot and self-clears at the end of every transaction.
 */
abstract contract HookGuardDeclaration {

    bool internal transient hookExecuting;
}
