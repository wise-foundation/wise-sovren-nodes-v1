// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {ReferralFacetBase} from "./ReferralFacetBase.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev ReferralFacet: the referral variants of the three plain deposit
 * entrypoints, with the modifier stacks of UserFacet; the referral
 * assignment runs first, then the flow is the plain deposit. `getReferrerOf`
 * reads through the registry pointer (zero while it is unset) with a plain
 * staticcall that may revert, because a view revert blocks nothing.
 */
contract ReferralFacet is ReferralFacetBase {

    constructor()
        FacetBase()
    {}

    function getReferrerOf(
        address _user
    )
        external
        view
        returns (address)
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {
            return ZERO_ADDRESS;
        }

        return IReferralRegistry(registry).referrerOf(
            _user
        );
    }

    function depositWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        registerLargeDeposit(msg.sender)
    {
        _handleReferral(
            _referrer
        );

        _deposit(
            _amount
        );
    }

    function depositAndClaimInterestWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256)
    {
        _handleReferral(
            _referrer
        );

        return _executeDepositAndClaim(
            _amount
        );
    }

    function depositAndCompoundInterestWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256)
    {
        _handleReferral(
            _referrer
        );

        return _executeDepositAndCompound(
            _amount
        );
    }
}
