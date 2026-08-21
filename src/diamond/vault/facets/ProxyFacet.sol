// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Surface for the registered `InterestRateProxy` (the queue
 * diamond, in production). Every function is proxy-gated.
 */
contract ProxyFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function triggerAssignInterest(
        address _user
    )
        external
        onlyDelegateCall
    {
        _validateInterestRateProxy();

        _assignInterest(
            _user
        );
    }

    function increaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external
        onlyDelegateCall
    {
        _validateInterestRateProxy();

        _increaseProxyBalance(
            _proxyUser,
            _amount
        );
    }

    function decreaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        external
        onlyDelegateCall
        assignInterest(_proxyUser)
    {
        _validateInterestRateProxy();

        _decreaseProxyBalance(
            _proxyUser,
            _amount
        );
    }
}
