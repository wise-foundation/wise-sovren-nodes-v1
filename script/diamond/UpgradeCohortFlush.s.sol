// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "./WiseSovrenNodesDiamondSelectors.sol";

/// @notice Installs the cohort-flush round on an already-running, finalized diamond: the
/// cohortFlush selector group (the two payable flush entrypoints, the fee quote, the three
/// master policy setters and the five routed views backing the slot-83 shard's `internal`
/// fields), the AdminFacet redeploy carrying the flush-hub pointer six, and the
/// settle-aware CohortHookFacet re-proposed as the transfer hook (its new
/// `applyCohortSettle` engine entrypoint is what lets a flush freshen a book to the second
/// through the slot-45 pointer; the flush facet compiles no engine code of its own). The
/// LIVE diamond entry contracts are never redeployed and never migrated: this round only
/// deploys NEW facet contracts and routes selectors and the hook through the diamond's
/// existing 3-day timelocks, plus one pointer write per vault.
///
/// This vault flushes its cohort book to the ONE mainnet hub shared with every vault of
/// the referral umbrella. The round assumes the registry round's groups are already routed
/// on the target vault (the flush facet reads the cohort state that round arms); running it
/// earlier is safe but pointless, since everything stays default-off. Prerequisite: the
/// hub, deployed from the shared referral repository, is recorded in
/// `config/hub.mainnet.json`; `propose()` fail-fasts if not.
///
/// TWO chained 3-day clocks per vault; the flush-hub pointer trio selectors are NEW (not
/// genesis-routed), so `proposeFlushHub` only exists on the diamond after the selector
/// round executes; the transfer-hook proposal runs inside clock 1 alongside the selector
/// batches, so the settle-aware engine is installed before any flush can arm:
///   `propose()`         : deploys the 4 facets, proposes the three selector batches and the
///                         hook. Clock 1 starts.
///   `execute()`         : after 3 days: flips both batches and the hook. Idempotent
///                         (queuedAt-guarded), re-runnable after partial mining.
///   `proposeFlushHub()` : same day as execute(): starts clock 2 through the
///                         freshly-routed {AdminFacet} trio. On the hub chain it proposes
///                         (hub, 0) for local direct-call delivery; on every other chain
///                         (hub, mainnet chain selector) for CCIP envelope delivery.
///   `executeFlushHub()` : after 3 more days: executes the pointer change and post-asserts
///                         pointer == config. The hub accepts this vault's reporter
///                         calls once the hub master has granted it as a reporter through
///                         the hub lever timelock (cast from the shared referral
///                         repository) and tagged its source with this vault system.
///   `abort()`           : cancels every pending batch, the hook proposal and the pointer
///                         proposal (each pre-execute only).
///   `status()`          : read-only sanity print for the operator (no broadcast).
///
/// Ordering law the steps encode: hub recorded → selectors + settle-aware hook live →
/// flush pointer wired → the hub side reporter grant LAST. Every intermediate state is
/// default-off: the flush entrypoints revert {FlushHubNotSet} while the pointer is unset,
/// and an envelope from a not-yet-registered source is rejected by the hub's
/// {UnknownFlushSource} gate. Rollback: pre-execute abort(); post-wire, proposing the
/// all-zero pointer detaches the hub after one more 3-day clock, and the hub-side source
/// registrations are instant master switches.
///
/// Invocation for the one Sovren vault (product via VAULT_PRODUCT, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlush.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlush.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlush.s.sol --sig "proposeFlushHub()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlush.s.sol --sig "executeFlushHub()" --rpc-url mainnet --broadcast
/// The reporter grant and the source tag are cast on the hub from the shared referral repository.
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the graduated files out of EVERY pending/
/// segment in the same commit: facets/pending/ (CohortFlushFacet, and CohortHookFacet if
/// this round ships it first), declarations/pending/ (CohortFlushDeclaration) and the
/// registry/hub pending trees their rounds cover.
contract UpgradeCohortFlush is VaultConfig {

    string internal constant HUB_NETWORK = "mainnet";

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

        require(
            _hubConfigExists(
                HUB_NETWORK
            ),
            "UpgradeCohortFlush: no hub config (config/hub.mainnet.json is written from the shared referral repository)"
        );

        _requireRegistryRoundExecuted(
            diamond
        );

        vm.startBroadcast(
            privKey
        );

        address adminFacet = address(new AdminFacet());
        address cohortFlushFacet = address(new CohortFlushFacet());
        address cohortFlushPolicyFacet = address(new CohortFlushPolicyFacet());
        address cohortHookFacet = address(new CohortHookFacet());

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._adminSelectors(),
            adminFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors(),
            cohortFlushFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors(),
            cohortFlushPolicyFacet
        );

        AdminFacet(diamond).proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.stopBroadcast();

        console2.log(
            "proposed cohort-flush upgrade on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  AdminFacet             ",
            adminFacet
        );

        console2.log(
            "  CohortFlushFacet       ",
            cohortFlushFacet
        );

        console2.log(
            "  CohortFlushPolicyFacet ",
            cohortFlushPolicyFacet
        );

        console2.log(
            "  CohortHookFacet        ",
            cohortHookFacet
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

        vm.startBroadcast(
            privKey
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._adminSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        if (WiseSovrenNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeTransferHookFacetChange();
        }

        vm.stopBroadcast();

        _assertGroupRouted(
            diamond,
            WiseSovrenNodesDiamondSelectors._adminSelectors()
        );

        _assertGroupRouted(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _assertGroupRouted(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        console2.log(
            "executed cohort-flush selector round on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "run proposeFlushHub() now (second 3-day clock)"
        );
    }

    function proposeFlushHub()
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

        address hub = _loadHub(
            HUB_NETWORK
        );

        if (_isHubChain()) {
            require(
                hub.code.length > 0,
                "UpgradeCohortFlush: recorded hub has no code on the hub chain"
            );
        }

        uint64 chainSelector = _flushHubChainSelector();

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        require(
            d.selectorToFacet(AdminFacet.proposeFlushHub.selector) != address(0),
            "UpgradeCohortFlush: pointer trio not routed yet (run execute() first)"
        );

        if (AdminFacet(diamond).getFlushHubChangeQueuedAt() > 0) {
            console2.log(
                "flush hub pointer proposal already pending on diamond",
                diamond
            );

            return;
        }

        vm.startBroadcast(
            privKey
        );

        AdminFacet(diamond).proposeFlushHub(
            hub,
            chainSelector
        );

        vm.stopBroadcast();

        console2.log(
            "proposed flush hub pointer on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  hub          ",
            hub
        );

        console2.log(
            "  chainSelector",
            chainSelector
        );

        console2.log(
            "earliest executeFlushHub()",
            block.timestamp + 3 days
        );
    }

    function executeFlushHub()
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

        address hub = _loadHub(
            HUB_NETWORK
        );

        uint64 chainSelector = _flushHubChainSelector();

        vm.startBroadcast(
            privKey
        );

        if (AdminFacet(diamond).getFlushHubChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeFlushHubChange();
        }

        vm.stopBroadcast();

        (
            address onchainHub,
            uint64 onchainSelector
        ) = AdminFacet(diamond).getFlushHub();

        require(
            onchainHub == hub
                && onchainSelector == chainSelector,
            "UpgradeCohortFlush: pointer does not match config hub"
        );

        console2.log(
            "flush hub pointer wired on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "grant this vault as a hub reporter from the shared referral repository so the hub accepts its flushes"
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

        vm.startBroadcast(
            privKey
        );

        bool flushRoundPending = WiseSovrenNodesDiamond(payable(diamond)).selectorChangeQueuedAt(
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()[0]
        ) > 0;

        _cancelGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _cancelGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        if (flushRoundPending) {
            _cancelGroup(
                diamond,
                WiseSovrenNodesDiamondSelectors._adminSelectors()
            );

            if (WiseSovrenNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelTransferHookFacetChange();
            }
        } else {
            console2.log(
                "flush batch not pending: the admin batch and the hook proposal were left alone (they may belong to the registry round)"
            );
        }

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        if (d.selectorToFacet(AdminFacet.getFlushHubChangeQueuedAt.selector) != address(0)) {
            if (AdminFacet(diamond).getFlushHubChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelFlushHubChange();
            }
        }

        vm.stopBroadcast();

        console2.log(
            "aborted pending cohort-flush upgrade on diamond",
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

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        console2.log(
            "diamond",
            diamond
        );

        console2.log(
            "admin group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._adminSelectors()[0]
            )
        );

        console2.log(
            "cohortFlush group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()[0]
            )
        );

        console2.log(
            "cohortFlushPolicy group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()[0]
            )
        );

        console2.log(
            "admin batch queuedAt",
            d.selectorChangeQueuedAt(
                WiseSovrenNodesDiamondSelectors._adminSelectors()[0]
            )
        );

        console2.log(
            "cohortFlush batch queuedAt",
            d.selectorChangeQueuedAt(
                WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()[0]
            )
        );

        console2.log(
            "cohortFlushPolicy batch queuedAt",
            d.selectorChangeQueuedAt(
                WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()[0]
            )
        );

        console2.log(
            "transferHookFacet",
            d.transferHookFacet()
        );

        console2.log(
            "proposedTransferHookFacet",
            d.proposedTransferHookFacet()
        );

        if (d.selectorToFacet(AdminFacet.getFlushHub.selector) != address(0)) {

            (
                address hub,
                uint64 chainSelector
            ) = AdminFacet(diamond).getFlushHub();

            console2.log(
                "onchain flush hub",
                hub
            );

            console2.log(
                "onchain flush selector",
                chainSelector
            );

            console2.log(
                "pointer queuedAt",
                AdminFacet(diamond).getFlushHubChangeQueuedAt()
            );
        }

        if (d.selectorToFacet(CohortFlushPolicyFacet.getPublicFlushEnabled.selector) != address(0)) {

            console2.log(
                "publicFlushEnabled",
                CohortFlushPolicyFacet(diamond).getPublicFlushEnabled()
            );

            console2.log(
                "flushGasLimit",
                CohortFlushPolicyFacet(diamond).getFlushGasLimit()
            );
        }
    }

    function _isHubChain()
        internal
        view
        returns (bool)
    {
        return _sameString(
            _networkName(),
            HUB_NETWORK
        );
    }

    function _flushHubChainSelector()
        internal
        view
        returns (uint64)
    {
        if (_isHubChain()) {
            return 0;
        }

        return _loadCcipChainSelector(
            HUB_NETWORK
        );
    }

    function _proposeGroup(
        address _diamond,
        bytes4[] memory _sels,
        address _facet
    )
        internal
    {
        WiseSovrenNodesDiamond(payable(_diamond)).proposeSelectors(
            _sels,
            _facet
        );
    }

    function _executeGroup(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
    {
        if (WiseSovrenNodesDiamond(payable(_diamond)).selectorChangeQueuedAt(_sels[0]) == 0) {
            return;
        }

        WiseSovrenNodesDiamond(payable(_diamond)).executeSelectorChanges(
            _sels
        );
    }

    function _cancelGroup(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
    {
        for (uint256 i; i < _sels.length; ++i) {
            WiseSovrenNodesDiamond(payable(_diamond)).cancelSelectorProposal(
                _sels[i]
            );
        }
    }

    /// @dev The round order: this round re-proposes the admin batch and the transfer hook,
    /// so it may start only after the registry round executed on this vault, and never twice
    /// (a second propose overwrites every pending batch and restarts its clock) unless
    /// `UPGRADE_FORCE_REPROPOSE=true` is set on purpose.
    function _requireRegistryRoundExecuted(
        address _diamond
    )
        internal
        view
    {
        WiseSovrenNodesDiamond dispatcher = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        require(
            dispatcher.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0),
            "UpgradeCohortFlush: the registry round has not executed on this vault (law 8: run UpgradeReferralRegistry.execute() first)"
        );

        if (vm.envOr("UPGRADE_FORCE_REPROPOSE", false)) {
            return;
        }

        require(
            dispatcher.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()[0]) == address(0),
            "UpgradeCohortFlush: the flush round already executed on this vault (set UPGRADE_FORCE_REPROPOSE=true to propose it again on purpose)"
        );

        require(
            dispatcher.selectorChangeQueuedAt(WiseSovrenNodesDiamondSelectors._adminSelectors()[0]) == 0,
            "UpgradeCohortFlush: a selector round is already pending on this vault (a second propose would overwrite it and restart its clock; abort() first, or set UPGRADE_FORCE_REPROPOSE=true)"
        );
    }

    function _assertGroupRouted(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
        view
    {
        WiseSovrenNodesDiamond dispatcher = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        for (uint256 i; i < _sels.length; ++i) {
            require(
                dispatcher.selectorToFacet(_sels[i]) != address(0),
                "UpgradeCohortFlush: a selector this round adds routes to no facet after execute() (its batch proposal was missing or cancelled)"
            );

            require(
                dispatcher.selectorChangeQueuedAt(_sels[i]) == 0,
                "UpgradeCohortFlush: a round selector is still queued after execute() (its batch was skipped because its first selector was cancelled)"
            );
        }
    }
}
