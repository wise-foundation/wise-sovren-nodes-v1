// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The reporter surface of the referral hub used by a flush on the hub
 * chain itself, where the vault is the allowed reporter and delivers by
 * direct call. Reverts bubble so a local delivery is never dropped.
 */
interface IReferralFlushHub {

    function reportSelf(
        address _referrer,
        uint256[] calldata _selfRuns
    )
        external;

    function deliverCrumbs(
        address _referrer,
        address _deliverer,
        uint256[] calldata _weeks,
        uint256[] calldata _words
    )
        external;

    function deliverGap(
        address _referrer,
        address _deliverer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        external;
}
