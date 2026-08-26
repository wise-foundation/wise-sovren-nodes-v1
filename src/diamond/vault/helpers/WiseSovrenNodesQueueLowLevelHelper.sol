// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WiseSovrenNodesHelper} from "./WiseSovrenNodesHelper.sol";
import {WiseSovrenNodesIncentiveLadder} from "../WiseSovrenNodesIncentiveLadder.sol";

/**
 * @dev Low-level queue helper: validators, linked-list manipulation,
 * token movement, proxy-benefactor and proxy-balance bridges, order
 * traversal primitives, and discount math. In the merged diamond the
 * vault is its own custodian, so the former external bridges into the
 * vault are direct internal calls.
 *
 * The lane arrays are read from {WiseSovrenNodesIncentiveLadder} so
 * the tiers the solver walks are the same tiers the constructor
 * marks allowed.
 */
abstract contract WiseSovrenNodesQueueLowLevelHelper is WiseSovrenNodesHelper {

    using SafeERC20 for IERC20;

    function _setProxyBenefactor(
        address _user
    )
        internal
    {
        _updateProxyBenefactor(
            _user
        );
    }

    function _validateJoinQue(
        uint256 _amount,
        int256 _incentive
    )
        internal
        view
    {
        require(
            _amount > 0,
            ZeroAmount()
        );

        _requireIncentiveAllowed(
            _incentive
        );

        _requireMinDeposit(
            _amount
        );
    }

    function _transferTokensIn(
        uint256 _amount
    )
        internal
    {
        _moveVaultTokens(
            msg.sender,
            address(this),
            _amount
        );
    }

    function _moveVaultTokens(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        _assignInterest(
            _from
        );

        _assignInterest(
            _to
        );

        _runTransferHook(
            _from,
            _to
        );

        _transfer(
            _from,
            _to,
            _amount
        );
    }

    function _createQueMember(
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (
            QueMember memory member,
            uint256 newId
        )
    {
        newId = earliestValidQueMemberByIncentive[_incentive];
        QueMember storage hole = QueMemberByIdAndIncentive[newId][_incentive];

        uint256 prevId = hole.tailPointer;
        uint256 nextId = newId + 1;

        member = QueMember({
            member: msg.sender,
            amount: _amount,
            tailPointer: prevId,
            headPointer: nextId
        });

        QueMemberByIdAndIncentive[newId][_incentive] = member;

        if (prevId < earliestValidQueMemberByIncentive[_incentive]) {
            QueMemberByIdAndIncentive[prevId][_incentive].headPointer = newId;
        }

        QueMemberByIdAndIncentive[nextId][_incentive].tailPointer = newId;

        unchecked {
            ++earliestValidQueMemberByIncentive[_incentive];
        }
    }

    function _updateJoinQueState(
        uint256 _amount,
        int256 _incentive
    )
        internal
    {
        _changeProxyAccounting(
            _increaseProxyBalance,
            msg.sender,
            _amount
        );

        totalActiveOrders++;
        activeOrderCountByIncentive[_incentive]++;
    }

    function _validateLeaveQue(
        uint256 _queMemberId,
        int256 _incentive
    )
        internal
        view
    {
        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        _requireIncentiveAllowed(
            _incentive
        );
    }

    function _hasNoOrdersToProcess(
        uint256[] memory _orders,
        uint256[] memory _partials
    )
        internal
        pure
        returns (bool)
    {
        return _orders.length == 0 && _partials.length == 0;
    }

    function _validateReduceAmount(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _reduceBy
    )
        internal
        view
    {
        require(
            _reduceBy > 0,
            ZeroAmount()
        );

        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        _requireIncentiveAllowed(
            _incentive
        );
    }

    function _executeReduction(
        QueMember storage _member,
        uint256 _reduceBy
    )
        internal
    {
        _changeProxyAccounting(
            _decreaseProxyBalance,
            msg.sender,
            _reduceBy
        );

        _member.amount -= _reduceBy;

        _requireMinDeposit(
            _member.amount
        );
    }

    function _changeProxyAccounting(
        function(address, uint256) internal _changeProxyBalance,
        address _user,
        uint256 _amount
    )
        internal
    {
        _updateProxyBenefactor(
            _user
        );

        _assignInterest(
            _user
        );

        _changeProxyBalance(
            _user,
            _amount
        );
    }

    function _validateMemberCanReduce(
        QueMember storage _member,
        uint256 _reduceBy
    )
        internal
        view
    {
        require(
            _member.member == msg.sender,
            NotMember()
        );

        require(
            _reduceBy < _member.amount,
            AmountTooHigh()
        );
    }

    function _validateMemberCanLeave(
        QueMember storage _member
    )
        internal
        view
    {
        require(
            _member.member == msg.sender,
            NotMember()
        );
    }

    function _updateCurrentOrderIfNeeded(
        uint256 _queMemberId,
        int256 _incentive,
        QueMember storage _member
    )
        internal
    {
        if (_queMemberId == currentOrderIdByIncentive[_incentive]) {
            currentOrderIdByIncentive[_incentive] = _member.headPointer;
        }
    }

    function _updateLinkedListPointers(
        uint256 _queMemberId,
        QueMember storage _member,
        int256 _incentive
    )
        internal
    {
        if (_queMemberId == currentOrderIdByIncentive[_incentive]) {
            QueMemberByIdAndIncentive[_member.headPointer][_incentive].tailPointer = _member.headPointer;
            return;
        }

        QueMemberByIdAndIncentive[_member.tailPointer][_incentive].headPointer = _member.headPointer;
        QueMemberByIdAndIncentive[_member.headPointer][_incentive].tailPointer = _member.tailPointer;
    }

    function _transferTokensOut(
        address _to,
        uint256 _amount
    )
        internal
    {
        _moveVaultTokens(
            address(this),
            _to,
            _amount
        );
    }

    function _requireIncentiveAllowed(
        int256 _incentive
    )
        internal
        view
    {
        require(
            incentiveAllowed[_incentive],
            IncentiveNotAllowed()
        );
    }

    function _requireMinDeposit(
        uint256 _amount
    )
        internal
        view
    {
        require(
            _amount >= minDepositAmount,
            AmountTooLow()
        );
    }

    function _requireValidMemberId(
        uint256 _id,
        int256 _incentive
    )
        internal
        view
    {
        require(
            _id < earliestValidQueMemberByIncentive[_incentive],
            QueMemberIdTooHigh()
        );
    }

    function _validateOrderProcessing(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        internal
        view
    {
        _requireValidMemberId(
            _queMemberId,
            _incentive
        );

        if (_isFullFulfill) {
            require(
                QueMemberByIdAndIncentive[_queMemberId][_incentive].amount > 0,
                ZeroAmount()
            );
        } else {
            require(
                _amount > 0,
                ZeroAmount()
            );

            require(
                _amount < QueMemberByIdAndIncentive[_queMemberId][_incentive].amount,
                AmountTooHigh()
            );
        }

        _requireIncentiveAllowed(
            _incentive
        );

        require(
            currentOrderIdByIncentive[_incentive] == _queMemberId,
            OrderNotReady()
        );
    }

    function _executeTransfers(
        address _cashedMember,
        uint256 _amount,
        uint256 _discountedAmount
    )
        internal
    {
        USD_TOKEN.safeTransferFrom(
            msg.sender,
            _cashedMember,
            _discountedAmount
        );

        _transferTokensOut(
            msg.sender,
            _amount
        );
    }

    function _executeTransfersFromContract(
        address _cashedMember,
        uint256 _amount,
        uint256 _discountedAmount
    )
        internal
    {
        USD_TOKEN.safeTransfer(
            _cashedMember,
            _discountedAmount
        );

        _transferTokensOut(
            msg.sender,
            _amount
        );
    }

    function _initializeNegativeIncentivesArray()
        internal
        pure
        returns (int256[] memory)
    {
        return WiseSovrenNodesIncentiveLadder.negativeIncentives();
    }

    function _initializeAllIncentivesArray()
        internal
        pure
        returns (int256[] memory)
    {
        return WiseSovrenNodesIncentiveLadder.allIncentives();
    }

    function _initializePositiveIncentivesArray()
        internal
        pure
        returns (int256[] memory)
    {
        return WiseSovrenNodesIncentiveLadder.positiveIncentives();
    }

    function _calculateDiscountFactor(
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        return _incentive >= 0
            ? PRECISION_RATE - uint256(_incentive)
            : PRECISION_RATE + uint256(-_incentive);
    }

    function _isEmptyOrder(
        QueMember storage _entry
    )
        internal
        view
        returns (bool)
    {
        return _entry.amount == 0;
    }

    function _moveToNextOrder(
        QueMember storage _entry,
        int256 _incentive
    )
        internal
        view
        returns (
            uint256 newCurrent,
            uint256 newNextId
        )
    {
        newCurrent = _entry.headPointer;

        if (newCurrent == 0 || newCurrent >= earliestValidQueMemberByIncentive[_incentive]) {
            newNextId = earliestValidQueMemberByIncentive[_incentive];
            newCurrent = earliestValidQueMemberByIncentive[_incentive];
        } else {
            newNextId = newCurrent;
        }
    }

    function _shouldContinuePlanTraversal(
        uint256 _amountLeft,
        PlanVars memory _v,
        int256 _incentive,
        uint256 _maxOrdersToConsider,
        uint256 _considerationLimit
    )
        internal
        view
        returns (bool)
    {
        return _amountLeft > 0
            && _v.current < earliestValidQueMemberByIncentive[_incentive]
            && _v.fullIndex < _v.arraySize
            && (_maxOrdersToConsider == 0 || _v.ordersConsidered < _considerationLimit);
    }

    function _buildFinalOrderArrays(
        PlanVars memory _v,
        uint256[] memory _tempFull
    )
        internal
        pure
        returns (
            uint256[] memory fullOrderIds,
            uint256[] memory partialOrderIds
        )
    {
        fullOrderIds = new uint256[](_v.fullIndex);

        for (uint256 i; i < _v.fullIndex; i++) {
            fullOrderIds[i] = _tempFull[i];
        }

        if (_v.hasPartial) {
            partialOrderIds = new uint256[](1);
            partialOrderIds[0] = _v.partialId;
        } else {
            partialOrderIds = new uint256[](0);
        }
    }

    function _initializePlanVars(
        uint256 _activeCount,
        uint256 _maxOrdersToConsider
    )
        internal
        pure
        returns (PlanVars memory v)
    {
        if (_maxOrdersToConsider == 0) {
            v.arraySize = _activeCount;
        } else {
            v.arraySize = _activeCount < _maxOrdersToConsider
                ? _activeCount
                : _maxOrdersToConsider;
        }
    }

    function _initializeSolveVars()
        internal
        view
        returns (SolveForAmountVars memory v)
    {
        v.incs = _initializePositiveIncentivesArray();
        v.tempIncentives = new int256[](totalActiveOrders);
        v.tempOrders = new uint256[](totalActiveOrders);
        v.tempPartials = new uint256[](totalActiveOrders);
    }

    function _processFullOrdersForIncentive(
        SolveForAmountVars memory _v,
        uint256[] memory _fullIds,
        int256 _incentive,
        uint256 _remainingAmount
    )
        internal
        view
        returns (uint256 newRemainingAmount)
    {
        newRemainingAmount = _remainingAmount;

        for (uint256 j; j < _fullIds.length; j++) {
            if (newRemainingAmount == 0) {
                break;
            }

            uint256 id = _fullIds[j];
            uint256 amt = QueMemberByIdAndIncentive[id][_incentive].amount;

            if (amt == 0 || amt > newRemainingAmount) {
                continue;
            }

            _v.tempIncentives[_v.orderIndex] = _incentive;
            _v.tempOrders[_v.orderIndex] = id;
            _v.orderIndex++;
            newRemainingAmount -= amt;
        }
    }

    function _processPartialOrderForIncentive(
        SolveForAmountVars memory _v,
        uint256[] memory _partialIds,
        int256 _incentive
    )
        internal
        pure
    {
        if (_partialIds.length != 0) {
            _v.tempPartials[_v.partialIndex] = _partialIds[0];
            _v.tempIncentives[_v.orderIndex + _v.partialIndex] = _incentive;
            _v.partialIndex++;
        }
    }

    function _buildSolveResults(
        SolveForAmountVars memory _v
    )
        internal
        pure
        returns (
            int256[] memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        )
    {
        incentives = new int256[](_v.orderIndex + _v.partialIndex);
        orders = new uint256[](_v.orderIndex);
        partials = new uint256[](_v.partialIndex);

        for (uint256 k; k < _v.orderIndex; k++) {
            incentives[k] = _v.tempIncentives[k];
            orders[k] = _v.tempOrders[k];
        }

        for (uint256 l; l < _v.partialIndex; l++) {
            incentives[_v.orderIndex + l] = _v.tempIncentives[_v.orderIndex + l];
            partials[l] = _v.tempPartials[l];
        }
    }

    function _collectOrdersForIncentive(
        int256 _currentIncentive,
        address _user,
        bool _checkUser,
        QueMember[] memory _tempOrders,
        int256[] memory _tempIncentives,
        uint256 _currentIndex
    )
        internal
        view
        returns (uint256 newIndex)
    {
        newIndex = _currentIndex;
        uint256 maxIdForIncentive = earliestValidQueMemberByIncentive[_currentIncentive];

        for (uint256 id = 0; id < maxIdForIncentive; id++) {
            QueMember storage member = QueMemberByIdAndIncentive[id][_currentIncentive];

            if (_shouldIncludeOrder(member, _user, _checkUser)) {
                _tempOrders[newIndex] = member;
                _tempIncentives[newIndex] = _currentIncentive;
                newIndex++;
            }
        }
    }

    function _shouldIncludeOrder(
        QueMember storage _member,
        address _user,
        bool _checkUser
    )
        internal
        view
        returns (bool)
    {
        return _checkUser
            ? (_member.member == _user && _member.amount > 0)
            : (_member.member != ZERO_ADDRESS && _member.amount > 0);
    }

    function _copyToFinalArrays(
        QueMember[] memory _tempOrders,
        int256[] memory _tempIncentives,
        uint256 _actualLength
    )
        internal
        pure
        returns (
            QueMember[] memory actualOrders,
            int256[] memory actualIncentives
        )
    {
        actualOrders = new QueMember[](_actualLength);
        actualIncentives = new int256[](_actualLength);

        for (uint256 j = 0; j < _actualLength; j++) {
            actualOrders[j] = _tempOrders[j];
            actualIncentives[j] = _tempIncentives[j];
        }
    }

    function _collectAllOrders(
        address _user,
        bool _checkUser
    )
        internal
        view
        returns (
            QueMember[] memory,
            int256[] memory
        )
    {
        int256[] memory allIncentives = _initializeAllIncentivesArray();
        QueMember[] memory tempOrders = new QueMember[](totalActiveOrders);
        int256[] memory tempIncentives = new int256[](totalActiveOrders);
        uint256 index = 0;

        for (uint256 i = 0; i < allIncentives.length; i++) {
            index = _collectOrdersForIncentive(
                allIncentives[i],
                _user,
                _checkUser,
                tempOrders,
                tempIncentives,
                index
            );
        }

        return _copyToFinalArrays(
            tempOrders,
            tempIncentives,
            index
        );
    }

    function _collectOrdersForIncentiveWithId(
        int256 _currentIncentive,
        address _user,
        bool _checkUser,
        QueMemberWithId[] memory _tempOrders,
        uint256 _currentIndex
    )
        internal
        view
        returns (uint256 newIndex)
    {
        newIndex = _currentIndex;
        uint256 maxIdForIncentive = earliestValidQueMemberByIncentive[_currentIncentive];

        for (uint256 id = 0; id < maxIdForIncentive; id++) {
            QueMember storage member = QueMemberByIdAndIncentive[id][_currentIncentive];

            if (_shouldIncludeOrder(member, _user, _checkUser)) {
                _tempOrders[newIndex] = QueMemberWithId({
                    memberId: id,
                    incentive: _currentIncentive,
                    member: member.member,
                    amount: member.amount,
                    tailPointer: member.tailPointer,
                    headPointer: member.headPointer
                });

                newIndex++;
            }
        }
    }

    function _copyToFinalArrayWithId(
        QueMemberWithId[] memory _tempOrders,
        uint256 _actualLength
    )
        internal
        pure
        returns (QueMemberWithId[] memory actualOrders)
    {
        actualOrders = new QueMemberWithId[](_actualLength);

        for (uint256 j = 0; j < _actualLength; j++) {
            actualOrders[j] = _tempOrders[j];
        }
    }

    function _collectAllOrdersWithId(
        address _user,
        bool _checkUser
    )
        internal
        view
        returns (QueMemberWithId[] memory)
    {
        int256[] memory allIncentives = _initializeAllIncentivesArray();
        QueMemberWithId[] memory tempOrders = new QueMemberWithId[](totalActiveOrders);
        uint256 index = 0;

        for (uint256 i = 0; i < allIncentives.length; i++) {
            index = _collectOrdersForIncentiveWithId(
                allIncentives[i],
                _user,
                _checkUser,
                tempOrders,
                index
            );
        }

        return _copyToFinalArrayWithId(
            tempOrders,
            index
        );
    }

    function _calculateFullOrdersCost(
        uint256[] memory _orders,
        int256[] memory _incentives
    )
        internal
        view
        returns (
            uint256 costInUsd,
            uint256 totalTokensPlanned
        )
    {
        for (uint256 i = 0; i < _orders.length; i++) {
            uint256 orderId = _orders[i];
            int256 incentive = _incentives[i];
            uint256 orderAmount = QueMemberByIdAndIncentive[orderId][incentive].amount;

            costInUsd += _predictChargedAmount(
                orderAmount,
                incentive
            );

            totalTokensPlanned += orderAmount;
        }
    }

    function _predictDiscountedAmount(
        uint256 _amount,
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 factor = _calculateDiscountFactor(
            _incentive
        );

        return Math.mulDiv(
            _amount,
            factor,
            PRECISION_RATE
        );
    }

    function _predictChargedAmount(
        uint256 _amount,
        int256 _incentive
    )
        internal
        pure
        returns (uint256)
    {
        uint256 discounted = _predictDiscountedAmount(
            _amount,
            _incentive
        );

        return discounted == 0
            ? _amount
            : discounted;
    }

    function _calculatePartialOrderCost(
        uint256[] memory _partials,
        int256[] memory _incentives,
        uint256 _ordersLength,
        uint256 _tokensToReceive,
        uint256 _totalTokensPlanned
    )
        internal
        pure
        returns (
            uint256 partialCost,
            uint256 partialTokens
        )
    {
        if (_partials.length > 0) {
            int256 partialIncentive = _incentives[_ordersLength];
            partialTokens = _tokensToReceive - _totalTokensPlanned;

            partialCost = _predictChargedAmount(
                partialTokens,
                partialIncentive
            );
        }
    }

    function _processOrderForCost(
        QueMember storage _entry,
        int256 _incentive,
        uint256 _remainingUsd
    )
        internal
        view
        returns (
            uint256 tokensAcquired,
            uint256 usdSpent
        )
    {
        uint256 orderCost = _predictChargedAmount(
            _entry.amount,
            _incentive
        );

        if (_remainingUsd >= orderCost) {
            tokensAcquired = _entry.amount;
            usdSpent = orderCost;
        } else {
            uint256 factor = _calculateDiscountFactor(
                _incentive
            );

            tokensAcquired = Math.mulDiv(
                _remainingUsd,
                PRECISION_RATE,
                factor
            );

            usdSpent = _remainingUsd;
        }
    }

    function _finalizeMemberRemoval(
        uint256 _queMemberId,
        QueMember storage _member,
        int256 _incentive,
        bool _handleAccounting
    )
        internal
    {
        if (_handleAccounting) {
            _changeProxyAccounting(
                _decreaseProxyBalance,
                _member.member,
                _member.amount
            );
        }

        _updateLinkedListPointers(
            _queMemberId,
            _member,
            _incentive
        );

        delete QueMemberByIdAndIncentive[_queMemberId][_incentive];

        totalActiveOrders--;
        activeOrderCountByIncentive[_incentive]--;
    }
}
