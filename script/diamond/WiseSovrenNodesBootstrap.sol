// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "./WiseSovrenNodesDiamondSelectors.sol";

struct BootstrapFacets {
    address admin;
    address proxy;
    address user;
    address sweep;
    address cashedInterest;
    address burnWise;
    address move;
    address bridge;
    address permit2;
    address multicall;
    address queueAdmin;
    address queueJoinLeave;
    address queueFulfill;
    address queueView;
    address queueForecast;
    address interestAdmin;
    address rescue;
    address graceFreezeHook;
    address graceAccumHook;
}

/**
 * @dev One-shot bootstrap shim for the deterministic multichain
 * deploy. The shim itself is deployed through CreateX CREATE3, so its
 * address depends only on the deployer EOA and a salt — never on
 * bytecode or constructor args. Its constructor then plain-CREATEs
 * the diamond as its first creation (nonce 1), which pins the diamond
 * to `keccak256(rlp([shim, 1]))` — the same canonical address on
 * every chain, while the per-chain constructor args (underlying,
 * name, caps) remain free to differ.
 *
 * The indirection exists because the diamond binds
 * `OwnableMaster(msg.sender)` at construction: created directly via a
 * factory, its master would be an inert CREATE3 proxy and the
 * selector wiring could never run. Created by this shim, the shim is
 * master for the length of its own constructor — long enough to wire
 * all selectors (instant pre-finalize), install the grace-freeze
 * transfer hook and the grace-accumulator deposit hook (both instant
 * pre-finalize; the accumulator ships dormant since
 * `depositAccumWindow` is never set), grant the pending master as a
 * sweeper and revoke the shim's own constructor-seeded grant (the
 * diamond constructor seeds worker, third party and `msg.sender` —
 * here the shim), point the CCIP router,
 * set the WISE token when configured, close the deposit gate on
 * dormant chains, and propose the deployer as the real owner. The
 * deployer
 * claims ownership in the next transaction and the shim is inert
 * from then on. `finalizeSetup` deliberately stays a separate,
 * later phase so peers can still be wired instantly.
 */
contract WiseSovrenNodesBootstrap {

    WiseSovrenNodesDiamond public immutable diamond;

    constructor(
        WiseSovrenNodesInitParams memory _params,
        BootstrapFacets memory _facets,
        address _ccipRouter,
        address _wiseToken,
        bool _startDormant,
        address _pendingMaster
    ) {
        WiseSovrenNodesDiamond deployed = new WiseSovrenNodesDiamond(
            _params
        );

        _wireSelectors(
            deployed,
            _facets
        );

        AdminFacet(address(deployed)).proposeTransferHookFacet(
            _facets.graceFreezeHook
        );

        AdminFacet(address(deployed)).executeTransferHookFacetChange();

        AdminFacet(address(deployed)).proposeDepositHookFacet(
            _facets.graceAccumHook
        );

        AdminFacet(address(deployed)).executeDepositHookFacetChange();

        AdminFacet(address(deployed)).setSweeper(
            _pendingMaster,
            true
        );

        AdminFacet(address(deployed)).setSweeper(
            address(this),
            false
        );

        BridgeFacet(address(deployed)).setCcipRouter(
            _ccipRouter
        );

        if (_wiseToken != address(0)) {
            AdminFacet(address(deployed)).setWiseToken(
                _wiseToken
            );
        }

        if (_startDormant == true) {
            AdminFacet(address(deployed)).setDepositsDisabled(
                true
            );
        }

        deployed.proposeOwner(
            _pendingMaster
        );

        diamond = deployed;
    }

    function _wireSelectors(
        WiseSovrenNodesDiamond _diamond,
        BootstrapFacets memory _facets
    )
        internal
    {
        _wireOne(
            _diamond,
            _facets.admin,
            WiseSovrenNodesDiamondSelectors.adminSelectors()
        );

        _wireOne(
            _diamond,
            _facets.proxy,
            WiseSovrenNodesDiamondSelectors.proxySelectors()
        );

        _wireOne(
            _diamond,
            _facets.user,
            WiseSovrenNodesDiamondSelectors.userSelectors()
        );

        _wireOne(
            _diamond,
            _facets.sweep,
            WiseSovrenNodesDiamondSelectors.sweepSelectors()
        );

        _wireOne(
            _diamond,
            _facets.cashedInterest,
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        _wireOne(
            _diamond,
            _facets.burnWise,
            WiseSovrenNodesDiamondSelectors.burnWiseSelectors()
        );

        _wireOne(
            _diamond,
            _facets.move,
            WiseSovrenNodesDiamondSelectors.moveSelectors()
        );

        _wireOne(
            _diamond,
            _facets.bridge,
            WiseSovrenNodesDiamondSelectors.bridgeSelectors()
        );

        _wireOne(
            _diamond,
            _facets.permit2,
            WiseSovrenNodesDiamondSelectors.permit2Selectors()
        );

        _wireOne(
            _diamond,
            _facets.multicall,
            WiseSovrenNodesDiamondSelectors.multicallSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueAdmin,
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueJoinLeave,
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueFulfill,
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueView,
            WiseSovrenNodesDiamondSelectors.queueViewSelectors()
        );

        _wireOne(
            _diamond,
            _facets.queueForecast,
            WiseSovrenNodesDiamondSelectors.queueForecastSelectors()
        );

        _wireOne(
            _diamond,
            _facets.interestAdmin,
            WiseSovrenNodesDiamondSelectors.interestAdminSelectors()
        );

        _wireOne(
            _diamond,
            _facets.rescue,
            WiseSovrenNodesDiamondSelectors.rescueSelectors()
        );
    }

    function _wireOne(
        WiseSovrenNodesDiamond _diamond,
        address _facet,
        bytes4[] memory _sels
    )
        internal
    {
        _diamond.proposeSelectors(
            _sels,
            _facet
        );

        _diamond.executeSelectorChanges(
            _sels
        );
    }
}
