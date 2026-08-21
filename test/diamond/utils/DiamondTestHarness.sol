// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {BurnWiseFacet} from "../../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {Permit2UserFacet} from "../../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MulticallFacet} from "../../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../../src/diamond/vault/facets/QueueViewFacet.sol";
import {QueueForecastFacet} from "../../../src/diamond/vault/facets/QueueForecastFacet.sol";
import {InterestAdminFacet} from "../../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {RescueFacet} from "../../../src/diamond/vault/facets/RescueFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

/**
 * @dev Shared scaffolding for diamond tests. Owns the deploy +
 * wire + finalize sequence and the per-facet selector wiring so
 * individual test files don't duplicate ~95 lines of boilerplate
 * (and so a new facet only requires updating the harness).
 *
 * Inheritors call `_deployDiamond(_usd)` from their `setUp`. The
 * test contract becomes the master because the diamond
 * constructor records `msg.sender` and the test contract is the
 * one calling `new WiseSovrenNodesDiamond(...)`.
 *
 * Cap is fixed at 1e9 * 1e6 (1 billion units of a 6-decimal
 * token). Every supported underlying on the production chains
 * (USDC, USDT, USDT0) is 6 decimals, so the constant covers
 * every current use case.
 */
abstract contract DiamondTestHarness is Test {

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal thirdPty = address(0xCAFE);
    address internal worker = address(0xD00D);

    uint256 internal constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 internal constant INTEREST_RATE = 2000;
    uint8 internal constant DEFAULT_DECIMALS = 6;

    function _deployDiamond(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _deployDiamondAtRate(
            _usd,
            INTEREST_RATE
        );
    }

    function _deployDiamondAtRate(
        address _usd,
        uint256 _rate
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamondWithRate(
            _usd,
            _rate
        );

        _wireAllFacets(
            d
        );

        d.finalizeSetup();
    }

    function _deployDiamondWithQueue(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _deployDiamondWithQueueAtRate(
            _usd,
            INTEREST_RATE
        );
    }

    function _deployDiamondWithQueueAtRate(
        address _usd,
        uint256 _rate
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamondWithRate(
            _usd,
            _rate
        );

        _wireAllFacets(
            d
        );

        _wireQueueFacets(
            d
        );

        d.finalizeSetup();
    }

    function _newDiamond(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamondWithRate(
            _usd,
            INTEREST_RATE
        );
    }

    function _newDiamondWithRate(
        address _usd,
        uint256 _rate
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        _ensurePermit2();

        d = new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: _usd,
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: TOTAL_DEPOSIT_CAP,
                interestRate: _rate,
                decimalsValue: DEFAULT_DECIMALS,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "wsnUSDC"
            })
        );
    }

    function _wireAllFacets(
        WiseSovrenNodesDiamond d
    )
        internal
    {
        _wireOne(
            d,
            address(new AdminFacet()),
            WiseSovrenNodesDiamondSelectors.adminSelectors()
        );

        _wireOne(
            d,
            address(new ProxyFacet()),
            WiseSovrenNodesDiamondSelectors.proxySelectors()
        );

        _wireOne(
            d,
            address(new UserFacet()),
            WiseSovrenNodesDiamondSelectors.userSelectors()
        );

        _wireOne(
            d,
            address(new SweepFacet()),
            WiseSovrenNodesDiamondSelectors.sweepSelectors()
        );

        _wireOne(
            d,
            address(new CashedInterestFacet()),
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        _wireOne(
            d,
            address(new BurnWiseFacet()),
            WiseSovrenNodesDiamondSelectors.burnWiseSelectors()
        );

        _wireOne(
            d,
            address(new MoveFacet()),
            WiseSovrenNodesDiamondSelectors.moveSelectors()
        );

        _wireOne(
            d,
            address(new Permit2UserFacet()),
            WiseSovrenNodesDiamondSelectors.permit2Selectors()
        );

        _wireOne(
            d,
            address(new MulticallFacet()),
            WiseSovrenNodesDiamondSelectors.multicallSelectors()
        );

        _wireOne(
            d,
            address(new InterestAdminFacet()),
            WiseSovrenNodesDiamondSelectors.interestAdminSelectors()
        );

        _wireOne(
            d,
            address(new RescueFacet()),
            WiseSovrenNodesDiamondSelectors.rescueSelectors()
        );
    }

    function _wireQueueFacets(
        WiseSovrenNodesDiamond d
    )
        internal
    {
        _wireOne(
            d,
            address(new QueueAdminFacet()),
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors()
        );

        _wireOne(
            d,
            address(new QueueJoinLeaveFacet()),
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _wireOne(
            d,
            address(new QueueFulfillFacet()),
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors()
        );

        _wireOne(
            d,
            address(new QueueViewFacet()),
            WiseSovrenNodesDiamondSelectors.queueViewSelectors()
        );

        _wireOne(
            d,
            address(new QueueForecastFacet()),
            WiseSovrenNodesDiamondSelectors.queueForecastSelectors()
        );
    }

    function _wireOne(
        WiseSovrenNodesDiamond d,
        address _facet,
        bytes4[] memory _sels
    )
        internal
    {
        d.proposeSelectors(
            _sels,
            _facet
        );

        d.executeSelectorChanges(
            _sels
        );
    }

    /**
     * @dev {Permit2UserFacet}'s constructor reverts if no
     * contract is present at the canonical Permit2 address. Tests
     * that don't need real Permit2 behaviour still trigger the
     * check because the harness deploys all 7 facets; etch a
     * minimal STOP at the canonical slot so the check passes. Tests
     * needing a real-ish Permit2 (the Permit2 facet test) etch a
     * full mock BEFORE calling `_deployDiamond` — that prior etch
     * is preserved here.
     */
    function _ensurePermit2()
        internal
    {
        if (CANONICAL_PERMIT2.code.length > 0) {
            return;
        }

        vm.etch(
            CANONICAL_PERMIT2,
            hex"00"
        );
    }
}
