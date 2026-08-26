// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Diamond-routing storage: selector→facet table, proposal
 * queue, and the `initialized` latch. New shards are appended after
 * it in the declarations linearisation, so its slots stay stable
 * across future facet additions.
 */
abstract contract SelectorRoutingDeclaration {

    mapping(bytes4 => address) public selectorToFacet;

    mapping(bytes4 => address) public proposedSelectorFacet;

    mapping(bytes4 => uint256) public selectorChangeQueuedAt;

    bool public initialized;

    uint256 internal constant SELECTOR_CHANGE_DELAY = 3 days;
}
