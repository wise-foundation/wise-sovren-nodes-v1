// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev User-facing surface: deposit, claim/compound variants, the
 * combined deposit-and-{claim,compound} helpers, and interest
 * moving.
 */
contract UserFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function deposit(
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        registerLargeDeposit(msg.sender)
    {
        _deposit(
            _amount
        );
    }

    function claimInterest()
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        returns (uint256)
    {
        return _handleSimpleClaim(
            msg.sender
        );
    }

    function claimInterestPartiallyAndCompound(
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256 claimedAmount)
    {
        claimedAmount = _executePartialClaimAndCompound(
            msg.sender,
            _amount
        );
    }

    function claimInterestExactAmount(
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        returns (uint256)
    {
        return _handleClaimExactAmount(
            msg.sender,
            _amount
        );
    }

    function depositAndClaimInterest(
        uint256 _amount
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
        return _executeDepositAndClaim(
            _amount
        );
    }

    function depositAndCompoundInterest(
        uint256 _amount
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
        return _executeDepositAndCompound(
            _amount
        );
    }

    function moveMyInterestTo(
        uint256 _amount,
        address _target,
        bool _all
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        assignInterest(_target)
        gracePeriodCheck(msg.sender)
    {
        _executeMoveInterestTo(
            msg.sender,
            _target,
            _amount,
            _all
        );
    }

    function compoundInterest()
        public
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        gracePeriodCheck(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256)
    {
        return _handleCompoundInterest(
            msg.sender
        );
    }
}
