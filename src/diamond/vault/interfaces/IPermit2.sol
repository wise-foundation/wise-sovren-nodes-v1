// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Minimal Permit2 surface — only the `permitTransferFrom` path
 * used by the Permit2 deposit facet. Permit2 is deployed at the
 * canonical CREATE2 address `0x000000000022D473030F116dDEE9F6B43aC78BA3`
 * on every chain it supports (incl. Ethereum mainnet and Arbitrum).
 *
 * Used to onboard tokens that lack EIP-2612 `permit`: the user
 * one-time approves Permit2 for the ERC20, then signs a typed
 * `PermitTransferFrom` per deposit; the facet calls
 * `permitTransferFrom` which validates the signature and pulls
 * tokens in a single atomic step.
 */
interface IPermit2 {

    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata _signature
    )
        external;
}
