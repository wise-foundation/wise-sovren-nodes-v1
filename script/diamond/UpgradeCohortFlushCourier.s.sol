// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";

import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "./WiseSovrenNodesDiamondSelectors.sol";

/// @notice Replaces the routed {CohortFlushFacet} of an already running vault with a new
/// deployment behind the same four selectors (the two payable flush entrypoints, the fee
/// quote and the envelope preview) through the diamond's existing 3-day selector timelock.
/// The new build changes one rule: a batch sent by an allowed flush bot opens a book whose
/// send cursors are still unset, exactly as the referrer's own batch would, so a referrer
/// no longer has to flush once itself before the couriers may carry its book. No storage
/// change, no selector change, no hook change; the LIVE diamond entry contracts are never
/// redeployed and nothing already deployed is modified.
///
/// ONE 3-day clock for the one Sovren vault:
///   `propose()` : deploys the facet and proposes the cohortFlush selector batch to it.
///                 Refuses while the flush round has not executed on the vault, refuses a
///                 key that is not the vault master, and refuses to overwrite a pending
///                 proposal of the batch unless `UPGRADE_FORCE_REPROPOSE=true` is set on
///                 purpose (a second propose restarts the clock).
///   `execute()` : after 3 days: flips the batch to the proposed facet and post-asserts
///                 that every selector of the group routes to that one facet with nothing
///                 queued. Idempotent (queuedAt-guarded), re-runnable after partial mining.
///   `abort()`   : cancels the pending batch (pre-execute only); the live facet stays.
///   `status()`  : read-only sanity print for the runbook (no broadcast).
///
/// Invocation for the one Sovren vault (product via VAULT_PRODUCT, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlushCourier.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlushCourier.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///
/// Broadcast only after the fork rehearsal against the live mainnet state
/// (`test/diamond/fork/WiseSovrenNodesCourierOpenFork.t.sol`), which drives this very script.
contract UpgradeCohortFlushCourier is VaultConfig {

    function propose()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        _requireKeyIsMaster(
            diamond,
            privKey
        );

        _requireFlushRoundExecuted(
            diamond
        );

        vm.startBroadcast(
            privKey
        );

        address cohortFlushFacet = address(new CohortFlushFacet());

        WiseSovrenNodesDiamond(payable(diamond)).proposeSelectors(
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors(),
            cohortFlushFacet
        );

        vm.stopBroadcast();

        console2.log(
            "proposed courier flush facet on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  CohortFlushFacet",
            cohortFlushFacet
        );

        console2.log(
            "earliest execute()",
            block.timestamp + 3 days
        );
    }

    function execute()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        address proposed = d.proposedSelectorFacet(
            sels[0]
        );

        vm.startBroadcast(
            privKey
        );

        if (d.selectorChangeQueuedAt(sels[0]) > 0) {
            d.executeSelectorChanges(
                sels
            );
        } else {
            console2.log(
                "cohortFlush batch not queued on diamond, nothing to execute",
                diamond
            );
        }

        vm.stopBroadcast();

        _assertGroupRouted(
            d,
            sels,
            proposed
        );

        console2.log(
            "courier flush facet routed on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  CohortFlushFacet",
            d.selectorToFacet(
                sels[0]
            )
        );
    }

    function abort()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        vm.startBroadcast(
            privKey
        );

        for (uint256 i; i < sels.length; ++i) {

            if (d.selectorChangeQueuedAt(sels[i]) > 0) {
                d.cancelSelectorProposal(
                    sels[i]
                );
            }
        }

        vm.stopBroadcast();

        console2.log(
            "aborted pending courier flush facet proposal on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );
    }

    function status()
        external
        view
    {
        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        console2.log(
            "diamond",
            diamond
        );

        console2.log(
            "master",
            d.master()
        );

        console2.log(
            "cohortFlush group facet",
            d.selectorToFacet(
                sels[0]
            )
        );

        console2.log(
            "cohortFlush proposed facet",
            d.proposedSelectorFacet(
                sels[0]
            )
        );

        console2.log(
            "cohortFlush batch queuedAt",
            d.selectorChangeQueuedAt(
                sels[0]
            )
        );
    }

    function _requireKeyIsMaster(
        address _diamond,
        uint256 _privKey
    )
        internal
        view
    {
        require(
            vm.addr(_privKey) == WiseSovrenNodesDiamond(payable(_diamond)).master(),
            "UpgradeCohortFlushCourier: PRIVATE_KEY is not the master of this vault"
        );
    }

    /// @dev The round re-proposes a routed group, so it may start only after the flush round
    /// executed on this vault, and never over a pending proposal of the group (a second
    /// propose overwrites it and restarts its clock) unless `UPGRADE_FORCE_REPROPOSE=true`
    /// is set on purpose.
    function _requireFlushRoundExecuted(
        address _diamond
    )
        internal
        view
    {
        WiseSovrenNodesDiamond dispatcher = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        require(
            dispatcher.selectorToFacet(sels[0]) != address(0),
            "UpgradeCohortFlushCourier: the flush round has not executed on this vault (run UpgradeCohortFlush.execute() first)"
        );

        if (vm.envOr("UPGRADE_FORCE_REPROPOSE", false)) {
            return;
        }

        require(
            dispatcher.selectorChangeQueuedAt(sels[0]) == 0,
            "UpgradeCohortFlushCourier: a cohortFlush proposal is already pending on this vault (a second propose would overwrite it and restart its clock; abort() first, or set UPGRADE_FORCE_REPROPOSE=true)"
        );
    }

    function _assertGroupRouted(
        WiseSovrenNodesDiamond _dispatcher,
        bytes4[] memory _sels,
        address _proposed
    )
        internal
        view
    {
        address routed = _dispatcher.selectorToFacet(
            _sels[0]
        );

        require(
            routed != address(0)
                && routed.code.length > 0,
            "UpgradeCohortFlushCourier: the cohortFlush group routes to no code after execute()"
        );

        require(
            _proposed == address(0)
                || routed == _proposed,
            "UpgradeCohortFlushCourier: the cohortFlush group does not route to the proposed facet after execute()"
        );

        for (uint256 i; i < _sels.length; ++i) {
            require(
                _dispatcher.selectorToFacet(_sels[i]) == routed,
                "UpgradeCohortFlushCourier: a cohortFlush selector routes to another facet after execute() (its proposal was missing or cancelled)"
            );

            require(
                _dispatcher.selectorChangeQueuedAt(_sels[i]) == 0,
                "UpgradeCohortFlushCourier: a cohortFlush selector is still queued after execute()"
            );
        }
    }
}
