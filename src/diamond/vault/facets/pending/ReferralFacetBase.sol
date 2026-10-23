// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev ReferralFacetBase: the shared assignment step of the referral
 * deposit facets. A zero or self referrer always reverts; otherwise
 * `(msg.sender, referrer)` goes to the chain ReferralRegistry, which
 * applies the write-once rule and emits the event. An unset pointer
 * reverts ReferralRegistryNotSet and registry reverts bubble into the
 * deposit.
 */
abstract contract ReferralFacetBase is FacetBase {

    function _handleReferral(
        address _referrer
    )
        internal
    {
        require(
            _referrer != ZERO_ADDRESS,
            InvalidValue()
        );

        require(
            _referrer != msg.sender,
            SelfReferral()
        );

        address registry = referralRegistry;

        require(
            registry != ZERO_ADDRESS,
            ReferralRegistryNotSet()
        );

        IReferralRegistry(registry).assignReferrer(
            msg.sender,
            _referrer
        );
    }
}
