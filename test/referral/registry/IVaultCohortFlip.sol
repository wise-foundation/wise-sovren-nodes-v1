// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The two vault calls of a referrer flip: `getAttributedContribution`
 * decides which vaults get a marker (a failed probe marks), and
 * `receiveReferrerFlip` relocates the user's book credit. A disarmed vault
 * holding credit for the user reverts, so the registry restores the marker
 * and the flip stays pokeable.
 */
interface IVaultCohortFlip {

    function getAttributedContribution(
        address _user
    )
        external
        view
        returns (uint256);

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external;
}
