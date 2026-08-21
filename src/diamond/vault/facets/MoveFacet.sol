// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Same-chain vault-to-vault move surface. Peer enable is
 * timelocked via `proposePeerVault` + `executePeerVaultChange`
 * behind `PEER_VAULT_CHANGE_DELAY` (3 days); `cancelPeerVaultChange`
 * aborts a pending propose; `removePeerVault` is the instant safety
 * brake for disabling a misbehaving peer. `moveBetweenVaults` is the
 * user entry that banks the user's accrued-but-unclaimed interest
 * into `cashedInterest` via `assignInterest` (claimable on the source,
 * mirroring `bridgeToVault`), burns on the source together with the
 * matching deposit-cap budget, and triggers the peer's mint;
 * `mintFromPeer` is the peer-authenticated counterpart that raises the
 * destination cap and mints the scaled amount; `getMoveableBalance` is
 * the view returning the max user-movable amount (share balance only,
 * matching `getBridgeableBalance`).
 */
contract MoveFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function proposePeerVault(
        address _peer
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposePeerVault(
            _peer
        );
    }

    function executePeerVaultChange(
        address _peer
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyPeerVaultChange(
            _peer
        );
    }

    function cancelPeerVaultChange(
        address _peer
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelPeerVaultChange(
            _peer
        );
    }

    function removePeerVault(
        address _peer
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _removePeerVault(
            _peer
        );
    }

    function moveBetweenVaults(
        address _dstVault,
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        gracePeriodCheck(msg.sender)
        assignInterest(msg.sender)
        registerLargeDeposit(msg.sender)
        returns (uint256 dstAmount)
    {
        dstAmount = _executeMoveOut(
            _dstVault,
            _amount
        );
    }

    function mintFromPeer(
        address _user,
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        assignInterest(_user)
    {
        _executeMintFromPeer(
            _user,
            _amount
        );
    }

    function getMoveableBalance(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return _getMoveableBalance(
            _user
        );
    }
}
