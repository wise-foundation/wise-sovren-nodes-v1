// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {IReferralRegistry} from "../../src/diamond/vault/interfaces/pending/IReferralRegistry.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseSovrenNodesDiamondSelectors} from "./WiseSovrenNodesDiamondSelectors.sol";

/**
 * @dev The two reads this script makes on the shared referral registry: whether this
 * diamond is allowlisted and whether the registry's sync setup is finalized. The registry
 * itself is deployed and operated from the shared referral repository, so only its
 * interface is declared here.
 */
interface IReferralRegistryStatus {

    function allowedVault(
        address _vault
    )
        external
        view
        returns (bool);

    function syncInitialized()
        external
        view
        returns (bool);
}

/// @notice Installs the referral-registry round
/// on an already-running, finalized diamond: the cohort recorder manifest
/// PLUS the slot-77 registry pointer. It replaces the two earlier upgrade scripts, deleted
/// so that neither can run by mistake: the slot-77 shard recompiles every facet in the
/// manifest and the
/// referral facets now write the per-chain standalone registry, so installing the
/// older script's builds would route stale bytecode. The LIVE diamond entry contracts are
/// never redeployed and never migrated: this round only deploys NEW facet contracts and
/// routes selectors through the diamond's existing 3-day timelock, plus one pointer write.
///
/// Prerequisite (once per CHAIN, not per vault): the shared referral repository has deployed
/// the chain's registry, allowlisted this diamond through its allow lane, and the address is recorded in
/// `config/registry.<network>.json`; `propose()` fail-fasts if not. The facet contracts
/// themselves carry no such gate: `deployFacets()` puts the 14 manifest facets onchain at
/// any time, before the allow lane has executed, and records their addresses in
/// `config/referral-round.<product>.<network>.json` (written only under `--broadcast`, so
/// a dry run leaves no phantom record). `propose()` reads that record, refuses to run
/// without it or with a recorded facet that has no code (a deploy run that stopped with
/// transactions unsent is finished with `--resume`), and proposes the batches without
/// deploying again. `deployFacets()` refuses to run while a record with deployed code
/// exists, so the facets are never deployed twice by mistake.
///
/// TWO chained 3-day clocks per vault; the pointer trio selectors are NEW (not
/// genesis-routed), so `proposeReferralRegistry` only exists on the diamond after the
/// selector round executes:
///   `deployFacets()`   : deploys the 14 manifest facets and writes their record. No clock
///                        starts and the diamond is not touched.
///   `propose()`        : takes the 14 recorded facets, proposes all 13 selector batches
///                        AND the transfer-hook swap to {CohortHookFacet}. Clock 1 starts.
///                        The routed move slice {CohortMoveHookFacet} ships in this round
///                        beside the routed bridge slice and the pointer swap, because the
///                        pointer facet forwards the move pair into it by selector.
///   `execute()`        : after 3 days: flips every batch, hook last. Idempotent
///                        (queuedAt-guarded), re-runnable after partial mining. Then
///                        asserts, in simulation and before anything is sent, that every
///                        selector of the thirteen batches routes to a facet and has no
///                        proposal left queued (the legacy pair excepted, whose optional
///                        retirement routes it to zero). A batch that carries a selector
///                        the genesis dispatcher never routed (the admin batch's
///                        post-genesis selectors and the referral, permit2 referral,
///                        recorder, bridge hook and move hook batches) fails the run when
///                        its proposal was missing or cancelled, and a batch skipped
///                        because its first selector was cancelled fails it too. The user,
///                        permit2, move, bridge and both queue batches hold only genesis
///                        selectors and the auto compound batch only selectors an earlier
///                        round routed; each keeps its live facet when its proposal is
///                        missing, so compare the per-batch facets `status()` prints with
///                        the ones `propose()` logged.
///   `proposePointer()` : same day as execute(): first runs the registry seam probe that
///                        `executePointer()` runs (below) against the config registry, so a
///                        registry that would fail it is refused three days earlier; then
///                        starts clock 2 through the freshly-routed {AdminFacet} trio,
///                        pointing at the config registry. A pending proposal of the config
///                        registry is reported and left; a pending proposal naming any other
///                        address is cancelled and the config registry proposed in the same
///                        broadcast, which restarts clock 2. With the pointer already wired
///                        to the config registry it proposes nothing and only cancels a
///                        mismatched pending proposal.
///   `executePointer()` : after 3 more days: first probes the config registry for every
///                        seam the vault calls (staticcalls of `referrerOf`,
///                        `effectiveReferrerOf`, `getReferrerPair`,
///                        `getPayoutDesignation`, `seedsLatched` and
///                        `syncPeerQuarantined` for every chain of the vault's mesh
///                        manifest, each answer held to the size and bounds the vault's
///                        own decoders apply, plus `allowedVault(diamond)` in place of the
///                        four write seams a staticcall cannot probe) and reverts on an
///                        unclean answer; then executes the pointer change (code + shape
///                        probe onchain) and post-asserts pointer == config. It refuses a
///                        registry whose sync setup is not finalized yet. On an armed vault the
///                        AdminFacet refuses the execute while a change is pending: disarm
///                        first, run `executePointer()`, then run `arm()` again.
///   `arm()`            : the separate go-live step: pre-asserts pointer wired, this diamond
///                        allowlisted on the registry, the registry's sync setup finalized,
///                        and every vault recorded for this chain (each product's vault
///                        config for this network; a product with no config here, or a
///                        recorded address without code, is skipped) routing the round's
///                        recorder, bridge hook and move hook batches. It then raises
///                        `bridgeGasLimit` to 5M (headroom for the atomic cross-chain carry
///                        apply on `ccipReceive`) BEFORE `setCohortSyncEnabled(true)` (which
///                        itself requires the pointer onchain), so no bridge ever leaves an
///                        armed vault under the 200k genesis budget, and post-asserts both
///                        values.
///   `proposeRetireLegacyReferralBridge()` : REQUIRED by the rollout (the legacy pair retires), any
///                        day after execute(): proposes the genesis passthrough pair
///                        `bridgeToVaultWithReferral` / `quoteBridgeFeeWithReferral` to the
///                        zero facet. The armed carry never needs caller bytes (both bridge
///                        entrypoints send identical wires once armed) and the name misleads
///                        about the referral system, so the pair is pure surface. Its own
///                        3-day clock, independent of the pointer clock; guarded on the
///                        round being executed and no bridge-group proposal pending. A
///                        pending zero-facet proposal of both selectors is reported and
///                        left; a pending proposal of either selector naming anything else
///                        is cancelled and the retirement proposed in the same broadcast.
///   `executeRetireLegacyReferralBridge()` : after 3 days: the pair routes to zero and the
///                        live fallback reverts {FacetNotFound} for both; `bridgeToVault`
///                        and `quoteBridgeFee` are post-asserted untouched. Reversible by a
///                        normal proposal of the pair back to the round's BridgeFacet.
///   `abort()`          : while the round is unexecuted (the recorder batch routes to no
///                        facet), cancels every pending selector batch of the round and the
///                        hook proposal. Once the recorder batch routes it treats the round as
///                        executed and leaves every selector batch and the hook alone, because
///                        the flush and payout rounds re-propose the admin batch and the flush
///                        round the hook; a partially mined `execute()` is finished by running
///                        `execute()` again. It never touches a pending legacy retirement,
///                        which is proposable only after the round executed: cancel that with
///                        one master `cancelSelectorProposal` per selector of the pair. The
///                        pointer proposal is cancelled in both cases (pre-execute only); the
///                        log names the branch taken.
///   `status()`         : read-only sanity print for the operator (no broadcast), including
///                        `bridgeGasLimit` and the facet each of the thirteen batches routes to
///                        (batch order of `propose()`).
///
/// Ordering law the steps encode: registry deployed → diamond
/// allowlisted → selectors live → pointer wired → arm LAST. Every intermediate state is
/// default-off: recorder touchpoints are gated no-ops until arm(), `...WithReferral`
/// entrypoints revert {ReferralRegistryNotSet} while the pointer is unset (loud, no silent
/// referrer drop), and the recorder's registry read is a guarded staticcall whose failure,
/// an unset pointer included, is reported as a failed lookup that defers the mutation.
/// Rollback: pre-execute abort(); post-arm `setCohortSyncEnabled(false)`
/// is instant (DISARM FIRST before any hook re-proposal).
///
/// Invocation for the one Sovren vault (product via VAULT_PRODUCT, chain via --rpc-url):
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "deployFacets()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "propose()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "execute()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "proposePointer()" --rpc-url mainnet --broadcast
///   ... wait 3 days ...
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "executePointer()" --rpc-url mainnet --broadcast
///   VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "arm()" --rpc-url mainnet --broadcast
/// The registry and the hub are shared with the WiseTelecomNodes vaults and are deployed
/// from that repository; this diamond joins them through the registry allow lane and the
/// hub source tag and reporter grant cast there, never through a redeploy.
///
/// NOTHING here may be broadcast until the owner gives the explicit go-ahead. After a REAL
/// broadcast is executed and verified, `git mv` the graduated
/// files out of EVERY pending/ segment in the same commit: facets/pending/,
/// declarations/pending/ (the shards this round's facets were compiled with),
/// interfaces/pending/ and shared/pending/.
contract UpgradeReferralRegistry is VaultConfig {

    struct RoundFacets {
        address adminFacet;
        address userFacet;
        address permit2UserFacet;
        address moveFacet;
        address bridgeFacet;
        address queueJoinLeaveFacet;
        address queueFulfillFacet;
        address referralFacet;
        address permit2ReferralFacet;
        address autoCompoundFacet;
        address cohortRecorderFacet;
        address cohortHookFacet;
        address cohortBridgeHookFacet;
        address cohortMoveHookFacet;
    }

    uint256 internal constant ROUND_FACET_COUNT = 14;

    uint256 internal constant ARMED_BRIDGE_GAS_LIMIT = 5_000_000;

    RoundFacets internal deployedRoundFacets;

    bool internal roundFacetsDeployedHere;

    function deployFacets()
        external
        returns (RoundFacets memory facets)
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory product = _vaultProduct();
        string memory network = _networkName();

        (
            address diamond,
        ) = _loadVault(
            network
        );

        _requireRoundNotProposed(
            diamond
        );

        _requireRoundFacetsNotDeployed(
            product,
            network
        );

        vm.startBroadcast(
            privKey
        );

        facets = _deployRoundFacets();

        vm.stopBroadcast();

        deployedRoundFacets = facets;
        roundFacetsDeployedHere = true;

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveRoundFacets(
                product,
                network,
                facets
            );
        } else {
            console2.log(
                "simulation only: config/referral-round not written"
            );
        }

        console2.log(
            "deployed referral-registry round facets for diamond",
            diamond
        );

        console2.log(
            "  product / network",
            product,
            network
        );

        _logRoundFacets(
            facets
        );
    }

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

        IReferralRegistryStatus registry = IReferralRegistryStatus(
            _loadRegistry(
                _networkName()
            )
        );

        require(
            address(registry).code.length > 0,
            "UpgradeReferralRegistry: chain registry not deployed (config/registry.<network>.json)"
        );

        require(
            registry.allowedVault(
                diamond
            ),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry (the allow lane runs from the shared referral repository)"
        );

        _requireRoundNotProposed(
            diamond
        );

        RoundFacets memory facets = _resolveRoundFacets();

        vm.startBroadcast(
            privKey
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._adminSelectors(),
            facets.adminFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._userSelectors(),
            facets.userFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._permit2Selectors(),
            facets.permit2UserFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._moveSelectors(),
            facets.moveFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._bridgeSelectors(),
            facets.bridgeFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors(),
            facets.queueJoinLeaveFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._queueFulfillSelectors(),
            facets.queueFulfillFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._referralSelectors(),
            facets.referralFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors(),
            facets.permit2ReferralFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors(),
            facets.cohortRecorderFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors(),
            facets.cohortBridgeHookFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors(),
            facets.cohortMoveHookFacet
        );

        _proposeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors(),
            facets.autoCompoundFacet
        );

        AdminFacet(diamond).proposeTransferHookFacet(
            facets.cohortHookFacet
        );

        vm.stopBroadcast();

        console2.log(
            "proposed referral-registry upgrade on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  registry (per chain)",
            address(registry)
        );

        _logRoundFacets(
            facets
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
            WiseSovrenNodesDiamondSelectors._userSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._permit2Selectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._moveSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._queueFulfillSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        _executeGroup(
            diamond,
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors()
        );

        if (WiseSovrenNodesDiamond(payable(diamond)).transferHookChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeTransferHookFacetChange();
        }

        vm.stopBroadcast();

        bytes4[][] memory groups = _roundGroups();

        for (uint256 i; i < groups.length; ++i) {
            _assertGroupRouted(
                diamond,
                groups[i]
            );
        }

        console2.log(
            "executed referral-registry selector round on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "run proposePointer() now (second 3-day clock)"
        );
    }

    function proposePointer()
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

        address registry = _loadRegistry(
            _networkName()
        );

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        require(
            d.selectorToFacet(AdminFacet.proposeReferralRegistry.selector) != address(0),
            "UpgradeReferralRegistry: pointer trio not routed yet (run execute() first)"
        );

        _assertRegistrySeams(
            registry,
            diamond,
            _meshLaneSelectors()
        );

        bool pending = AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0;

        address proposed = AdminFacet(diamond).getProposedReferralRegistry();

        if (pending && proposed == registry) {
            console2.log(
                "pointer proposal for the config registry already pending on diamond",
                diamond
            );

            return;
        }

        bool wired = AdminFacet(diamond).getReferralRegistry() == registry;

        if (wired && pending == false) {
            console2.log(
                "pointer already wired to the config registry on diamond",
                diamond
            );

            return;
        }

        if (pending) {
            console2.log(
                "cancelling mismatched pending pointer proposal",
                proposed
            );
        }

        vm.startBroadcast(
            privKey
        );

        if (pending) {
            AdminFacet(diamond).cancelReferralRegistryChange();
        }

        if (wired) {
            vm.stopBroadcast();

            console2.log(
                "pointer already wired to the config registry; cancelled the mismatched proposal only on diamond",
                diamond
            );

            return;
        }

        AdminFacet(diamond).proposeReferralRegistry(
            registry
        );

        vm.stopBroadcast();

        console2.log(
            "proposed registry pointer on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  registry",
            registry
        );

        console2.log(
            "earliest executePointer()",
            block.timestamp + 3 days
        );
    }

    function executePointer()
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

        address registry = _loadRegistry(
            _networkName()
        );

        _assertRegistrySeams(
            registry,
            diamond,
            _meshLaneSelectors()
        );

        require(
            IReferralRegistryStatus(registry).syncInitialized(),
            "UpgradeReferralRegistry: registry sync setup not finalized (finalized from the shared referral repository)"
        );

        vm.startBroadcast(
            privKey
        );

        if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
            AdminFacet(diamond).executeReferralRegistryChange();
        }

        vm.stopBroadcast();

        require(
            AdminFacet(diamond).getReferralRegistry() == registry,
            "UpgradeReferralRegistry: pointer does not match config registry"
        );

        console2.log(
            "registry pointer wired on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "run arm() to enable recording (separate go-live step)"
        );
    }

    function arm()
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

        IReferralRegistryStatus registry = IReferralRegistryStatus(
            _loadRegistry(
                _networkName()
            )
        );

        require(
            AdminFacet(diamond).getReferralRegistry() == address(registry),
            "UpgradeReferralRegistry: pointer not wired to the config registry"
        );

        require(
            registry.allowedVault(
                diamond
            ),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry"
        );

        require(
            registry.syncInitialized(),
            "UpgradeReferralRegistry: registry sync setup not finalized (finalized from the shared referral repository)"
        );

        _assertChainRoundExecuted(
            _networkName()
        );

        _assertPeerRoundsExecuted(
            diamond
        );

        vm.startBroadcast(
            privKey
        );

        BridgeFacet(diamond).setBridgeGasLimit(
            ARMED_BRIDGE_GAS_LIMIT
        );

        AdminFacet(diamond).setCohortSyncEnabled(
            true
        );

        vm.stopBroadcast();

        require(
            BridgeFacet(diamond).bridgeGasLimit() == ARMED_BRIDGE_GAS_LIMIT,
            "UpgradeReferralRegistry: bridgeGasLimit is not the armed budget after arm()"
        );

        require(
            CohortRecorderFacet(diamond).getCohortSyncEnabled(),
            "UpgradeReferralRegistry: cohortSyncEnabled is not true after arm()"
        );

        console2.log(
            "armed cohort recorder on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "  bridgeGasLimit",
            uint256(BridgeFacet(diamond).bridgeGasLimit())
        );
    }

    function proposeRetireLegacyReferralBridge()
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

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        bytes4[] memory pair = WiseSovrenNodesDiamondSelectors._legacyReferralBridgeSelectors();

        require(
            d.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0),
            "UpgradeReferralRegistry: registry round not executed yet (run execute() first)"
        );

        address bridgeFacet = d.selectorToFacet(
            BridgeFacet.bridgeToVault.selector
        );

        require(
            bridgeFacet != address(0)
                && d.selectorToFacet(pair[0]) == bridgeFacet
                && d.selectorToFacet(pair[1]) == bridgeFacet,
            "UpgradeReferralRegistry: legacy pair not on the round's BridgeFacet"
        );

        require(
            d.selectorChangeQueuedAt(BridgeFacet.bridgeToVault.selector) == 0,
            "UpgradeReferralRegistry: bridge group proposal still pending (execute() first)"
        );

        bool pending = d.selectorChangeQueuedAt(pair[0]) > 0
            || d.selectorChangeQueuedAt(pair[1]) > 0;

        bool pendingMatches = d.selectorChangeQueuedAt(pair[0]) > 0
            && d.selectorChangeQueuedAt(pair[1]) > 0
            && d.proposedSelectorFacet(pair[0]) == address(0)
            && d.proposedSelectorFacet(pair[1]) == address(0);

        if (pendingMatches) {
            console2.log(
                "legacy referral bridge retirement already pending on diamond",
                diamond
            );

            return;
        }

        if (pending) {
            console2.log(
                "cancelling mismatched pending proposal of the legacy pair, bridge selector facet",
                d.proposedSelectorFacet(
                    pair[0]
                )
            );

            console2.log(
                "  quote selector facet",
                d.proposedSelectorFacet(
                    pair[1]
                )
            );
        }

        vm.startBroadcast(
            privKey
        );

        if (pending) {
            _cancelGroup(
                diamond,
                pair
            );
        }

        _proposeGroup(
            diamond,
            pair,
            address(0)
        );

        vm.stopBroadcast();

        console2.log(
            "proposed legacy referral bridge retirement on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
        );

        console2.log(
            "earliest executeRetireLegacyReferralBridge()",
            block.timestamp + 3 days
        );
    }

    function executeRetireLegacyReferralBridge()
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

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        bytes4[] memory pair = WiseSovrenNodesDiamondSelectors._legacyReferralBridgeSelectors();

        vm.startBroadcast(
            privKey
        );

        _executeGroup(
            diamond,
            pair
        );

        vm.stopBroadcast();

        require(
            d.selectorToFacet(pair[0]) == address(0)
                && d.selectorToFacet(pair[1]) == address(0),
            "UpgradeReferralRegistry: legacy pair still routed (propose the retirement first)"
        );

        require(
            d.selectorToFacet(BridgeFacet.bridgeToVault.selector) != address(0),
            "UpgradeReferralRegistry: bridgeToVault lost its route"
        );

        require(
            d.selectorToFacet(BridgeFacet.quoteBridgeFee.selector) != address(0),
            "UpgradeReferralRegistry: quoteBridgeFee lost its route"
        );

        console2.log(
            "retired legacy referral bridge on diamond",
            diamond
        );

        console2.log(
            "  product / network",
            _vaultProduct(),
            _networkName()
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

        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(diamond)
        );

        bool roundExecuted = d.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0);

        vm.startBroadcast(
            privKey
        );

        if (roundExecuted == false) {

            bytes4[][] memory groups = _roundGroups();

            for (uint256 i; i < groups.length; ++i) {
                _cancelGroup(
                    diamond,
                    groups[i]
                );
            }

            if (d.transferHookChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelTransferHookFacetChange();
            }
        }

        if (d.selectorToFacet(AdminFacet.getReferralRegistryChangeQueuedAt.selector) != address(0)) {
            if (AdminFacet(diamond).getReferralRegistryChangeQueuedAt() > 0) {
                AdminFacet(diamond).cancelReferralRegistryChange();
            }
        }

        vm.stopBroadcast();

        if (roundExecuted == false) {
            console2.log(
                "round unexecuted: cancelled every selector batch, the hook proposal and any pointer proposal on diamond",
                diamond
            );
        } else {
            console2.log(
                "round executed: left every selector batch, the hook and any legacy retirement alone, cancelled any pending pointer proposal on diamond",
                diamond
            );
        }
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

        address registry = _loadRegistry(
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
            "config registry",
            registry
        );

        console2.log(
            "admin group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._adminSelectors()[0]
            )
        );

        console2.log(
            "referral group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._referralSelectors()[0]
            )
        );

        console2.log(
            "cohort group facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]
            )
        );

        console2.log(
            "cohort move hook facet",
            d.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()[0]
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

        if (d.selectorToFacet(AdminFacet.getReferralRegistry.selector) != address(0)) {

            console2.log(
                "onchain registry pointer",
                AdminFacet(diamond).getReferralRegistry()
            );

            console2.log(
                "proposed registry pointer",
                AdminFacet(diamond).getProposedReferralRegistry()
            );

            console2.log(
                "pointer queuedAt",
                AdminFacet(diamond).getReferralRegistryChangeQueuedAt()
            );
        }

        if (registry.code.length > 0) {
            console2.log(
                "diamond allowlisted on registry",
                IReferralRegistryStatus(registry).allowedVault(
                    diamond
                )
            );
        }

        if (d.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0)) {
            console2.log(
                "cohortSyncEnabled",
                CohortRecorderFacet(diamond).getCohortSyncEnabled()
            );
        }

        console2.log(
            "bridgeGasLimit",
            uint256(BridgeFacet(diamond).bridgeGasLimit())
        );

        bytes4[][] memory groups = _roundGroups();

        for (uint256 i; i < groups.length; ++i) {
            console2.log(
                "round batch facet",
                i,
                d.selectorToFacet(
                    groups[i][0]
                )
            );

            console2.log(
                "round batch proposed facet",
                i,
                d.proposedSelectorFacet(
                    groups[i][0]
                )
            );

            console2.log(
                "round batch queuedAt",
                i,
                d.selectorChangeQueuedAt(
                    groups[i][0]
                )
            );
        }

        bytes4[] memory pair = WiseSovrenNodesDiamondSelectors._legacyReferralBridgeSelectors();

        console2.log(
            "legacy bridgeToVaultWithReferral facet",
            d.selectorToFacet(
                pair[0]
            )
        );

        console2.log(
            "legacy retirement queuedAt",
            d.selectorChangeQueuedAt(
                pair[0]
            )
        );
    }

    /// @dev Probes `_registry` for every seam the vault calls, before the vault's registry
    /// pointer may be proposed or executed toward it. Each read the vault makes is
    /// staticcalled and held to the size and bounds the vault's own decoder applies; the four
    /// write seams (`assignReferrer`, `mergeReferrer`, `stageCarry`, `consumeCarry`) cannot be
    /// staticcalled, since each writes and is gated to an allowlisted vault, so the read of
    /// `allowedVault(_diamond)` stands in for them. Every probe answers cleanly on the real
    /// registry, and a replacement registry must answer the same way.
    function _assertRegistrySeams(
        address _registry,
        address _diamond,
        uint64[] memory _laneSelectors
    )
        internal
        view
    {
        require(
            _registry.code.length > 0,
            "UpgradeReferralRegistry: config registry has no code"
        );

        uint256[] memory words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.referrerOf.selector,
                _diamond
            ),
            1
        );

        require(
            words[0] <= type(uint160).max,
            "UpgradeReferralRegistry: referrerOf answer is not a clean address"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.effectiveReferrerOf.selector,
                _diamond,
                _diamond
            ),
            1
        );

        require(
            words[0] <= type(uint160).max,
            "UpgradeReferralRegistry: effectiveReferrerOf answer is not a clean address"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.getReferrerPair.selector,
                _diamond
            ),
            3
        );

        require(
            words[0] <= type(uint160).max
                && words[1] <= CohortWeeks.RING_LANE_MAX
                && words[2] <= CohortWeeks.CARRY_BYTE_MASK,
            "UpgradeReferralRegistry: getReferrerPair answer outside the vault's decode bounds"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.getPayoutDesignation.selector,
                _diamond
            ),
            2
        );

        require(
            words[0] <= type(uint160).max
                && (words[1] >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT) <= CohortWeeks.RING_LANE_MAX,
            "UpgradeReferralRegistry: getPayoutDesignation answer outside the vault's decode bounds"
        );

        words = _probeRegistry(
            _registry,
            abi.encodeWithSelector(
                IReferralRegistry.seedsLatched.selector
            ),
            1
        );

        require(
            words[0] <= 1,
            "UpgradeReferralRegistry: seedsLatched answer is not a clean bool"
        );

        for (uint256 i; i < _laneSelectors.length; ++i) {

            words = _probeRegistry(
                _registry,
                abi.encodeWithSelector(
                    IReferralRegistry.syncPeerQuarantined.selector,
                    _laneSelectors[i]
                ),
                1
            );

            require(
                words[0] <= 1,
                "UpgradeReferralRegistry: syncPeerQuarantined answer is not a clean bool"
            );

            console2.log(
                "  lane selector",
                uint256(_laneSelectors[i])
            );

            console2.log(
                "    quarantined",
                words[0] == 1
            );
        }

        require(
            IReferralRegistryStatus(_registry).allowedVault(
                _diamond
            ),
            "UpgradeReferralRegistry: diamond not allowlisted on the registry, so assignReferrer, mergeReferrer, stageCarry and consumeCarry would refuse it"
        );

        console2.log(
            "registry seam probes clean",
            _registry
        );
    }

    function _probeRegistry(
        address _registry,
        bytes memory _calldata,
        uint256 _wordCount
    )
        internal
        view
        returns (uint256[] memory words)
    {
        (
            bool success,
            bytes memory returnData
        ) = _registry.staticcall(
            _calldata
        );

        require(
            success && returnData.length == _wordCount * 32,
            "UpgradeReferralRegistry: registry seam probe failed or returned the wrong size"
        );

        words = new uint256[](
            _wordCount
        );

        for (uint256 i; i < _wordCount; ++i) {

            uint256 word;

            assembly {
                word := mload(add(returnData, mul(add(i, 1), 32)))
            }

            words[i] = word;
        }
    }

    function _meshLaneSelectors()
        internal
        view
        returns (uint64[] memory selectors)
    {
        string[] memory chains = _loadMesh().chains;

        selectors = new uint64[](
            chains.length
        );

        for (uint256 i; i < chains.length; ++i) {
            selectors[i] = _loadCcipChainSelector(
                chains[i]
            );
        }
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

    /// @dev The thirteen selector batches this round proposes and executes, in the order
    /// `propose()` and `execute()` handle them; `execute()` asserts them routed, `status()`
    /// prints their facets and `abort()` cancels them while the round is unexecuted.
    function _roundGroups()
        internal
        pure
        returns (bytes4[][] memory groups)
    {
        groups = new bytes4[][](
            13
        );

        groups[0] = WiseSovrenNodesDiamondSelectors._adminSelectors();
        groups[1] = WiseSovrenNodesDiamondSelectors._userSelectors();
        groups[2] = WiseSovrenNodesDiamondSelectors._permit2Selectors();
        groups[3] = WiseSovrenNodesDiamondSelectors._moveSelectors();
        groups[4] = WiseSovrenNodesDiamondSelectors._bridgeSelectors();
        groups[5] = WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors();
        groups[6] = WiseSovrenNodesDiamondSelectors._queueFulfillSelectors();
        groups[7] = WiseSovrenNodesDiamondSelectors._referralSelectors();
        groups[8] = WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors();
        groups[9] = WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors();
        groups[10] = WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors();
        groups[11] = WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors();
        groups[12] = WiseSovrenNodesDiamondSelectors._autoCompoundSelectors();
    }

    /// @dev Asserts that every selector of `_sels` routes to a facet on `_diamond` and has
    /// no proposal left queued. A selector the genesis dispatcher never routed fails the
    /// route check when its batch proposal was missing or cancelled; a batch that
    /// `_executeGroup` skipped because only its first selector was cancelled fails the queue
    /// check. A selector the genesis dispatcher already routed passes the route check with
    /// its genesis facet, so the user, permit2, move, bridge and both queue batches, which
    /// hold only genesis selectors, and the auto compound batch, whose selectors an earlier
    /// round routed, are checked by comparing the batch facets `status()` prints with the
    /// ones `propose()` logged. The legacy referral bridge pair is exempt:
    /// its optional retirement queues it and routes it to zero on purpose, and `execute()`
    /// stays re-runnable after that retirement.
    function _assertGroupRouted(
        address _diamond,
        bytes4[] memory _sels
    )
        internal
        view
    {
        WiseSovrenNodesDiamond d = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        bytes4[] memory pair = WiseSovrenNodesDiamondSelectors._legacyReferralBridgeSelectors();

        for (uint256 i; i < _sels.length; ++i) {

            if (_sels[i] == pair[0] || _sels[i] == pair[1]) {
                continue;
            }

            require(
                d.selectorToFacet(_sels[i]) != address(0),
                "UpgradeReferralRegistry: a selector this round adds routes to no facet after execute() (its batch proposal was missing or cancelled)"
            );

            require(
                d.selectorChangeQueuedAt(_sels[i]) == 0,
                "UpgradeReferralRegistry: a round selector is still queued after execute() (its batch was skipped because its first selector was cancelled)"
            );
        }
    }

    /// @dev Holds the same-chain arming order before any vault of this chain arms: every
    /// vault recorded for `_network` (each product's `config/vault.<product>.<network>.json`;
    /// a product with no config on this chain is skipped, and so is a recorded address with
    /// no code) must already route the round's recorder, bridge hook and move hook batches,
    /// because the vaults of one chain are live same-chain peers that carry moves and queue
    /// traffic between each other.
    function _assertChainRoundExecuted(
        string memory _network
    )
        internal
        view
    {
        string[1] memory products = [
            "usdc"
        ];

        for (uint256 i; i < products.length; ++i) {

            if (vm.exists(_vaultConfigPath(products[i], _network)) == false) {
                continue;
            }

            address vault = _loadVaultDiamond(
                products[i],
                _network
            );

            if (vault.code.length == 0) {
                continue;
            }

            WiseSovrenNodesDiamond v = WiseSovrenNodesDiamond(
                payable(vault)
            );

            require(
                v.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0)
                    && v.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()[0]) != address(0)
                    && v.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()[0]) != address(0),
                string.concat(
                    "UpgradeReferralRegistry: the ",
                    products[i],
                    " vault of this chain has not executed the registry round (run execute() on every vault of the chain before any arm())"
                )
            );

            console2.log(
                "  same-chain vault round executed",
                products[i],
                vault
            );
        }
    }

    /// @dev A second `propose()` on a vault would overwrite every pending batch and the hook
    /// proposal and restart their clocks (the flush round's included, law 8), and a propose
    /// after the round executed would re-deploy fourteen facets for nothing, so the step refuses
    /// both unless `UPGRADE_FORCE_REPROPOSE=true` is set on purpose.
    function _requireRoundNotProposed(
        address _diamond
    )
        internal
        view
    {
        if (vm.envOr("UPGRADE_FORCE_REPROPOSE", false)) {
            return;
        }

        WiseSovrenNodesDiamond dispatcher = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        require(
            dispatcher.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) == address(0),
            "UpgradeReferralRegistry: the registry round already executed on this vault (set UPGRADE_FORCE_REPROPOSE=true to propose it again on purpose)"
        );

        require(
            dispatcher.selectorChangeQueuedAt(WiseSovrenNodesDiamondSelectors._adminSelectors()[0]) == 0,
            "UpgradeReferralRegistry: a selector round is already pending on this vault (a second propose would overwrite it and restart its clock; abort() first, or set UPGRADE_FORCE_REPROPOSE=true)"
        );
    }

    /// @dev The arming order: no vault arms while a bridge peer of its mesh still runs the
    /// genesis bytecode, because a genesis source relays caller bytes verbatim under the
    /// 200,000 gas budget and an armed destination would apply a forged carry or strand the
    /// delivery. Every enabled bridge peer is read over its own chain alias (`vm.rpc`, the
    /// keyed endpoint of the env) and must route the cohort bridge hook slice, which only the
    /// executed registry round installs. `ARM_SKIP_PEER_CHECK=true` skips the read for an
    /// emergency re-arm.
    function _assertPeerRoundsExecuted(
        address _diamond
    )
        internal
    {
        if (vm.envOr("ARM_SKIP_PEER_CHECK", false)) {
            console2.log(
                "  law 1 peer check skipped by ARM_SKIP_PEER_CHECK"
            );

            return;
        }

        WiseSovrenNodesDiamond dispatcher = WiseSovrenNodesDiamond(
            payable(_diamond)
        );

        string[] memory chains = _loadMesh().chains;

        for (uint256 i; i < chains.length; ++i) {
            if (_sameString(chains[i], _networkName())) {
                continue;
            }

            uint64 selector = _loadCcipChainSelector(
                chains[i]
            );

            if (dispatcher.crossChainPeerEnabled(selector) == false) {
                continue;
            }

            address peer = dispatcher.crossChainPeer(
                selector
            );

            if (peer == address(0)) {
                continue;
            }

            string memory params = string.concat(
                "[{\"to\":\"",
                vm.toString(
                    peer
                ),
                "\",\"data\":\"",
                vm.toString(
                    abi.encodeWithSignature(
                        "selectorToFacet(bytes4)",
                        WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()[0]
                    )
                ),
                "\"},\"latest\"]"
            );

            bytes memory answer = vm.rpc(
                chains[i],
                "eth_call",
                params
            );

            require(
                answer.length == 32 && abi.decode(answer, (address)) != address(0),
                string.concat(
                    "UpgradeReferralRegistry: the bridge peer on ",
                    chains[i],
                    " has not executed the registry round (law 1: every peer routes the shipped BridgeFacet and the bridge hook slice before any vault arms)"
                )
            );

            console2.log(
                "  bridge peer round executed",
                chains[i],
                peer
            );
        }
    }

    function _deployRoundFacets()
        internal
        returns (RoundFacets memory facets)
    {
        facets.adminFacet = address(new AdminFacet());
        facets.userFacet = address(new UserFacet());
        facets.permit2UserFacet = address(new Permit2UserFacet());
        facets.moveFacet = address(new MoveFacet());
        facets.bridgeFacet = address(new BridgeFacet());
        facets.queueJoinLeaveFacet = address(new QueueJoinLeaveFacet());
        facets.queueFulfillFacet = address(new QueueFulfillFacet());
        facets.referralFacet = address(new ReferralFacet());
        facets.permit2ReferralFacet = address(new Permit2ReferralFacet());
        facets.autoCompoundFacet = address(new AutoCompoundFacet());
        facets.cohortRecorderFacet = address(new CohortRecorderFacet());
        facets.cohortHookFacet = address(new CohortHookFacet());
        facets.cohortBridgeHookFacet = address(new CohortBridgeHookFacet());
        facets.cohortMoveHookFacet = address(new CohortMoveHookFacet());
    }

    function _resolveRoundFacets()
        internal
        view
        returns (RoundFacets memory facets)
    {
        if (roundFacetsDeployedHere) {
            return deployedRoundFacets;
        }

        string memory product = _vaultProduct();
        string memory network = _networkName();

        require(
            _roundFacetsRecorded(
                product,
                network
            ),
            "UpgradeReferralRegistry: no round facets recorded for this product and network (config/referral-round.<product>.<network>.json), run deployFacets() first"
        );

        facets = _loadRoundFacets(
            product,
            network
        );

        require(
            _roundFacetsCodeCount(
                facets
            ) == ROUND_FACET_COUNT,
            "UpgradeReferralRegistry: a recorded round facet has no code (finish the deployFacets() run with --resume)"
        );
    }

    function _requireRoundFacetsNotDeployed(
        string memory _product,
        string memory _network
    )
        internal
        view
    {
        if (_roundFacetsRecorded(_product, _network) == false) {
            return;
        }

        require(
            _roundFacetsCodeCount(
                _loadRoundFacets(
                    _product,
                    _network
                )
            ) == 0,
            "UpgradeReferralRegistry: round facets already deployed and recorded (config/referral-round.<product>.<network>.json), propose() reads them"
        );
    }

    function _roundFacetArray(
        RoundFacets memory _facets
    )
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](ROUND_FACET_COUNT);
        list[0] = _facets.adminFacet;
        list[1] = _facets.userFacet;
        list[2] = _facets.permit2UserFacet;
        list[3] = _facets.moveFacet;
        list[4] = _facets.bridgeFacet;
        list[5] = _facets.queueJoinLeaveFacet;
        list[6] = _facets.queueFulfillFacet;
        list[7] = _facets.referralFacet;
        list[8] = _facets.permit2ReferralFacet;
        list[9] = _facets.autoCompoundFacet;
        list[10] = _facets.cohortRecorderFacet;
        list[11] = _facets.cohortHookFacet;
        list[12] = _facets.cohortBridgeHookFacet;
        list[13] = _facets.cohortMoveHookFacet;
    }

    function _roundFacetsCodeCount(
        RoundFacets memory _facets
    )
        internal
        view
        returns (uint256 count)
    {
        address[] memory list = _roundFacetArray(
            _facets
        );

        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].code.length > 0) {
                count++;
            }
        }
    }

    function _roundFacetsPath(
        string memory _product,
        string memory _network
    )
        internal
        view
        virtual
        returns (string memory)
    {
        return string.concat(
            "config/referral-round.",
            _product,
            ".",
            _network,
            ".json"
        );
    }

    function _roundFacetsRecorded(
        string memory _product,
        string memory _network
    )
        internal
        view
        returns (bool)
    {
        return vm.exists(
            _roundFacetsPath(
                _product,
                _network
            )
        );
    }

    function _saveRoundFacets(
        string memory _product,
        string memory _network,
        RoundFacets memory _facets
    )
        internal
    {
        string memory obj = "referralRound";

        vm.serializeAddress(
            obj,
            "adminFacet",
            _facets.adminFacet
        );

        vm.serializeAddress(
            obj,
            "userFacet",
            _facets.userFacet
        );

        vm.serializeAddress(
            obj,
            "permit2UserFacet",
            _facets.permit2UserFacet
        );

        vm.serializeAddress(
            obj,
            "moveFacet",
            _facets.moveFacet
        );

        vm.serializeAddress(
            obj,
            "bridgeFacet",
            _facets.bridgeFacet
        );

        vm.serializeAddress(
            obj,
            "queueJoinLeaveFacet",
            _facets.queueJoinLeaveFacet
        );

        vm.serializeAddress(
            obj,
            "queueFulfillFacet",
            _facets.queueFulfillFacet
        );

        vm.serializeAddress(
            obj,
            "referralFacet",
            _facets.referralFacet
        );

        vm.serializeAddress(
            obj,
            "permit2ReferralFacet",
            _facets.permit2ReferralFacet
        );

        vm.serializeAddress(
            obj,
            "autoCompoundFacet",
            _facets.autoCompoundFacet
        );

        vm.serializeAddress(
            obj,
            "cohortRecorderFacet",
            _facets.cohortRecorderFacet
        );

        vm.serializeAddress(
            obj,
            "cohortHookFacet",
            _facets.cohortHookFacet
        );

        vm.serializeAddress(
            obj,
            "cohortBridgeHookFacet",
            _facets.cohortBridgeHookFacet
        );

        string memory out = vm.serializeAddress(
            obj,
            "cohortMoveHookFacet",
            _facets.cohortMoveHookFacet
        );

        vm.writeJson(
            out,
            _roundFacetsPath(
                _product,
                _network
            )
        );
    }

    function _loadRoundFacets(
        string memory _product,
        string memory _network
    )
        internal
        view
        returns (RoundFacets memory facets)
    {
        string memory json = vm.readFile(
            _roundFacetsPath(
                _product,
                _network
            )
        );

        facets.adminFacet = vm.parseJsonAddress(json, ".adminFacet");
        facets.userFacet = vm.parseJsonAddress(json, ".userFacet");
        facets.permit2UserFacet = vm.parseJsonAddress(json, ".permit2UserFacet");
        facets.moveFacet = vm.parseJsonAddress(json, ".moveFacet");
        facets.bridgeFacet = vm.parseJsonAddress(json, ".bridgeFacet");
        facets.queueJoinLeaveFacet = vm.parseJsonAddress(json, ".queueJoinLeaveFacet");
        facets.queueFulfillFacet = vm.parseJsonAddress(json, ".queueFulfillFacet");
        facets.referralFacet = vm.parseJsonAddress(json, ".referralFacet");
        facets.permit2ReferralFacet = vm.parseJsonAddress(json, ".permit2ReferralFacet");
        facets.autoCompoundFacet = vm.parseJsonAddress(json, ".autoCompoundFacet");
        facets.cohortRecorderFacet = vm.parseJsonAddress(json, ".cohortRecorderFacet");
        facets.cohortHookFacet = vm.parseJsonAddress(json, ".cohortHookFacet");
        facets.cohortBridgeHookFacet = vm.parseJsonAddress(json, ".cohortBridgeHookFacet");
        facets.cohortMoveHookFacet = vm.parseJsonAddress(json, ".cohortMoveHookFacet");
    }

    function _logRoundFacets(
        RoundFacets memory _facets
    )
        internal
        pure
    {
        console2.log(
            "  AdminFacet          ",
            _facets.adminFacet
        );

        console2.log(
            "  UserFacet           ",
            _facets.userFacet
        );

        console2.log(
            "  Permit2UserFacet    ",
            _facets.permit2UserFacet
        );

        console2.log(
            "  MoveFacet           ",
            _facets.moveFacet
        );

        console2.log(
            "  BridgeFacet         ",
            _facets.bridgeFacet
        );

        console2.log(
            "  QueueJoinLeaveFacet ",
            _facets.queueJoinLeaveFacet
        );

        console2.log(
            "  QueueFulfillFacet   ",
            _facets.queueFulfillFacet
        );

        console2.log(
            "  ReferralFacet       ",
            _facets.referralFacet
        );

        console2.log(
            "  Permit2ReferralFacet",
            _facets.permit2ReferralFacet
        );

        console2.log(
            "  CohortRecorderFacet ",
            _facets.cohortRecorderFacet
        );

        console2.log(
            "  CohortHookFacet     ",
            _facets.cohortHookFacet
        );

        console2.log(
            "  CohortBridgeHookFacet",
            _facets.cohortBridgeHookFacet
        );

        console2.log(
            "  CohortMoveHookFacet ",
            _facets.cohortMoveHookFacet
        );

        console2.log(
            "  AutoCompoundFacet   ",
            _facets.autoCompoundFacet
        );

    }
}
