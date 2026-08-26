// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Swappable transfer-hook policy that freezes a grace-locked
 * position. Any share movement OUT of an address still inside its
 * large-deposit grace window — `lastLargeDepositAt[from]` set and
 * `gracePeriodDuration` not yet elapsed — reverts
 * `GracePeriodNotElapsed` via the shared `_checkGracePeriod` guard.
 *
 * Installed as the `transferHookFacet`, it runs on `transfer`,
 * `transferFrom` and the queue internal move `_moveVaultTokens`, so a
 * freshly-boosted holder can neither hand the shares to a fresh
 * address nor escrow them via `joinQue` for a confederate wallet to
 * fulfil — closing the same-chain seasoning bypass left open once
 * `moveBetweenVaults` / `bridgeToVault` are source-gated by
 * `gracePeriodCheck`.
 *
 * Payouts out of the vault's own escrow (`from == address(this)`, e.g.
 * queue leave / fulfil) pass because the vault address is never
 * stamped, and `_burn`-based exits carry no hook — so principal exit
 * to USD stays open. Holds no state; reads only
 * tail-shard storage through DELEGATECALL. Entered only via
 * `_runTransferHook`'s internal delegatecall; `onlyDelegateCall`
 * rejects a direct facet call.
 *
 * The freeze is a master switch: it enforces only while
 * `graceFreezeEnabled` is `true`. The bool defaults to `false`, so a
 * diamond that has the hook installed still transfers freely until
 * master flips it on (instant, no timelock, `setGraceFreezeEnabled`),
 * and master can flip it back off at any time.
 */
contract GraceFreezeHookFacet is FacetBase {

    function applyTransferHook(
        address _from,
        address
    )
        external
        view
        onlyDelegateCall
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        if (graceFreezeEnabled == false) {
            return;
        }

        _checkGracePeriod(
            _from
        );
    }
}
