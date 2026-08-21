// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Script} from "forge-std/Script.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {RescueFacet} from "../../src/diamond/vault/facets/RescueFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {GraceAccumHookFacet} from "../../src/diamond/vault/facets/GraceAccumHookFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "./WiseSovrenNodesDiamondSelectors.sol";
import {WiseSovrenNodesBootstrap, BootstrapFacets} from "./WiseSovrenNodesBootstrap.sol";

interface ICreateX {

    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    )
        external
        payable
        returns (address);

    function computeCreate3Address(
        bytes32 salt
    )
        external
        view
        returns (address);
}

/**
 * @dev Deploys the WiseSovrenNodes diamond: 19 facets (12 vault, 5
 * queue, 2 grace hooks), the diamond, the selector wiring (propose +
 * execute pre-finalize, no timelock), and `finalizeSetup` in one tx. The
 * diamond registers itself as its own `InterestRateProxy` in its
 * constructor (fixed at deploy, no setter). Init args are passed as a
 * single `WiseSovrenNodesInitParams` struct so the diamond constructor
 * avoids stack-too-deep without needing via-IR.
 *
 * The {Permit2UserFacet} exposes Permit2-based single-tx
 * deposits — the sole signature-deposit path. It works for every
 * supported token (USDC, USDT, USDT0, ...) through the canonical
 * Uniswap Permit2 deployment, whose presence the facet constructor
 * verifies at deploy time.
 *
 * The queue facets fold the former QueContract diamond into this
 * single contract; the diamond custodies queued tokens itself and is
 * its own `InterestRateProxy` so interest accrues to the queueing
 * user rather than the diamond.
 */
contract DeployWiseSovrenNodesDiamond is Script {

    address internal constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    struct DeterministicCfg {
        bytes32 salt;
        address expectedDiamond;
        address ccipRouter;
        address wiseToken;
        bool startDormant;
        address pendingMaster;
    }

    struct DeployedFacets {
        AdminFacet admin;
        ProxyFacet proxy;
        UserFacet user;
        SweepFacet sweep;
        CashedInterestFacet cashedInterest;
        BurnWiseFacet burnWise;
        MoveFacet move;
        BridgeFacet bridge;
        Permit2UserFacet permit2;
        MulticallFacet multicall;
        QueueAdminFacet queueAdmin;
        QueueJoinLeaveFacet queueJoinLeave;
        QueueFulfillFacet queueFulfill;
        QueueViewFacet queueView;
        QueueForecastFacet queueForecast;
        InterestAdminFacet interestAdmin;
        RescueFacet rescue;
        GraceFreezeHookFacet graceFreezeHook;
        GraceAccumHookFacet graceAccumHook;
    }

    function deploy(
        WiseSovrenNodesInitParams memory _params
    )
        public
        returns (
            WiseSovrenNodesDiamond diamond,
            DeployedFacets memory facets
        )
    {
        (
            diamond,
            facets
        ) = deployWithoutFinalize(
            _params
        );

        diamond.finalizeSetup();
    }

    function deployWithoutFinalize(
        WiseSovrenNodesInitParams memory _params
    )
        public
        returns (
            WiseSovrenNodesDiamond diamond,
            DeployedFacets memory facets
        )
    {
        facets = _deployFacets();

        diamond = new WiseSovrenNodesDiamond(
            _params
        );

        _wireSelectors(
            diamond,
            facets
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(facets.graceFreezeHook)
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        AdminFacet(address(diamond)).proposeDepositHookFacet(
            address(facets.graceAccumHook)
        );

        AdminFacet(address(diamond)).executeDepositHookFacetChange();
    }

    /**
     * @dev Deterministic production deploy: the 19 facets stay plain
     * CREATE (their addresses may differ per chain), then the
     * {WiseSovrenNodesBootstrap} shim goes through CreateX CREATE3
     * with `_cfg.salt`, plain-CREATEs the diamond at shim nonce 1
     * (the canonical cross-chain address), wires everything in its
     * constructor and proposes `_cfg.pendingMaster` as owner. The
     * broadcaster must BE `_cfg.pendingMaster` because the final step
     * claims ownership. Left un-finalized, exactly like
     * {deployWithoutFinalize}.
     */
    function deployDeterministic(
        WiseSovrenNodesInitParams memory _params,
        DeterministicCfg memory _cfg
    )
        public
        returns (
            WiseSovrenNodesDiamond diamond,
            DeployedFacets memory facets
        )
    {
        facets = _deployFacets();

        bytes memory initCode = abi.encodePacked(
            type(WiseSovrenNodesBootstrap).creationCode,
            abi.encode(
                _params,
                _toBootstrapFacets(
                    facets
                ),
                _cfg.ccipRouter,
                _cfg.wiseToken,
                _cfg.startDormant,
                _cfg.pendingMaster
            )
        );

        address shim = ICreateX(CREATE_X).deployCreate3(
            _cfg.salt,
            initCode
        );

        diamond = WiseSovrenNodesBootstrap(shim).diamond();

        if (_cfg.expectedDiamond != address(0)) {
            require(
                address(diamond) == _cfg.expectedDiamond,
                "DeployWiseSovrenNodesDiamond: canonical address mismatch"
            );
        }

        diamond.claimOwnership();
    }

    /**
     * @dev Pre-broadcast checks for a deterministic deploy on the
     * current chain: CreateX and canonical Permit2 must have code,
     * the local CREATE3 math must agree with CreateX's own
     * `computeCreate3Address`, and the canonical diamond address must
     * still be empty. Returns the predicted (shim, diamond) pair.
     */
    function preflightDeterministic(
        address _deployer,
        bytes32 _salt
    )
        public
        view
        returns (
            address shim,
            address diamond
        )
    {
        require(
            CREATE_X.code.length > 0,
            "DeployWiseSovrenNodesDiamond: CreateX not deployed on this chain"
        );

        require(
            CANONICAL_PERMIT2.code.length > 0,
            "DeployWiseSovrenNodesDiamond: Permit2 not deployed on this chain"
        );

        (
            shim,
            diamond
        ) = predictDeterministicAddress(
            _deployer,
            _salt
        );

        require(
            ICreateX(CREATE_X).computeCreate3Address(
                guardedSalt(_deployer, _salt)
            ) == shim,
            "DeployWiseSovrenNodesDiamond: local CREATE3 math mismatch"
        );

        require(
            diamond.code.length == 0,
            "DeployWiseSovrenNodesDiamond: canonical address already has code"
        );
    }

    /**
     * @dev Pure address prediction, usable without any RPC: CreateX
     * guards the salt with the deployer, CREATE2-deploys its fixed
     * CREATE3 proxy, the proxy CREATEs the shim at nonce 1, and the
     * shim CREATEs the diamond at nonce 1.
     */
    function predictDeterministicAddress(
        address _deployer,
        bytes32 _salt
    )
        public
        pure
        returns (
            address shim,
            address diamond
        )
    {
        address proxy = _create2Address(
            CREATE_X,
            guardedSalt(_deployer, _salt),
            CREATE3_PROXY_INITCODE_HASH
        );

        shim = _nonceOneAddress(
            proxy
        );

        diamond = _nonceOneAddress(
            shim
        );
    }

    /**
     * @dev Builds the CreateX salt for this deployer and product tag:
     * bytes 0-19 = deployer (permissioned-deploy guard, nobody else
     * can ever claim the address on any chain), byte 20 = 0x00 (no
     * cross-chain redeploy protection, so every chain yields the same
     * address), bytes 21-31 = the product/version tag.
     */
    function makeSalt(
        address _deployer,
        bytes11 _tag
    )
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            bytes20(_deployer)
        ) | (
            bytes32(_tag) >> 168
        );
    }

    /**
     * @dev CreateX permissioned-salt derivation for a salt whose
     * first 20 bytes are the deployer and whose 21st byte is 0x00
     * (msg.sender-guarded, NO cross-chain redeploy protection — the
     * combination that yields the same address on every chain).
     */
    function guardedSalt(
        address _deployer,
        bytes32 _salt
    )
        public
        pure
        returns (bytes32)
    {
        require(
            address(bytes20(_salt)) == _deployer,
            "DeployWiseSovrenNodesDiamond: salt not guarded by deployer"
        );

        require(
            _salt[20] == 0x00,
            "DeployWiseSovrenNodesDiamond: cross-chain protection byte must be 0x00"
        );

        return keccak256(
            abi.encodePacked(
                bytes32(
                    uint256(
                        uint160(_deployer)
                    )
                ),
                _salt
            )
        );
    }

    function _deployFacets()
        internal
        returns (DeployedFacets memory facets)
    {
        facets.admin = new AdminFacet();
        facets.proxy = new ProxyFacet();
        facets.user = new UserFacet();
        facets.sweep = new SweepFacet();
        facets.cashedInterest = new CashedInterestFacet();
        facets.burnWise = new BurnWiseFacet();
        facets.move = new MoveFacet();
        facets.bridge = new BridgeFacet();
        facets.permit2 = new Permit2UserFacet();
        facets.multicall = new MulticallFacet();
        facets.queueAdmin = new QueueAdminFacet();
        facets.queueJoinLeave = new QueueJoinLeaveFacet();
        facets.queueFulfill = new QueueFulfillFacet();
        facets.queueView = new QueueViewFacet();
        facets.queueForecast = new QueueForecastFacet();
        facets.interestAdmin = new InterestAdminFacet();
        facets.rescue = new RescueFacet();
        facets.graceFreezeHook = new GraceFreezeHookFacet();
        facets.graceAccumHook = new GraceAccumHookFacet();
    }

    function _toBootstrapFacets(
        DeployedFacets memory _facets
    )
        internal
        pure
        returns (BootstrapFacets memory)
    {
        return BootstrapFacets({
            admin: address(_facets.admin),
            proxy: address(_facets.proxy),
            user: address(_facets.user),
            sweep: address(_facets.sweep),
            cashedInterest: address(_facets.cashedInterest),
            burnWise: address(_facets.burnWise),
            move: address(_facets.move),
            bridge: address(_facets.bridge),
            permit2: address(_facets.permit2),
            multicall: address(_facets.multicall),
            queueAdmin: address(_facets.queueAdmin),
            queueJoinLeave: address(_facets.queueJoinLeave),
            queueFulfill: address(_facets.queueFulfill),
            queueView: address(_facets.queueView),
            queueForecast: address(_facets.queueForecast),
            interestAdmin: address(_facets.interestAdmin),
            rescue: address(_facets.rescue),
            graceFreezeHook: address(_facets.graceFreezeHook),
            graceAccumHook: address(_facets.graceAccumHook)
        });
    }

    function _create2Address(
        address _deployer,
        bytes32 _salt,
        bytes32 _initCodeHash
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            _deployer,
                            _salt,
                            _initCodeHash
                        )
                    )
                )
            )
        );
    }

    function _nonceOneAddress(
        address _deployer
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"d694",
                            _deployer,
                            hex"01"
                        )
                    )
                )
            )
        );
    }

    function _wireSelectors(
        WiseSovrenNodesDiamond diamond,
        DeployedFacets memory facets
    )
        internal
    {
        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.adminSelectors(),
            address(facets.admin)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.proxySelectors(),
            address(facets.proxy)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.userSelectors(),
            address(facets.user)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.sweepSelectors(),
            address(facets.sweep)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors(),
            address(facets.cashedInterest)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.burnWiseSelectors(),
            address(facets.burnWise)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.moveSelectors(),
            address(facets.move)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.bridgeSelectors(),
            address(facets.bridge)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.permit2Selectors(),
            address(facets.permit2)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.multicallSelectors(),
            address(facets.multicall)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors(),
            address(facets.queueAdmin)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(facets.queueJoinLeave)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors(),
            address(facets.queueFulfill)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueViewSelectors(),
            address(facets.queueView)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.queueForecastSelectors(),
            address(facets.queueForecast)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.interestAdminSelectors(),
            address(facets.interestAdmin)
        );

        diamond.proposeSelectors(
            WiseSovrenNodesDiamondSelectors.rescueSelectors(),
            address(facets.rescue)
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.adminSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.proxySelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.userSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.sweepSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.burnWiseSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.moveSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.bridgeSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.permit2Selectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.multicallSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueViewSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.queueForecastSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.interestAdminSelectors()
        );

        diamond.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors.rescueSelectors()
        );
    }
}
