// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

import {NestedMulticall} from "../../shared/DiamondErrors.sol";

/**
 * @dev Uniswap-style batch executor for the WiseSovrenNodes diamond.
 * Runs several diamond selectors in one transaction, each as a fresh
 * DELEGATECALL back into the dispatcher so `msg.sender` and the
 * storage context are preserved and every inner function keeps its
 * own `nonReentrant` guard.
 *
 * Hardening:
 * - NON-PAYABLE: the implicit callvalue check rejects ETH at entry,
 *   so `msg.value` is always zero and no inner call can observe
 *   leftover value. The payable flows, `bridgeToVault` and
 *   `bridgeToVaultWithReferral`, are issued directly, never through
 *   `multicall`.
 * - NOT `nonReentrant`: `_status` is one shared slot for the diamond
 *   and every facet, so an outer guard would trip the first inner
 *   `nonReentrant` call; each inner call guards itself instead.
 * - Nested multicall is rejected so a batch can never recurse.
 * - Atomic: the first inner revert is bubbled up verbatim and rolls
 *   the whole batch back.
 */
contract MulticallFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function multicall(
        bytes[] calldata _data
    )
        external
        onlyDelegateCall
        returns (bytes[] memory results)
    {
        results = new bytes[](
            _data.length
        );

        bytes4 selfSelector = this.multicall.selector;

        for (uint256 i; i < _data.length;) {

            if (
                _data[i].length >= 4
                    && bytes4(_data[i][:4]) == selfSelector
            ) {
                revert NestedMulticall();
            }

            (
                bool success,
                bytes memory result
            ) = address(this).delegatecall(
                _data[i]
            );

            if (success == false) {
                assembly {
                    revert(
                        add(result, 0x20),
                        mload(result)
                    )
                }
            }

            results[i] = result;

            unchecked {
                ++i;
            }
        }
    }
}
