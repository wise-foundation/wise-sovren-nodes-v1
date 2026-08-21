// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Master-only escape hatch for tokens stranded on the vault by
 * direct wallet transfers. Strictly excluded: the underlying
 * `USD_TOKEN`, whose vault balance backs interest claims and the
 * sweep-buffer reservation (its surplus leaves only through
 * `sweepOverhang` to the worker), and the vault's own share token.
 * Every other balance is invisible to vault accounting and can be
 * returned to its sender.
 *
 * No reentrancy guard: the single external call happens after all
 * checks, the function writes no vault storage, and the caller is
 * the master.
 */
contract RescueFacet is FacetBase {

    using SafeERC20 for IERC20;

    constructor()
        FacetBase()
    {}

    function rescueToken(
        address _token,
        address _to,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
    {
        require(
            _token != address(USD_TOKEN)
                && _token != address(this),
            ProtectedToken()
        );

        require(
            _to != address(0),
            InvalidValue()
        );

        IERC20(_token).safeTransfer(
            _to,
            _amount
        );

        emit TokenRescued(
            _token,
            _to,
            _amount
        );
    }
}
