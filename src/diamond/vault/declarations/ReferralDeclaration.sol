// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Referral / cross-chain-data tail shard. The bridge wire format
 * always carries a `bytes referralData` field (empty by default), so a
 * future referral system can transport data cross-chain without another
 * message-format change. `referralEnabled` gates whether an inbound
 * bridge that carries a non-empty `referralData` surfaces it via the
 * `BridgeReferral` event; it defaults to `false`, so until master flips
 * it the bridge behaves exactly as before and the payload is ignored.
 *
 * `bridgeGasLimit` overrides the destination `ccipReceive` callback
 * budget when non-zero, so a future referral consumer that writes
 * storage on arrival can raise the budget with no redeploy; `0` (the
 * unset default) falls back to `BRIDGE_GAS_LIMIT`. `MAX_REFERRAL_BYTES`
 * caps the payload so a caller cannot inflate the message past the CCIP
 * size ceiling or the destination gas budget, and `MAX_BRIDGE_GAS_LIMIT`
 * bounds the configurable budget.
 *
 * Appended last in the declarations linearisation so it takes fresh tail
 * slots and moves no pre-existing slot. `referralEnabled` and
 * `bridgeGasLimit` pack into a single slot.
 */
abstract contract ReferralDeclaration {

    bool public referralEnabled;

    uint64 public bridgeGasLimit;

    uint256 internal constant MAX_REFERRAL_BYTES = 256;

    uint256 internal constant MAX_BRIDGE_GAS_LIMIT = 5_000_000;

    uint256 internal constant LEGACY_BRIDGE_PAYLOAD_LENGTH = 64;
}
