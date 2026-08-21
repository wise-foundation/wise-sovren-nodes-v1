// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Errors for the diamond proxy machinery — selector routing
 * and lifecycle.
 */

error FacetNotFound();

error AlreadyInitialized();

error NoSelectorChangeQueued();

error SelectorTimelockNotElapsed();

error OnlyDelegateCall();

error NestedMulticall();
