// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesAdminHelper} from "./WiseSovrenNodesAdminHelper.sol";

/**
 * @dev Proxy-balance accounting. Inc/dec are caller-gated to
 * `InterestRateProxy` at the facet boundary.
 */
abstract contract WiseSovrenNodesProxyHelper is WiseSovrenNodesAdminHelper {

    function _increaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        internal
    {
        proxyBalance[_proxyUser] += _amount;

        emit ProxyBalanceIncreased(
            _proxyUser,
            _amount
        );
    }

    function _decreaseProxyBalance(
        address _proxyUser,
        uint256 _amount
    )
        internal
    {
        proxyBalance[_proxyUser] -= _amount;

        emit ProxyBalanceDecreased(
            _proxyUser,
            _amount
        );
    }
}
