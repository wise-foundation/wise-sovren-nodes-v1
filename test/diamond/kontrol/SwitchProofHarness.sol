// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesQueueHelper} from "../../../src/diamond/vault/helpers/WiseSovrenNodesQueueHelper.sol";
import {WiseSovrenNodesDeclarations} from "../../../src/diamond/vault/declarations/WiseSovrenNodesDeclarations.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Inherit-harness over the real queue helper chain
 * ({WiseSovrenNodesQueueHelper} → … → {WiseSovrenNodesDeclarations}). Deploying
 * it runs the genuine constructor, so `InterestRateProxy == address(this)`
 * and the full production queue + interest + ERC20 code is exercised.
 *
 * `exposedSwitchCore` replays the exact internal-helper sequence that
 * {QueueJoinLeaveFacet.switchQueIncentive} performs (the facet body
 * is only that sequence plus validation + the event), so a symbolic
 * (Kontrol) or fuzz (Foundry) driver proves properties against the real
 * mutation code. `harnessSeedOrder` places a live order via the real
 * insert path; the narrow `harnessSet*` writers place single storage
 * fields. Nothing here alters vault logic.
 */
contract SwitchProofHarness is WiseSovrenNodesQueueHelper {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDeclarations(
            _params
        )
    {}

    // ---- real insert path (seed a live order) ----

    function harnessSeedOrder(
        uint256 _amount,
        int256 _incentive
    )
        external
        returns (uint256 id)
    {
        (
            ,
            id
        ) = _createQueMember(
            _amount,
            _incentive
        );

        _updateJoinQueState(
            _amount,
            _incentive
        );
    }

    // ---- real switch mutation sequence (code under test) ----

    function exposedSwitchCore(
        uint256 _queMemberId,
        int256 _oldIncentive,
        int256 _newIncentive
    )
        external
        returns (uint256 newId)
    {
        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_oldIncentive];

        uint256 amount = member.amount;

        _updateCurrentOrderIfNeeded(
            _queMemberId,
            _oldIncentive,
            member
        );

        _finalizeMemberRemoval(
            _queMemberId,
            member,
            _oldIncentive,
            true
        );

        (
            ,
            newId
        ) = _createQueMember(
            amount,
            _newIncentive
        );

        _updateJoinQueState(
            amount,
            _newIncentive
        );
    }

    // ---- narrow storage writers (proof scaffolding only) ----

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
