// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The ReferralRegistry surface a vault calls: the write-once assign,
 * the plain and flip-aware referrer reads, the same-chain carry mailbox,
 * the bridge pair read and merge, the payout designation read, the seed
 * latch and the sync quarantine flag. The engine reaches the mutating and
 * cohort reads through guarded calls; the admin surface is operated on the
 * registry directly.
 */
interface IReferralRegistry {

    function assignReferrer(
        address _user,
        address _referrer
    )
        external;

    function referrerOf(
        address _user
    )
        external
        view
        returns (address);

    function effectiveReferrerOf(
        address _user,
        address _vault
    )
        external
        view
        returns (address);

    function getReferrerPair(
        address _user
    )
        external
        view
        returns (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        );

    function mergeReferrer(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        external;

    function stageCarry(
        address _dstVault,
        address _user,
        uint256[] calldata _payload
    )
        external;

    function consumeCarry(
        address _srcVault,
        address _user
    )
        external
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        );

    function getPayoutDesignation(
        address _owner
    )
        external
        view
        returns (
            address payout,
            uint256 stamp
        );

    function seedsLatched()
        external
        view
        returns (bool);

    function syncPeerQuarantined(
        uint64 _chainSelector
    )
        external
        view
        returns (bool);
}
