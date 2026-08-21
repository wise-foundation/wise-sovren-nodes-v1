// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Per-user state: interest accounting.
 */
abstract contract UserStateDeclaration {

    mapping(address => uint256) public lastSyncTimeStamp;

    mapping(address => uint256) public cashedInterest;
}
