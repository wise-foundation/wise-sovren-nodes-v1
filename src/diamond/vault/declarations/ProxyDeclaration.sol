// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Proxy-locked balances shard.
 */
abstract contract ProxyDeclaration {

    mapping(address => uint256) public proxyBalance;
}
