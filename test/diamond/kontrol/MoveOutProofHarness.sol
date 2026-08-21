// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Inherit-harness over the real {WiseSovrenNodesDiamond} for the
 * MOV-1 same-chain move-out cap-relocation proof. Deploying it runs
 * the genuine constructor; `exposedExecuteMoveOut` forwards verbatim
 * into the production `_executeMoveOut`, so the peer/balance guards,
 * the burn, the `_reduceDepositCap` cap relocation and the
 * `IPeerVault.mintFromPeer` call are all the real code under test.
 * Pending interest is deliberately above this entry point: the facet's
 * `assignInterest` modifier banks it into `cashedInterest` without
 * minting, so the internal helper proven here must touch no interest
 * state and no supply beyond the burn.
 *
 * The `harness*` writers place single storage fields so the driver can
 * seed a registered same-chain peer, a symbolic deposit cap and the
 * mover's balance and last-sync stamp — so a year of pending interest
 * stands ready to expose any residual compound mint.
 * `harnessSetPeerVault` writes the live slot the timelock's
 * `executePeerVaultChange` would write. Nothing here alters vault
 * logic.
 */
contract MoveOutProofHarness is WiseSovrenNodesDiamond {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDiamond(
            _params
        )
    {}

    // ---- real move-out path (code under test) ----

    function exposedExecuteMoveOut(
        address _dstVault,
        uint256 _amount
    )
        external
        returns (uint256)
    {
        return _executeMoveOut(
            _dstVault,
            _amount
        );
    }

    // ---- narrow storage writers (proof scaffolding only) ----

    function harnessSetPeerVault(
        address _peer,
        bool _enabled
    )
        external
    {
        peerVault[_peer] = _enabled;
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
