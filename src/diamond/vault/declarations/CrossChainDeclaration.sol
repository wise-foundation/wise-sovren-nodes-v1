// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Cross-chain bridge shard. `ccipRouter` is the Chainlink CCIP
 * router this diamond sends through and is authenticated as the sole
 * caller of `ccipReceive`; it is set once and never rotated.
 * `crossChainPeer[selector]` is the sibling vault (same underlying
 * stablecoin) on the chain identified by that CCIP `selector`, and
 * `crossChainPeerEnabled[selector]` gates both outbound bridging to
 * and inbound minting from that chain. `crossChainPeerDecimals`
 * records the peer's share decimals so `bridgeToVault` can scale the
 * amount the same way `moveBetweenVaults` does on-chain.
 *
 * `crossChainPeerChangeQueuedAt` backs a propose/execute flow behind
 * `CROSS_CHAIN_PEER_CHANGE_DELAY` (3 days) that mirrors the selector
 * routing timelock: instant while the diamond is still being wired
 * (before `finalizeSetup`), timelocked afterwards, so a compromised
 * master cannot instantly register a malicious peer that would mint
 * unbacked shares. `BRIDGE_GAS_LIMIT` is the callback budget CCIP
 * grants the destination `ccipReceive` for the mint path.
 *
 * Unlike the same-chain mover, peer registration deliberately has NO
 * `_peer != address(this)` guard: the deterministic CREATE3 rollout
 * gives every vault in a mesh the identical canonical address, so
 * `RegisterCrossChainPeers` registers this diamond's own address as
 * the peer for every remote selector. Such a guard would brick the
 * production mesh wiring.
 */
abstract contract CrossChainDeclaration {

    address public ccipRouter;

    mapping(uint64 => address) public crossChainPeer;

    mapping(uint64 => bool) public crossChainPeerEnabled;

    mapping(uint64 => uint8) public crossChainPeerDecimals;

    mapping(uint64 => uint256) public crossChainPeerChangeQueuedAt;

    uint256 internal constant CROSS_CHAIN_PEER_CHANGE_DELAY = 3 days;

    uint256 internal constant BRIDGE_GAS_LIMIT = 200_000;
}
