// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Inherit-harness over the real {WiseSovrenNodesDiamond} for the
 * BRG-5 bridge room-conservation proofs. Deploying it runs the
 * genuine constructor; `exposedExecuteBridgeReceive` and
 * `exposedExecuteBridgeOut` forward verbatim into the production
 * `_executeBridgeReceive` / `_executeBridgeOut`, so the router
 * authentication, peer gates, replay guard, burn/mint and the
 * `_raiseDepositCap` / `_reduceDepositCap` cap relocation are all the
 * real code under test.
 *
 * The `harness*` writers place single storage fields so the driver can
 * set up a routed lane and an arbitrary cap/supply pre-state without
 * walking the propose/execute timelock (which is governance machinery
 * orthogonal to the room law): `harnessSetRouter` bypasses only the
 * set-once guard of `_setCcipRouter`, `harnessSetPeer` writes the
 * live peer slots the timelock's `executeCrossChainPeerChange` would
 * write (including the peer decimals the out-path scales by), and
 * `harnessSetCap` writes `totalDepositCap` directly so a symbolic
 * pre-state cap lands without walking `setTotalDepositCap`'s
 * supply floor. Nothing here alters vault logic.
 */
contract BridgeHeadroomProofHarness is WiseSovrenNodesDiamond {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDiamond(
            _params
        )
    {}

    // ---- real bridge paths (code under test) ----

    function exposedExecuteBridgeReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
    {
        _executeBridgeReceive(
            _message
        );
    }

    function exposedExecuteBridgeOut(
        uint64 _destChainSelector,
        uint256 _amount,
        bytes calldata _referralData
    )
        external
        payable
        returns (
            uint256 dstAmount,
            bytes32 messageId
        )
    {
        return _executeBridgeOut(
            _destChainSelector,
            _amount,
            _referralData
        );
    }

    // ---- narrow storage writers (proof scaffolding only) ----

    function harnessSetRouter(
        address _router
    )
        external
    {
        ccipRouter = _router;
    }

    function harnessSetPeer(
        uint64 _chainSelector,
        address _peer,
        uint8 _peerDecimals,
        bool _enabled
    )
        external
    {
        crossChainPeer[_chainSelector] = _peer;
        crossChainPeerDecimals[_chainSelector] = _peerDecimals;
        crossChainPeerEnabled[_chainSelector] = _enabled;
    }

    function harnessSetCap(
        uint256 _cap
    )
        external
    {
        totalDepositCap = _cap;
    }

    function harnessMint(
        address _user,
        uint256 _amount
    )
        external
    {
        _mint(
            _user,
            _amount
        );
    }

    function harnessSetLastSync(
        address _user,
        uint256 _timestamp
    )
        external
    {
        lastSyncTimeStamp[_user] = _timestamp;
    }
}
