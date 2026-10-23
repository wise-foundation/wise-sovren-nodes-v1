// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";
import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";

import {OnlyDelegateCall} from "../../../src/diamond/shared/DiamondErrors.sol";

/**
 * @dev ReferralHubFacetBase: the delegatecall guard of the routed hub
 * facets; a direct call to a facet address reverts OnlyDelegateCall.
 */
abstract contract ReferralHubFacetBase is ReferralHubDeclarations {

    address internal immutable _self;

    constructor()
        OwnableMaster(
            msg.sender
        )
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(
            address(this) != _self,
            OnlyDelegateCall()
        );
        _;
    }
}
