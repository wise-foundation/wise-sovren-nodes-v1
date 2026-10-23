// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {IReferralHub} from "../IReferralHub.sol";

/**
 * @dev Test helper for the hub lever timelock: a grant (allowing a
 * reporter, setting the router, setting a flush or designation source to
 * a chain id) runs after `finalizeSetup` only as the exact call proposed
 * through `proposeLeverChange` at least the selector change delay earlier.
 * `_grant` proposes the call, warps past the delay, executes it from the
 * caller and warps back, so a fixture keeps its clock; the lever state
 * holds no time. `_queue` only proposes and warps past the delay, for a
 * test that asserts the setter's own event on the direct call. The caller
 * must be the hub master.
 */
library HubLeverGrants {

    Vm private constant VM = Vm(
        address(
            uint160(
                uint256(
                    keccak256(
                        "hevm cheat code"
                    )
                )
            )
        )
    );

    uint256 internal constant LEVER_DELAY = 3 days;

    function _grant(
        address _hub,
        bytes memory _call
    )
        internal
    {
        uint256 start = block.timestamp;

        IReferralHub(_hub).proposeLeverChange(
            _call
        );

        VM.warp(
            start + LEVER_DELAY
        );

        (
            bool success,
            bytes memory returnData
        ) = _hub.call(
            _call
        );

        if (success == false) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }

        VM.warp(
            start
        );
    }

    function _queue(
        address _hub,
        bytes memory _call
    )
        internal
    {
        IReferralHub(_hub).proposeLeverChange(
            _call
        );

        VM.warp(
            block.timestamp + LEVER_DELAY
        );
    }
}
