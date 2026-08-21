// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {DeployWiseSovrenNodesDiamond} from "../diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {VaultConfig} from "./VaultConfig.sol";

/// @notice Prints the canonical CREATE3 addresses for a mesh manifest — pure math, no RPC and no
/// broadcast needed. Fill `deployerEOA` and `saltTag` in config/vault_mesh.<product>.json, run
/// `VAULT_PRODUCT=<product> forge script script/vault/PredictCanonicalAddress.s.sol`, then copy
/// the printed canonical into the manifest. Every deploy preflight re-derives and cross-checks
/// this address (locally and against CreateX itself) before anything is broadcast.
contract PredictCanonicalAddress is DeployWiseSovrenNodesDiamond, VaultConfig {

    function run()
        external
        view
    {
        VaultMesh memory mesh = _loadMesh();

        require(
            mesh.deployerEOA != address(0),
            "PredictCanonicalAddress: set deployerEOA in the mesh manifest first"
        );

        bytes32 salt = makeSalt(
            mesh.deployerEOA,
            mesh.saltTag
        );

        (
            address shim,
            address diamond
        ) = predictDeterministicAddress(
            mesh.deployerEOA,
            salt
        );

        console2.log("mesh file ", _meshPath());
        console2.log("deployer  ", mesh.deployerEOA);
        console2.log("salt      ", vm.toString(salt));
        console2.log("shim      ", shim);
        console2.log("canonical ", diamond);
    }
}
