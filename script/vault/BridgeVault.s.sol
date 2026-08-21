// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "./VaultConfig.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

/// @notice Bridges `amount` vault shares from the current chain's diamond to the peer on
/// `destChainSelector`, paying the CCIP fee in native gas quoted via `quoteBridgeFee`. Burns on
/// the source, keeps unclaimed interest here, and mints on the destination when CCIP delivers.
/// Track the returned messageId on https://ccip.chain.link. Reference flow for the UI.
contract BridgeVault is VaultConfig {

    function run(
        uint64  destChainSelector,
        uint256 amount
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

        uint256 fee = BridgeFacet(address(diamond)).quoteBridgeFee(
            destChainSelector,
            amount
        );

        vm.startBroadcast(
            privKey
        );

        (
            uint256 dstAmount,
            bytes32 messageId
        ) = BridgeFacet(address(diamond)).bridgeToVault{value: fee}(
            destChainSelector,
            amount
        );

        vm.stopBroadcast();

        console2.log("dest selector", destChainSelector);
        console2.log("src amount   ", amount);
        console2.log("dst amount   ", dstAmount);
        console2.log("native fee   ", fee);
        console2.logBytes32(messageId);
    }
}
