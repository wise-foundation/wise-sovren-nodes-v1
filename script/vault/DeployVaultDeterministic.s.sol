// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {DeployWiseSovrenNodesDiamond} from "../diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {VaultConfig} from "./VaultConfig.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/// @notice Production deploy at the canonical CREATE3 address. Reads the per-chain params from
/// config/vault_deploy.<product>.<network>.json, the CCIP router from config/ccip.<network>.json
/// and the mesh manifest from config/vault_mesh.<product>.json, then deploys against the REAL
/// underlying (no mock, no queue seed) through {WiseSovrenNodesBootstrap} via CreateX — the
/// diamond lands at the SAME address on every chain of the mesh. Chains flagged inactive in the
/// manifest deploy dormant (deposit gate closed, everything else fully wired). Preflight aborts
/// before any broadcast if CreateX or Permit2 are missing, the predicted address deviates from
/// the manifest canonical, or the canonical slot already has code. A zero thirdParty/worker in
/// the config means the broadcasting deployer is used (both master-changeable afterwards). Once
/// ownership is claimed the premium incentive lanes are opened, which cannot happen inside the
/// shim's own transaction without exceeding the single-transaction gas ceiling. The diamond is
/// left un-finalized: follow with {RegisterCrossChainPeers} then {FinalizeVault}.
contract DeployVaultDeterministic is DeployWiseSovrenNodesDiamond, VaultConfig {

    struct DeployCfg {
        address usd;
        address wise;
        address thirdParty;
        address worker;
        uint256 totalDepositCap;
        uint256 interestRate;
        uint8 decimalsValue;
        string tokenName;
        string tokenSymbol;
    }

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        address deployer = vm.addr(
            privKey
        );

        string memory network = _networkName();

        ChainCfg memory cfg = _loadCfg(
            network
        );

        DeployCfg memory dc = _loadDeployCfg(
            network
        );

        VaultMesh memory mesh = _loadMesh();

        if (mesh.deployerEOA != address(0)) {
            require(
                deployer == mesh.deployerEOA,
                "DeployVaultDeterministic: broadcaster is not the mesh deployer EOA"
            );
        }

        if (_isTestnetChain() == false) {
            _assertSignoff(
                network
            );
        }

        bytes32 salt = makeSalt(
            deployer,
            mesh.saltTag
        );

        (
            ,
            address predicted
        ) = preflightDeterministic(
            deployer,
            salt
        );

        if (mesh.canonical != address(0)) {
            require(
                predicted == mesh.canonical,
                "DeployVaultDeterministic: predicted address != mesh canonical"
            );
        }

        vm.startBroadcast(
            privKey
        );

        (
            WiseSovrenNodesDiamond diamond,
        ) = deployDeterministic(
            _buildParams(
                dc,
                deployer
            ),
            DeterministicCfg({
                salt: salt,
                expectedDiamond: mesh.canonical,
                ccipRouter: cfg.router,
                wiseToken: dc.wise,
                startDormant: _isActiveInMesh(mesh, network) == false,
                pendingMaster: deployer
            })
        );

        vm.stopBroadcast();

        _saveVault(
            network,
            address(diamond),
            dc.usd,
            dc.wise
        );

        console2.log("product    ", _vaultProduct());
        console2.log("network    ", network);
        console2.log("predicted  ", predicted);
        console2.log("diamond    ", address(diamond));
        console2.log("dormant    ", _isActiveInMesh(mesh, network) == false);
        console2.log("usd        ", dc.usd);
        console2.log("router     ", cfg.router);
        console2.log("wise       ", dc.wise);
    }

    function _buildParams(
        DeployCfg memory _dc,
        address _deployer
    )
        internal
        pure
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: _dc.usd,
            thirdPartyAddress: _dc.thirdParty == address(0)
                ? _deployer
                : _dc.thirdParty,
            workerAddress: _dc.worker == address(0)
                ? _deployer
                : _dc.worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: _dc.totalDepositCap,
            interestRate: _dc.interestRate,
            decimalsValue: _dc.decimalsValue,
            tokenName: _dc.tokenName,
            tokenSymbol: _dc.tokenSymbol
        });
    }

    function _loadDeployCfg(
        string memory _network
    )
        internal
        view
        returns (DeployCfg memory dc)
    {
        string memory json = vm.readFile(
            string.concat(
                "config/vault_deploy.",
                _vaultProduct(),
                ".",
                _network,
                ".json"
            )
        );

        dc.usd = vm.parseJsonAddress(json, ".usd");
        dc.wise = vm.parseJsonAddress(json, ".wise");
        dc.thirdParty = vm.parseJsonAddress(json, ".thirdParty");
        dc.worker = vm.parseJsonAddress(json, ".worker");
        dc.totalDepositCap = vm.parseJsonUint(json, ".totalDepositCap");
        dc.interestRate = vm.parseJsonUint(json, ".interestRate");
        dc.decimalsValue = uint8(vm.parseJsonUint(json, ".decimals"));
        dc.tokenName = vm.parseJsonString(json, ".tokenName");
        dc.tokenSymbol = vm.parseJsonString(json, ".tokenSymbol");
    }
}
