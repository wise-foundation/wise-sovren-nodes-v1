// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesQueueHelper} from "../../../src/diamond/vault/helpers/WiseSovrenNodesQueueHelper.sol";
import {WiseSovrenNodesDeclarations} from "../../../src/diamond/vault/declarations/WiseSovrenNodesDeclarations.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Minimal concrete stablecoin for the fulfillment lemmas: the
 * real `_processOrder` pays the queued member over `USD_TOKEN`, so
 * the proof needs a token with code. Kept deliberately tiny (no OZ
 * inheritance) so the symbolic engine carries as little extra state
 * as possible. Return values satisfy SafeERC20.
 */
contract MockStable {

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        balanceOf[_to] += _amount;
    }

    function approve(
        address _spender,
        uint256 _amount
    )
        external
        returns (bool)
    {
        allowance[msg.sender][_spender] = _amount;

        return true;
    }

    function transfer(
        address _to,
        uint256 _amount
    )
        external
        returns (bool)
    {
        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;

        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        external
        returns (bool)
    {
        allowance[_from][msg.sender] -= _amount;
        balanceOf[_from] -= _amount;
        balanceOf[_to] += _amount;

        return true;
    }
}

/**
 * @dev Inherit-harness over the real queue helper chain
 * ({WiseSovrenNodesQueueHelper} → … → {WiseSovrenNodesDeclarations}),
 * following the {SwitchProofHarness} pattern. Deploying it runs the
 * genuine constructor, so `InterestRateProxy == address(this)` and the
 * full production queue + interest + ERC20 code is exercised.
 *
 * `harnessSeedOrder` inserts a live order via the real insert path
 * (`_createQueMember` + `_updateJoinQueState`) and mints the escrowed
 * shares straight to the vault, reproducing the end-state of a real
 * `joinQue` (the facet body is that sequence plus validation, the
 * share pull-in and the event).
 *
 * `exposedLeaveCore` replays the exact mutation sequence of
 * {QueueJoinLeaveFacet.leaveQue} - cursor advance, removal with
 * accounting, share pay-out - and `exposedProcessOrder` calls the real
 * `_processOrder` fulfillment path verbatim, USD leg included. Nothing
 * here alters vault logic.
 */
contract CursorProofHarness is WiseSovrenNodesQueueHelper {

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

        _mint(
            address(this),
            _amount
        );
    }

    // ---- real leave mutation sequence (code under test) ----

    function exposedLeaveCore(
        uint256 _queMemberId,
        int256 _incentive
    )
        external
        returns (uint256 leftOverAmount)
    {
        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        leftOverAmount = member.amount;

        _updateCurrentOrderIfNeeded(
            _queMemberId,
            _incentive,
            member
        );

        _finalizeMemberRemoval(
            _queMemberId,
            member,
            _incentive,
            true
        );

        _transferTokensOut(
            msg.sender,
            leftOverAmount
        );
    }

    // ---- real fulfillment path (code under test) ----

    function exposedProcessOrder(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        external
    {
        _processOrder(
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );
    }

    // ---- narrow storage writers (proof scaffolding only) ----

    function harnessSetLastSync(
        address _user,
        uint256 _timestamp
    )
        external
    {
        lastSyncTimeStamp[_user] = _timestamp;
    }
}
