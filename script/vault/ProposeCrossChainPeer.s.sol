// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

/// @notice Stages a single cross-chain peer on the local diamond via master. Split out
/// from {RegisterCrossChainPeers} so an Nth chain can be added to an already-finalized,
/// running mesh: run this, wait out the 3-day CROSS_CHAIN_PEER_CHANGE_DELAY, then run
/// {ExecuteCrossChainPeer} (both are instant only before {FinalizeVault}). Takes raw args
/// so no _meshNetworks/config edit is needed to add a peer to a live diamond.
contract ProposeCrossChainPeer is VaultConfig {

    function run(
        uint64 _chainSelector,
        address _peer,
        uint8 _peerDecimals
    )
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

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            _chainSelector,
            _peer,
            _peerDecimals
        );

        vm.stopBroadcast();

        console2.log("proposed peer for selector", _chainSelector);
        console2.log("  peer                    ", _peer);
        console2.log("  decimals                ", _peerDecimals);
    }
}
