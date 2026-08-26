// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Minimal interface a source vault uses to call its
 * destination peer's `mintFromPeer` entry inside the
 * `moveBetweenVaults` flow. `decimals()` is sourced separately via
 * `IERC20Metadata`.
 */
interface IPeerVault {

    function mintFromPeer(
        address _user,
        uint256 _amount
    )
        external;
}
