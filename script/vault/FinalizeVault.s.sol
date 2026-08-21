// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {VaultConfig} from "./VaultConfig.sol";
import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";

/// @notice Locks the diamond down after the mesh is wired: `finalizeSetup` flips `initialized`,
/// so from here on both selector changes and cross-chain peer changes are subject to the 3-day
/// timelock. Run once per chain after {RegisterCrossChainPeers}.
contract FinalizeVault is VaultConfig {

    function run()
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

        WiseSovrenNodesDiamond(payable(diamond)).finalizeSetup();

        vm.stopBroadcast();
    }
}
