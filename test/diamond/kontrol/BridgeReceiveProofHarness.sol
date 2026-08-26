// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Inherit-harness over the real {WiseSovrenNodesDiamond} for the
 * QLV-5 bridge-receive atomicity proofs. Deploying it runs the genuine
 * constructor; `exposedExecuteBridgeReceive` forwards verbatim into
 * the production `_executeBridgeReceive`, so the router
 * authentication, peer gates, replay guard, payload decode,
 * deposit-cap raise and mint are all the real code under test.
 *
 * The `harness*` writers place single storage fields so the driver can
 * set up a routed lane without walking the propose/execute timelock
 * (which is governance machinery orthogonal to the receive path):
 * `harnessSetRouter` bypasses only the set-once guard of
 * `_setCcipRouter` and `harnessSetPeer` writes the live peer slots the
 * timelock's `executeCrossChainPeerChange` would write. Nothing here
 * alters vault logic.
 */
contract BridgeReceiveProofHarness is WiseSovrenNodesDiamond {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDiamond(
            _params
        )
    {}

    // ---- real receive path (code under test) ----

    function exposedExecuteBridgeReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
    {
        _executeBridgeReceive(
            _message
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
        bool _enabled
    )
        external
    {
        crossChainPeer[_chainSelector] = _peer;
        crossChainPeerEnabled[_chainSelector] = _enabled;
    }

    function harnessSetProcessed(
        bytes32 _messageId
    )
        external
    {
        processedMessageId[_messageId] = true;
    }

    function harnessSetReferralEnabled(
        bool _enabled
    )
        external
    {
        referralEnabled = _enabled;
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
