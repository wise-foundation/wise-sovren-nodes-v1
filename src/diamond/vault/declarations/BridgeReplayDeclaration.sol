// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Bridge-hardening tail shard. `processedMessageId[id]` records
 * every CCIP message this vault has already minted against, so a
 * re-delivered `ccipReceive` can never mint twice — a defense-in-depth
 * idempotency guard layered on top of CCIP's own exactly-once delivery.
 *
 * `proposedCrossChainPeer[selector]` and `proposedCrossChainPeerDecimals`
 * stage a pending cross-chain peer so that repointing an already-enabled
 * lane is bound by the same `CROSS_CHAIN_PEER_CHANGE_DELAY` timelock as a
 * first-time enable: the live `crossChainPeer` mapping only moves on
 * `executeCrossChainPeerChange`, never on `proposeCrossChainPeer`.
 *
 * Appended last in the declarations linearisation so it takes fresh tail
 * slots and moves no pre-existing slot.
 */
abstract contract BridgeReplayDeclaration {

    mapping(bytes32 => bool) public processedMessageId;

    mapping(uint64 => address) public proposedCrossChainPeer;

    mapping(uint64 => uint8) public proposedCrossChainPeerDecimals;
}
