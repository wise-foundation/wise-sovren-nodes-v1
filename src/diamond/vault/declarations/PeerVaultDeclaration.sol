// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Peer-vault shard. `peerVault[other] == true` means this
 * diamond accepts `mintFromPeer` calls from `other` and lets its
 * users move tokens out to `other`. Enabling a peer is timelocked
 * via `proposePeerVault` + `executePeerVaultChange` behind a 3-day
 * `PEER_VAULT_CHANGE_DELAY` (matching the worker-rotation shape
 * from Step 15) so a compromised master cannot instantly register
 * a malicious peer that would mint unbacked tokens. Disabling is
 * instant via `removePeerVault` as a safety brake — removing a
 * misbehaving peer should not wait three days.
 */
abstract contract PeerVaultDeclaration {

    mapping(address => bool) public peerVault;

    mapping(address => uint256) public peerVaultChangeQueuedAt;

    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;
}
