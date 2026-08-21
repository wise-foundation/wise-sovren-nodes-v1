// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";

/// @notice Read-only pre-deploy check that the frozen sign-off lock still matches every live
/// deploy input for VAULT_PRODUCT on this network. Runs the exact same assertion
/// {DeployVaultDeterministic} runs before it broadcasts, so an operator can confirm the sign-off
/// holds without sending a transaction (and a drift is caught before any gas is spent). Sends no
/// transactions.
///
///   VAULT_PRODUCT=usdc forge script script/vault/VerifySignoff.s.sol:VerifySignoff --rpc-url mainnet
contract VerifySignoff is VaultConfig {

    function run()
        external
        view
    {
        string memory network = _networkName();

        _assertSignoff(
            network
        );

        console2.log("sign-off verified");
        console2.log("product ", _vaultProduct());
        console2.log("network ", network);
        console2.log("lock    ", _signoffPath(network));
    }
}
