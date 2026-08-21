// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

/// @notice Wires the local diamond into the CCIP mesh: for every other chain in the mesh
/// manifest it registers the CANONICAL diamond address (the same address everywhere, thanks to
/// the deterministic deploy) as the cross-chain peer, keyed by that chain's CCIP selector from
/// config/ccip.<network>.json. Because the peer address is known in advance, this needs no
/// remote deploy record — peers can even be registered before the remote chain is deployed;
/// nobody else can ever claim the canonical address there (msg.sender-guarded salt). Run after
/// {DeployVaultDeterministic} and before {FinalizeVault}: pre-finalize the propose + execute
/// pair applies instantly. On a finalized chain the execute reverts with the 3-day timelock —
/// use {ProposeCrossChainPeer} / {ExecuteCrossChainPeer} instead.
///
/// LANE-ENABLEMENT TIMING GUARD: enabling a peer sets `crossChainPeerEnabled = true`, and
/// {BridgeFacet._executeBridgeReceive} mints on that flag alone — it does NOT check the deposit
/// gate. So enabling an inbound lane on a MIGRATION-TARGET leg before it is seeded would let a
/// bridge-in mint shares and push the diamond's `totalSupply()` above zero, tripping
/// {SeedVaultMigration}'s `require(totalSupply == 0)`. When the mesh manifest marks the local
/// chain in a `seedFirst` array, this script hard-aborts unless the leg is already seeded
/// (`totalSupply() > 0`). Greenfield legs (no `seedFirst`, or `false`) register freely.
contract RegisterCrossChainPeers is VaultConfig {

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory self = _networkName();

        VaultMesh memory mesh = _loadMesh();

        require(
            mesh.canonical != address(0),
            "RegisterCrossChainPeers: canonical not set in mesh manifest"
        );

        require(
            mesh.canonical.code.length > 0,
            "RegisterCrossChainPeers: no code at canonical on this chain"
        );

        _requireSeededIfMigrationTarget(
            mesh,
            self
        );

        vm.startBroadcast(
            privKey
        );

        for (uint256 i; i < mesh.chains.length; ++i) {
            if (_sameString(mesh.chains[i], self)) {
                continue;
            }

            ChainCfg memory remoteCfg = _loadCfg(
                mesh.chains[i]
            );

            BridgeFacet(mesh.canonical).proposeCrossChainPeer(
                remoteCfg.chainSelector,
                mesh.canonical,
                mesh.peerDecimals
            );

            BridgeFacet(mesh.canonical).executeCrossChainPeerChange(
                remoteCfg.chainSelector
            );

            console2.log("peer set for selector", remoteCfg.chainSelector);
            console2.log("  peer diamond        ", mesh.canonical);
        }

        vm.stopBroadcast();
    }

    /// @dev Aborts if the local chain is flagged `seedFirst` in the mesh manifest but the
    /// canonical diamond has not been seeded yet (`totalSupply() == 0`). The `seedFirst` array
    /// is parallel to `chains`; a mesh without it (greenfield-only meshes, testnet) skips the
    /// check entirely, so this is inert everywhere except the migration meshes.
    function _requireSeededIfMigrationTarget(
        VaultMesh memory _mesh,
        string memory _self
    )
        internal
        view
    {
        string memory json = vm.readFile(
            _meshPath()
        );

        if (vm.keyExistsJson(json, ".seedFirst") == false) {
            return;
        }

        bool[] memory seedFirst = vm.parseJsonBoolArray(
            json,
            ".seedFirst"
        );

        require(
            seedFirst.length == _mesh.chains.length,
            "RegisterCrossChainPeers: seedFirst/chains length mismatch"
        );

        for (uint256 i; i < _mesh.chains.length; ++i) {

            if (_sameString(_mesh.chains[i], _self) == false) {
                continue;
            }

            if (seedFirst[i] == false) {
                return;
            }

            require(
                IERC20(_mesh.canonical).totalSupply() > 0,
                "RegisterCrossChainPeers: migration-target leg not seeded - run SeedVaultMigration before enabling its inbound cross-chain lanes (a bridge-in would mint and trip the totalSupply==0 seed guard)"
            );

            return;
        }
    }
}
