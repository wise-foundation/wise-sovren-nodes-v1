// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubCheckpoints} from "./ReferralHubCheckpoints.sol";
import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev ReferralHubCheckpointsFacet: the week bucket reads of the hub.
 * Views carry no delegatecall guard; a direct call reads zeros.
 */
contract ReferralHubCheckpointsFacet is ReferralHubCheckpoints {

    constructor()
        OwnableMaster(
            msg.sender
        )
    {}
}
