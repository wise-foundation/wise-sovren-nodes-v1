// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IPermit2} from "../interfaces/IPermit2.sol";

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Permit2-enabled deposit facet for ERC20s that do not
 * implement EIP-2612 — notably USDT on Ethereum mainnet.
 *
 * Flow: user makes a one-time `approve(PERMIT2, type(uint256).max)`
 * on the underlying token, then signs a typed `PermitTransferFrom`
 * per deposit. The facet forwards the signature to Permit2 which
 * validates it and pulls tokens directly to `thirdPartyAddress`
 * in one atomic call. Because the pull happens through Permit2
 * the signature itself can only authorize that exact amount once,
 * keyed by `_nonce`.
 *
 * Permit2 is the canonical Uniswap deployment at
 * `0x000000000022D473030F116dDEE9F6B43aC78BA3`, same address on
 * every supported chain (Ethereum mainnet, Arbitrum, etc.). The
 * constructor reverts with {Permit2NotDeployed} if no contract
 * is present at that address on the target chain — prevents
 * deploying a facet whose entrypoints would always revert and
 * silently consume user gas.
 */
contract Permit2UserFacet is FacetBase {

    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    constructor()
        FacetBase()
    {
        if (address(PERMIT2).code.length == 0) {
            revert Permit2NotDeployed();
        }
    }

    function depositWithPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(msg.sender)
        registerLargeDeposit(msg.sender)
    {
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

    function depositAndClaimInterestWithPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
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

    function depositAndCompoundInterestWithPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
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
