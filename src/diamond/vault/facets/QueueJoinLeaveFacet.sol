// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {QueueFacetBase} from "./QueueFacetBase.sol";

/**
 * @dev User-facing join / leave / reduce surface for the queue.
 */
contract QueueJoinLeaveFacet is QueueFacetBase {

    constructor()
        QueueFacetBase()
    {}

    function joinQue(
        uint256 _amount,
        int256 _incentive
    )
        external
        onlyDelegateCall
        whenNotPaused
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory,
            uint256
        )
    {
        if (negativeIncentivesNotAllowed == true) {
            require(
                _incentive >= 0,
                NegativeIncentiveNotAllowed()
            );
        }

        _validateJoinQue(
            _amount,
            _incentive
        );

        (
            QueMember memory member,
            uint256 newId
        ) = _createQueMember(
            _amount,
            _incentive
        );

        _updateJoinQueState(
            _amount,
            _incentive
        );

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensIn(
            _amount
        );

        emit JoinQue(
            msg.sender,
            _amount,
            _incentive,
            newId
        );

        return (
            member,
            newId
        );
    }

    function leaveQue(
        uint256 _queMemberId,
        int256 _incentive
    )
        external
        onlyDelegateCall
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory,
            uint256 leftOverAmount
        )
    {
        _validateLeaveQue(
            _queMemberId,
            _incentive
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];
        leftOverAmount = member.amount;

        _validateMemberCanLeave(
            member
        );

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

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensOut(
            msg.sender,
            leftOverAmount
        );

        emit LeaveQue(
            msg.sender,
            _queMemberId,
            _incentive,
            leftOverAmount
        );

        return (
            member,
            leftOverAmount
        );
    }

    function reduceQueAmount(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _reduceBy
    )
        external
        onlyDelegateCall
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory,
            uint256 leftOverAmount
        )
    {
        _validateReduceAmount(
            _queMemberId,
            _incentive,
            _reduceBy
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_incentive];

        _validateMemberCanReduce(
            member,
            _reduceBy
        );

        _executeReduction(
            member,
            _reduceBy
        );

        _setProxyBenefactor(
            msg.sender
        );

        _transferTokensOut(
            msg.sender,
            _reduceBy
        );

        emit ReduceQueAmount(
            msg.sender,
            _queMemberId,
            _incentive,
            _reduceBy
        );

        return (
            member,
            member.amount
        );
    }

    /**
     * @dev Moves a whole order from `_oldIncentive` into `_newIncentive`
     * without the leave-then-rejoin token round-trip. It composes the
     * exact same internal helpers `leaveQue` + `joinQue` use, in the
     * same order, but omits `_transferTokensOut` / `_transferTokensIn`
     * because the escrowed vault shares never leave the vault — so the
     * final storage is identical to `leaveQue(id, old)` immediately
     * followed by `joinQue(amount, new)`. Being share-movement-free, it
     * never invokes the transfer hook; a swappable `transferHookFacet`
     * (behind its 3-day timelock) does not cover this path.
     */
    function switchQueIncentive(
        uint256 _queMemberId,
        int256 _oldIncentive,
        int256 _newIncentive
    )
        external
        onlyDelegateCall
        whenNotPaused
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory newMember,
            uint256 newId
        )
    {
        require(
            _oldIncentive != _newIncentive,
            SameIncentive()
        );

        if (negativeIncentivesNotAllowed == true) {
            require(
                _newIncentive >= 0,
                NegativeIncentiveNotAllowed()
            );
        }

        _validateLeaveQue(
            _queMemberId,
            _oldIncentive
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_oldIncentive];

        _validateMemberCanLeave(
            member
        );

        uint256 amount = member.amount;

        _validateJoinQue(
            amount,
            _newIncentive
        );

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
            newMember,
            newId
        ) = _createQueMember(
            amount,
            _newIncentive
        );

        _updateJoinQueState(
            amount,
            _newIncentive
        );

        emit SwitchQueIncentive(
            msg.sender,
            _queMemberId,
            _oldIncentive,
            newId,
            _newIncentive,
            amount
        );
    }

    /**
     * @dev Peels `_amount` off an order in `_oldIncentive` into a new
     * order in `_newIncentive`, leaving the remainder in place. Composes
     * the same helpers `reduceQueAmount` + `joinQue` use, minus the
     * token round-trip, so the final storage is identical to
     * `reduceQueAmount(id, old, amount)` followed by
     * `joinQue(amount, new)`. `_amount` must be strictly less than the
     * order amount (a whole-order move must use `switchQueIncentive`).
     * Share-movement-free and hook-free, as above.
     */
    function switchQueIncentivePartial(
        uint256 _queMemberId,
        int256 _oldIncentive,
        int256 _newIncentive,
        uint256 _amount
    )
        external
        onlyDelegateCall
        whenNotPaused
        setProxyBenefactor
        nonReentrant
        returns (
            QueMember memory newMember,
            uint256 newId
        )
    {
        require(
            _oldIncentive != _newIncentive,
            SameIncentive()
        );

        if (negativeIncentivesNotAllowed == true) {
            require(
                _newIncentive >= 0,
                NegativeIncentiveNotAllowed()
            );
        }

        _validateReduceAmount(
            _queMemberId,
            _oldIncentive,
            _amount
        );

        QueMember storage member = QueMemberByIdAndIncentive[_queMemberId][_oldIncentive];

        _validateMemberCanReduce(
            member,
            _amount
        );

        _validateJoinQue(
            _amount,
            _newIncentive
        );

        _executeReduction(
            member,
            _amount
        );

        (
            newMember,
            newId
        ) = _createQueMember(
            _amount,
            _newIncentive
        );

        _updateJoinQueState(
            _amount,
            _newIncentive
        );

        emit SwitchQueIncentivePartial(
            msg.sender,
            _queMemberId,
            _oldIncentive,
            newId,
            _newIncentive,
            _amount
        );
    }
}
