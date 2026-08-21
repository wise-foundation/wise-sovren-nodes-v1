// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {CCIPConfig} from "../ccip/CCIPConfig.sol";

/// @notice Extends the CCIP config bookkeeping with the per-product vault files. Every path
/// carries the product key (VAULT_PRODUCT env, default "usdc") so the USDC and USDT meshes keep
/// fully parallel configs: config/vault.<product>.<network>.json records a deploy,
/// config/vault_deploy.<product>.<network>.json holds the per-chain init params, and
/// config/vault_mesh.<product>[.testnet].json is the mesh manifest — canonical CREATE3 address,
/// deployer EOA, salt tag, peer decimals and the chain list with per-chain active flags. The
/// testnet manifest is selected automatically by chainid.
abstract contract VaultConfig is CCIPConfig {

    struct VaultMesh {
        address canonical;
        address deployerEOA;
        bytes11 saltTag;
        uint8 peerDecimals;
        string[] chains;
        bool[] active;
    }

    uint256 internal constant SEPOLIA_ID = 11155111;
    uint256 internal constant BASE_SEPOLIA_ID = 84532;
    uint256 internal constant ARBITRUM_SEPOLIA_ID = 421614;
    uint256 internal constant ROBINHOOD_TESTNET_ID = 46630;

    function _vaultProduct()
        internal
        view
        returns (string memory)
    {
        return vm.envOr(
            "VAULT_PRODUCT",
            string("usdc")
        );
    }

    function _isTestnetChain()
        internal
        view
        returns (bool)
    {
        uint256 id = block.chainid;

        return id == SEPOLIA_ID
            || id == BASE_SEPOLIA_ID
            || id == ARBITRUM_SEPOLIA_ID
            || id == ROBINHOOD_TESTNET_ID;
    }

    function _meshPath()
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "config/vault_mesh.",
            _vaultProduct(),
            _isTestnetChain()
                ? ".testnet.json"
                : ".json"
        );
    }

    function _loadMesh()
        internal
        view
        returns (VaultMesh memory mesh)
    {
        string memory json = vm.readFile(
            _meshPath()
        );

        mesh.canonical = vm.parseJsonAddress(json, ".canonical");
        mesh.deployerEOA = vm.parseJsonAddress(json, ".deployerEOA");
        mesh.saltTag = _tagToBytes11(
            vm.parseJsonString(json, ".saltTag")
        );
        mesh.peerDecimals = uint8(
            vm.parseJsonUint(json, ".peerDecimals")
        );
        mesh.chains = vm.parseJsonStringArray(json, ".chains");
        mesh.active = vm.parseJsonBoolArray(json, ".active");

        require(
            mesh.chains.length == mesh.active.length,
            "VaultConfig: mesh chains/active length mismatch"
        );
    }

    function _isActiveInMesh(
        VaultMesh memory _mesh,
        string memory _network
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < _mesh.chains.length; ++i) {
            if (_sameString(_mesh.chains[i], _network)) {
                return _mesh.active[i];
            }
        }

        revert(
            "VaultConfig: network not in mesh manifest"
        );
    }

    function _sameString(
        string memory _a,
        string memory _b
    )
        internal
        pure
        returns (bool)
    {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }

    function _tagToBytes11(
        string memory _tag
    )
        internal
        pure
        returns (bytes11 out)
    {
        bytes memory raw = bytes(_tag);

        if (raw.length > 1 && raw[0] == "0" && raw[1] == "x") {
            raw = vm.parseBytes(
                _tag
            );

            require(
                raw.length == 11,
                "VaultConfig: hex salt tag must be exactly 11 bytes"
            );
        } else {
            require(
                raw.length > 0 && raw.length <= 11,
                "VaultConfig: salt tag must be 1-11 bytes"
            );
        }

        bytes32 word;

        assembly {
            word := mload(add(raw, 32))
        }

        out = bytes11(word);
    }

    function _saveVault(
        string  memory network,
        address diamond,
        address usd,
        address wise
    )
        internal
    {
        string memory obj = "vault";

        vm.serializeAddress(
            obj,
            "diamond",
            diamond
        );

        vm.serializeAddress(
            obj,
            "usd",
            usd
        );

        string memory out = vm.serializeAddress(
            obj,
            "wise",
            wise
        );

        vm.writeJson(
            out,
            string.concat(
                "config/vault.",
                _vaultProduct(),
                ".",
                network,
                ".json"
            )
        );
    }

    function _loadVault(
        string memory network
    )
        internal
        view
        returns (
            address diamond,
            address usd
        )
    {
        string memory json = vm.readFile(
            string.concat(
                "config/vault.",
                _vaultProduct(),
                ".",
                network,
                ".json"
            )
        );

        diamond = vm.parseJsonAddress(json, ".diamond");
        usd     = vm.parseJsonAddress(json, ".usd");
    }

    function _signoffPath(
        string memory _network
    )
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "config/signoff.",
            _network,
            ".",
            _vaultProduct(),
            ".json"
        );
    }

    /// @notice Hard-asserts the frozen sign-off lock still equals every live deploy input for this
    /// product+network. config/signoff.<net>.<product>.json is a tamper-evident copy of the values
    /// a mainnet deploy reads (init params + mesh identity + CCIP endpoint), emitted at the
    /// sign-off gate; any later edit to the deploy, mesh or CCIP config that drifts from the
    /// approved lock aborts the broadcast. `vm.readFile` reverts when the lock is absent, so a
    /// mainnet deploy can never run un-signed. Pure config-to-config comparison — no chain state.
    function _assertSignoff(
        string memory _network
    )
        internal
        view
    {
        string memory so = vm.readFile(
            _signoffPath(_network)
        );

        string memory dep = vm.readFile(
            string.concat(
                "config/vault_deploy.",
                _vaultProduct(),
                ".",
                _network,
                ".json"
            )
        );

        _assertAddrEq(so, ".usd", dep, ".usd", "signoff drift: usd");
        _assertAddrEq(so, ".wise", dep, ".wise", "signoff drift: wise");
        _assertAddrEq(so, ".thirdParty", dep, ".thirdParty", "signoff drift: thirdParty");
        _assertAddrEq(so, ".worker", dep, ".worker", "signoff drift: worker");
        _assertUintEq(so, ".totalDepositCap", dep, ".totalDepositCap", "signoff drift: totalDepositCap");
        _assertUintEq(so, ".interestRate", dep, ".interestRate", "signoff drift: interestRate");
        _assertUintEq(so, ".decimals", dep, ".decimals", "signoff drift: decimals");
        _assertStrEq(so, ".tokenName", dep, ".tokenName", "signoff drift: tokenName");
        _assertStrEq(so, ".tokenSymbol", dep, ".tokenSymbol", "signoff drift: tokenSymbol");

        string memory meshJson = vm.readFile(
            _meshPath()
        );

        _assertAddrEq(so, ".canonical", meshJson, ".canonical", "signoff drift: canonical");
        _assertAddrEq(so, ".deployerEOA", meshJson, ".deployerEOA", "signoff drift: deployerEOA");
        _assertStrEq(so, ".saltTag", meshJson, ".saltTag", "signoff drift: saltTag");

        string memory ccipJson = vm.readFile(
            string.concat(
                "config/ccip.",
                _network,
                ".json"
            )
        );

        _assertAddrEq(so, ".ccipRouter", ccipJson, ".router", "signoff drift: ccipRouter");
        _assertStrEq(so, ".ccipSelector", ccipJson, ".chainSelector", "signoff drift: ccipSelector");
    }

    function _assertAddrEq(
        string memory _a,
        string memory _keyA,
        string memory _b,
        string memory _keyB,
        string memory _msg
    )
        internal
        view
    {
        require(
            vm.parseJsonAddress(_a, _keyA) == vm.parseJsonAddress(_b, _keyB),
            _msg
        );
    }

    function _assertUintEq(
        string memory _a,
        string memory _keyA,
        string memory _b,
        string memory _keyB,
        string memory _msg
    )
        internal
        view
    {
        require(
            vm.parseJsonUint(_a, _keyA) == vm.parseJsonUint(_b, _keyB),
            _msg
        );
    }

    function _assertStrEq(
        string memory _a,
        string memory _keyA,
        string memory _b,
        string memory _keyB,
        string memory _msg
    )
        internal
        view
    {
        require(
            _sameString(
                vm.parseJsonString(_a, _keyA),
                vm.parseJsonString(_b, _keyB)
            ),
            _msg
        );
    }
}
