// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

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
}
