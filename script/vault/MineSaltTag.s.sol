// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {DeployWiseSovrenNodesDiamond} from "../diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {VaultConfig} from "./VaultConfig.sol";

/// @notice Grinds CREATE3 product salt tags until the canonical diamond address starts with the
/// 0x7e1E ("TELE") brand prefix shared by every product mesh — pure math, no RPC and no
/// broadcast. Fill `deployerEOA` in config/vault_mesh.<product>.json, run
/// `VAULT_PRODUCT=<product> forge script script/vault/MineSaltTag.s.sol`, paste the printed tag
/// into the manifest and re-run {PredictCanonicalAddress} to record the canonical. Only bytes
/// 21-31 of the salt are ground: bytes 0-19 stay the deployer EOA (CreateX permissioned-deploy
/// guard — nobody else can ever claim the address on any chain) and byte 20 stays 0x00
/// (chain-invariant), so a mined salt keeps the full squat protection. `MINE_DEPLOYER` overrides
/// the manifest EOA; `MINE_START` / `MINE_COUNT` window the counter for batched runs.
contract MineSaltTag is DeployWiseSovrenNodesDiamond, VaultConfig {

    bytes2 internal constant BRAND_PREFIX = 0x7e1e;

    uint256 internal constant DEFAULT_COUNT = 262_144;

    function run()
        external
        view
    {
        VaultMesh memory mesh = _loadMesh();

        address deployer = vm.envOr(
            "MINE_DEPLOYER",
            mesh.deployerEOA
        );

        require(
            deployer != address(0),
            "MineSaltTag: set deployerEOA in the mesh manifest or MINE_DEPLOYER"
        );

        uint256 start = vm.envOr(
            "MINE_START",
            uint256(0)
        );

        uint256 count = vm.envOr(
            "MINE_COUNT",
            DEFAULT_COUNT
        );

        for (uint256 i = start; i < start + count; ++i) {

            bytes11 tag = bytes11(
                uint88(i)
            );

            bytes32 salt = makeSalt(
                deployer,
                tag
            );

            (
                address shim,
                address diamond
            ) = predictDeterministicAddress(
                deployer,
                salt
            );

            if (bytes2(bytes20(diamond)) == BRAND_PREFIX) {

                console2.log("mesh file ", _meshPath());
                console2.log("deployer  ", deployer);
                console2.log("tries     ", i - start + 1);
                console2.log("tag       ", vm.toString(abi.encodePacked(tag)));
                console2.log("salt      ", vm.toString(salt));
                console2.log("shim      ", shim);
                console2.log("canonical ", diamond);

                return;
            }
        }

        revert(
            "MineSaltTag: no match in window - raise MINE_COUNT or bump MINE_START"
        );
    }
}
