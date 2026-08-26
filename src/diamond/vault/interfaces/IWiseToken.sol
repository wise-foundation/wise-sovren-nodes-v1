// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Subset of the WISE token surface the burn facet calls. The
 * mainnet WISE token exposes a permissionless `burn(uint256)` that
 * decreases the caller's balance and totalSupply; the concrete token
 * address is configured per deployment via `setWiseToken`.
 */
interface IWiseToken {

    function burn(
        uint256 _amount
    )
        external;

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);
}
