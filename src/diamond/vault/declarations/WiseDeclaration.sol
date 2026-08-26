// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev WISE-token shard. `WISE_TOKEN` is the token `burnWise` burns.
 * It lives in storage rather than a bytecode constant so the diamond
 * can be deployed on chains that have no WISE token — there it stays
 * `address(0)` and `burnWise` reverts `WiseTokenNotSet` — and later be
 * pointed at a bridged WISE by master through `setWiseToken`. Appended
 * last so it takes a fresh tail slot and moves no pre-existing slot.
 */
abstract contract WiseDeclaration {

    address public WISE_TOKEN;
}
