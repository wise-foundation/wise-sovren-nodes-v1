// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesHelper} from "../helpers/WiseSovrenNodesHelper.sol";
import {WiseSovrenNodesDeclarations} from "../declarations/WiseSovrenNodesDeclarations.sol";
import {WiseSovrenNodesInitParams} from "../WiseSovrenNodesDiamondStructs.sol";

import {OnlyDelegateCall} from "../../shared/DiamondErrors.sol";

/**
 * @dev Common base for the non-queue concrete vault facets (the queue
 * action facets use the sibling {QueueFacetBase}). Stores
 * `_self = address(this)` so `onlyDelegateCall` can reject direct
 * calls to the facet. Placeholder constructor args satisfy
 * `_validateConstructorInputs`; facet storage is never read because
 * facets are only entered via DELEGATECALL.
 */
abstract contract FacetBase is WiseSovrenNodesHelper {

    address internal immutable _self;

    constructor()
        WiseSovrenNodesDeclarations(
            WiseSovrenNodesInitParams({
                usdAddress: address(0x000000000000000000000000000000000000dEaD),
                thirdPartyAddress: address(0x000000000000000000000000000000000000dEaD),
                workerAddress: address(0x000000000000000000000000000000000000dEaD),
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 1,
                interestRate: 0,
                decimalsValue: 18,
                tokenName: "FACET",
                tokenSymbol: "FACET"
            })
        )
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall()
        internal
        view
    {
        if (address(this) != _self) {
            return;
        }

        revert OnlyDelegateCall();
    }
}
