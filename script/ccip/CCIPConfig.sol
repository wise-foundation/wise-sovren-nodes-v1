// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/Script.sol";

/// @notice Shared CCIP config + deployed-address bookkeeping for the CCT bridge scripts.
/// @dev Reads config/ccip.<network>.json (CCIP infra, sourced from the CCIP Directory) and
/// reads/writes config/deployed.<network>.json (our token + pool). Network is derived from
/// block.chainid so the scripts need no extra args beyond --rpc-url.
abstract contract CCIPConfig is Script {

    struct ChainCfg {
        string  network;
        uint64  chainSelector;
        address router;
        address rmnProxy;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address link;
    }

    function _networkName()
        internal
        view
        returns (string memory)
    {
        uint256 id = block.chainid;

        if (id == 11155111) return "sepolia";
        if (id == 84532)    return "base_sepolia";
        if (id == 421614)   return "arbitrum_sepolia";
        if (id == 46630)    return "robinhood_testnet";
        if (id == 1)        return "mainnet";
        if (id == 8453)     return "base";
        if (id == 42161)    return "arbitrum";
        if (id == 4663)     return "robinhood";

        return vm.toString(
            id
        );
    }

    /// @notice The chain mesh that the current network belongs to.
    function _meshNetworks()
        internal
        view
        returns (string[] memory mesh)
    {
        uint256 id = block.chainid;

        mesh = new string[](4);

        if (
            id == 11155111
            || id == 84532
            || id == 421614
            || id == 46630
        ) {
            mesh[0] = "sepolia";
            mesh[1] = "base_sepolia";
            mesh[2] = "arbitrum_sepolia";
            mesh[3] = "robinhood_testnet";
            return mesh;
        }

        mesh[0] = "mainnet";
        mesh[1] = "base";
        mesh[2] = "arbitrum";
        mesh[3] = "robinhood";
    }

    function _loadCfg(
        string memory network
    )
        internal
        view
        returns (ChainCfg memory cfg)
    {
        string memory json = vm.readFile(
            string.concat(
                "config/ccip.",
                network,
                ".json"
            )
        );

        cfg.network                   = network;
        cfg.chainSelector             = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    json,
                    ".chainSelector"
                )
            )
        );
        cfg.router                    = vm.parseJsonAddress(json, ".router");
        cfg.rmnProxy                  = vm.parseJsonAddress(json, ".rmnProxy");
        cfg.tokenAdminRegistry        = vm.parseJsonAddress(json, ".tokenAdminRegistry");
        cfg.registryModuleOwnerCustom = vm.parseJsonAddress(json, ".registryModuleOwnerCustom");
        cfg.link                      = vm.parseJsonAddress(json, ".link");
    }

    function _saveDeployed(
        string  memory network,
        address token,
        address pool
    )
        internal
    {
        string memory obj = "deployed";

        vm.serializeAddress(
            obj,
            "token",
            token
        );

        string memory out = vm.serializeAddress(
            obj,
            "pool",
            pool
        );

        vm.writeJson(
            out,
            string.concat(
                "config/deployed.",
                network,
                ".json"
            )
        );
    }

    function _loadDeployed(
        string memory network
    )
        internal
        view
        returns (address token, address pool)
    {
        string memory json = vm.readFile(
            string.concat(
                "config/deployed.",
                network,
                ".json"
            )
        );

        token = vm.parseJsonAddress(json, ".token");
        pool  = vm.parseJsonAddress(json, ".pool");
    }
}
