// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesQueueStructs} from "../WiseSovrenNodesQueueStructs.sol";

/**
 * @dev Order-book and linked-list state for the queue surface.
 * Appended after the vault shards so the vault's slot layout stays
 * stable.
 */
abstract contract QueueStateDeclaration is WiseSovrenNodesQueueStructs {

    mapping(uint256 => mapping(int256 => QueMember)) public QueMemberByIdAndIncentive;

    mapping(int256 => uint256) public earliestValidQueMemberByIncentive;

    mapping(int256 => uint256) public currentOrderIdByIncentive;

    mapping(int256 => bool) public incentiveAllowed;

    mapping(int256 => uint256) public activeOrderCountByIncentive;

    uint256 public totalActiveOrders;
}
