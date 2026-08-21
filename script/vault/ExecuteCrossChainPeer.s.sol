// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

/// @notice Promotes a staged cross-chain peer to live on the local diamond via master.
/// Run after {ProposeCrossChainPeer}: instant before {FinalizeVault}, otherwise only once
/// the 3-day CROSS_CHAIN_PEER_CHANGE_DELAY has elapsed. The lane carries value once the
/// mirror propose/execute pair has also run on the peer chain.
contract ExecuteCrossChainPeer is VaultConfig {

    function run(
        uint64 _chainSelector
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

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            _chainSelector
        );

        vm.stopBroadcast();

        console2.log("executed peer change for selector", _chainSelector);
    }
}
