// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {DeployWiseSovrenNodesDiamond} from "../diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {VaultConfig} from "./VaultConfig.sol";

/// @notice Grinds CREATE3 product salt tags until the canonical diamond address opens with the
/// brand prefix — pure math, no RPC and no broadcast. Fill `deployerEOA` in
/// config/vault_mesh.<product>.json, run `VAULT_PRODUCT=<product> forge script
/// script/vault/MineSaltTag.s.sol`, choose one of the printed candidates, paste its tag into the
/// manifest and re-run {PredictCanonicalAddress} to record the canonical. Only bytes 21-31 of the
/// salt are ground: bytes 0-19 stay the deployer EOA (CreateX permissioned-deploy guard — nobody
/// else can ever claim the address on any chain) and byte 20 stays 0x00 (chain-invariant), so a
/// mined salt keeps the full squat protection. `MINE_DEPLOYER` overrides the manifest EOA;
/// `MINE_START` / `MINE_COUNT` window the counter for batched runs; `MINE_MATCHES` caps how many
/// candidates are printed.
///
/// The prefix reads "Sov" in the digits hexadecimal allows: S as 5, o as 0, v approximated by b.
/// Nothing of "Sovren" past that can be spelled at all, since r, e and n have no digit that
/// resembles them in sequence, so three nibbles is where the name runs out and further nibbles
/// would only pin arbitrary characters. Three constrained nibbles land roughly one address in
/// 4096, so a default window yields many candidates and the nicest full address is chosen by eye
/// at sign-off rather than taking the first hit.
contract MineSaltTag is DeployWiseSovrenNodesDiamond, VaultConfig {

    uint256 internal constant BRAND_PREFIX = 0x50b;

    uint256 internal constant BRAND_PREFIX_SHIFT = 148;

    uint256 internal constant DEFAULT_COUNT = 262_144;

    uint256 internal constant DEFAULT_MATCHES = 20;

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

        uint256 wanted = vm.envOr(
            "MINE_MATCHES",
            DEFAULT_MATCHES
        );

        console2.log("mesh file ", _meshPath());
        console2.log("deployer  ", deployer);

        uint256 found;

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

            if (uint160(diamond) >> BRAND_PREFIX_SHIFT == BRAND_PREFIX) {

                console2.log("---");
                console2.log("tries     ", i - start + 1);
                console2.log("tag       ", vm.toString(abi.encodePacked(tag)));
                console2.log("salt      ", vm.toString(salt));
                console2.log("shim      ", shim);
                console2.log("canonical ", diamond);

                found++;

                if (found == wanted) {
                    return;
                }
            }
        }

        require(
            found > 0,
            "MineSaltTag: no match in window - raise MINE_COUNT or bump MINE_START"
        );
    }
}
