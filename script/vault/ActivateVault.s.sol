// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";

/// @notice Activates a dormant chain: one master transaction that opens the deposit gate
/// (`setDepositsDisabled(false)`) on the canonical diamond. Everything else — peers, router,
/// finalization — was already wired at deploy time, so this is the entire activation. The
/// counterpart for closing the gate again is `setDepositsDisabled(true)` via cast.
contract ActivateVault is VaultConfig {

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        VaultMesh memory mesh = _loadMesh();

        require(
            mesh.canonical != address(0),
            "ActivateVault: canonical not set in mesh manifest"
        );

        vm.startBroadcast(
            privKey
        );

        AdminFacet(mesh.canonical).setDepositsDisabled(
            false
        );

        vm.stopBroadcast();

        console2.log("deposits enabled");
        console2.log("product ", _vaultProduct());
        console2.log("network ", _networkName());
        console2.log("diamond ", mesh.canonical);
    }
}
