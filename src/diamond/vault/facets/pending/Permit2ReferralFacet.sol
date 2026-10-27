// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IPermit2} from "../../interfaces/IPermit2.sol";

import {FacetBase} from "../FacetBase.sol";
import {ReferralFacetBase} from "./ReferralFacetBase.sol";

/**
 * @dev Permit2ReferralFacet: the referral variants of the three Permit2
 * deposit entrypoints. The Permit2 pull mirrors Permit2UserFacet line for
 * line; the referral step runs first in every entrypoint.
 */
contract Permit2ReferralFacet is ReferralFacetBase {

    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    constructor()
        FacetBase()
    {
        if (address(PERMIT2).code.length == 0) {
            revert Permit2NotDeployed();
        }
    }

    function depositWithPermit2WithReferral(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature,
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

        _checkValuesDeposit(
            _amount
        );

        _pullViaPermit2(
            _amount,
            _nonce,
            _deadline,
            _signature
        );

        _recordDeposit(
            _amount
        );
    }

    function depositAndClaimInterestWithPermit2WithReferral(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature,
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

        _checkValuesDeposit(
            _amount
        );

        _pullViaPermit2(
            _amount,
            _nonce,
            _deadline,
            _signature
        );

        _recordDeposit(
            _amount
        );

        return _handleSimpleClaim(
            msg.sender
        );
    }

    function depositAndCompoundInterestWithPermit2WithReferral(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature,
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

        _checkValuesDeposit(
            _amount
        );

        _pullViaPermit2(
            _amount,
            _nonce,
            _deadline,
            _signature
        );

        _recordDeposit(
            _amount
        );

        return _handleCompoundInterest(
            msg.sender
        );
    }

    function _pullViaPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    )
        internal
    {
        PERMIT2.permitTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({
                    token: address(USD_TOKEN),
                    amount: _amount
                }),
                nonce: _nonce,
                deadline: _deadline
            }),
            IPermit2.SignatureTransferDetails({
                to: thirdPartyAddress,
                requestedAmount: _amount
            }),
            msg.sender,
            _signature
        );
    }
}
