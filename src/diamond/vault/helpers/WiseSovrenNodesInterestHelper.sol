// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesProxyHelper} from "./WiseSovrenNodesProxyHelper.sol";

/**
 * @dev Interest accrual, assignment, claim and compound logic plus
 * the public view helpers. Most parity-sensitive layer — any drift
 * here surfaces as cashedInterest / pending-interest mismatch.
 */
abstract contract WiseSovrenNodesInterestHelper is WiseSovrenNodesProxyHelper {

    using SafeERC20 for IERC20;

    modifier assignInterest(
        address _user
    ) {
        _assignInterest(
            _user
        );
        _;
    }

    modifier gracePeriodCheck(
        address _user
    ) {
        _checkGracePeriod(
            _user
        );
        _;
    }

    modifier registerLargeDeposit(
        address _user
    ) {
        uint256 balanceBefore = balanceOf(
            _user
        );
        _;
        _registerLargeDeposit(
            _user,
            balanceBefore
        );
    }

    function _assignInterest(
        address _user
    )
        internal
    {
        address userToAssign = _user;

        if (_user == InterestRateProxy) {
            userToAssign = currentProxyBenefactor;
        }

        if (userToAssign == ZERO_ADDRESS) {
            return;
        }

        uint256 scaledPending = _pendingInterestScaledByTimeStamp(
            userToAssign,
            block.timestamp
        );

        if (scaledPending > 0) {
            uint256 accrued = scaledPending
                + interestRemainder[userToAssign];

            uint256 interest = accrued
                / PRECISION_FACTOR_E18;

            interestRemainder[userToAssign] = accrued
                - interest
                * PRECISION_FACTOR_E18;

            if (interest > 0) {
                cashedInterest[userToAssign] += interest;

                totalCashedInterest += interest;

                emit TotalCashedInterestChanged(
                    totalCashedInterest
                );
            }
        }

        lastSyncTimeStamp[userToAssign] = block.timestamp;
    }

    function _checkGracePeriod(
        address _user
    )
        internal
        view
    {
        require(
            lastLargeDepositAt[_user] == 0
                || block.timestamp >= lastLargeDepositAt[_user] + gracePeriodDuration,
            GracePeriodNotElapsed()
        );
    }

    function _registerLargeDeposit(
        address _user,
        uint256 _balanceBefore
    )
        internal
    {
        uint256 threshold = graceThresholdAmount;

        if (threshold == 0) {
            return;
        }

        uint256 balanceAfter = balanceOf(
            _user
        );

        if (balanceAfter <= _balanceBefore) {
            return;
        }

        uint256 balanceIncrease = balanceAfter
            - _balanceBefore;

        address facet = depositHookFacet;

        if (facet == ZERO_ADDRESS) {
            if (balanceIncrease < threshold) {
                return;
            }

            _stampLargeDeposit(
                _user,
                balanceIncrease
            );

            return;
        }

        _runDepositHook(
            facet,
            _user,
            balanceIncrease
        );
    }

    function _stampLargeDeposit(
        address _user,
        uint256 _balanceIncrease
    )
        internal
    {
        lastLargeDepositAt[_user] = block.timestamp;

        emit LargeDepositRegistered(
            _user,
            _balanceIncrease,
            block.timestamp + gracePeriodDuration
        );
    }

    function _executeMoveInterestTo(
        address _from,
        address _target,
        uint256 _amount,
        bool _all
    )
        internal
    {
        if (_target == _from) {
            return;
        }

        require(
            _target != ZERO_ADDRESS && _target != InterestRateProxy,
            InvalidValue()
        );

        uint256 available = cashedInterest[_from];

        uint256 moveAmount = _all
            ? available
            : _amount;

        require(
            moveAmount > 0,
            NoInterest()
        );

        require(
            moveAmount <= available,
            InvalidValue()
        );

        cashedInterest[_from] = available - moveAmount;

        cashedInterest[_target] = cashedInterest[_target] + moveAmount;

        emit InterestMoved(
            _from,
            _target,
            moveAmount
        );
    }

    function _runTransferHook(
        address _from,
        address _to
    )
        internal
    {
        address facet = transferHookFacet;

        if (facet == ZERO_ADDRESS) {
            return;
        }

        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = facet.delegatecall(
            abi.encodeWithSelector(
                TRANSFER_HOOK_SELECTOR,
                _from,
                _to
            )
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _runDepositHook(
        address _facet,
        address _user,
        uint256 _balanceIncrease
    )
        internal
    {
        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = _facet.delegatecall(
            abi.encodeWithSelector(
                DEPOSIT_HOOK_SELECTOR,
                _user,
                _balanceIncrease
            )
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _calculateInterestScaledE18(
        uint256 _balance,
        uint256 _timeDelta
    )
        internal
        view
        returns (uint256)
    {
        uint256 yearFactor = _timeDelta
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        return _balance
            * interestRate
            * yearFactor
            / PRECISION_RATE;
    }

    function _calculateInterest(
        uint256 _balance,
        uint256 _timeDelta
    )
        internal
        view
        returns (uint256)
    {
        return _calculateInterestScaledE18(
            _balance,
            _timeDelta
        ) / PRECISION_FACTOR_E18;
    }

    function _prepareClaim(
        address _user
    )
        internal
        returns (uint256 interestAmount)
    {
        interestAmount = cashedInterest[_user];

        if (interestAmount == 0) {
            revert NoInterest();
        }

        cashedInterest[_user] = 0;

        totalCashedInterest -= interestAmount;

        emit TotalCashedInterestChanged(
            totalCashedInterest
        );
    }

    function _prepareExactAmountClaim(
        address _user,
        uint256 _amount
    )
        internal
    {
        if (_amount == 0) {
            revert InvalidValue();
        }

        uint256 totalInterest = cashedInterest[_user];

        if (totalInterest < _amount) {
            revert InsufficientInterest();
        }

        cashedInterest[_user] = totalInterest - _amount;

        totalCashedInterest -= _amount;

        emit TotalCashedInterestChanged(
            totalCashedInterest
        );
    }

    function _handleSimpleClaim(
        address _user
    )
        internal
        returns (uint256 interest)
    {
        interest = _prepareClaim(
            _user
        );

        USD_TOKEN.safeTransfer(
            _user,
            interest
        );

        emit ClaimInterestSimple(
            _user,
            interest
        );
    }

    function _handleClaimExactAmount(
        address _user,
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _prepareExactAmountClaim(
            _user,
            _amount
        );

        USD_TOKEN.safeTransfer(
            _user,
            _amount
        );

        emit ClaimInterestExactAmount(
            _user,
            _amount
        );

        return _amount;
    }

    function _handleCompoundInterest(
        address _user
    )
        internal
        returns (uint256 interest)
    {
        interest = _prepareClaim(
            _user
        );

        _checkDepositCap(
            interest
        );

        _mint(
            _user,
            interest
        );

        USD_TOKEN.safeTransfer(
            thirdPartyAddress,
            interest
        );

        emit CompoundInterest(
            _user,
            interest
        );
    }

    function _executePartialClaimAndCompound(
        address _user,
        uint256 _amount
    )
        internal
        returns (uint256 totalClaimed)
    {
        totalClaimed = _handleClaimExactAmount(
            _user,
            _amount
        );

        totalClaimed += _handleCompoundInterest(
            _user
        );
    }

    // ---- view helpers ----

    function _pendingInterestScaledByTimeStamp(
        address _user,
        uint256 _timestamp
    )
        internal
        view
        returns (uint256)
    {
        if (_user == InterestRateProxy) {
            return 0;
        }

        uint256 currentBalance = balanceOf(_user)
            + proxyBalance[_user];

        if (currentBalance == 0) {
            return 0;
        }

        uint256 lastSync = lastSyncTimeStamp[_user];

        if (_timestamp <= lastSync) {
            return 0;
        }

        uint256 timeDelta = _timestamp - lastSync;

        return _calculateInterestScaledE18(
            currentBalance,
            timeDelta
        );
    }

    /**
     * @dev Mirrors _assignInterest exactly: the carried interestRemainder
     * participates in the floor, so the view reports precisely the amount
     * the next sync will bank. A zero scaled pending returns zero because
     * _assignInterest skips entirely in that case and the remainder alone
     * can never reach a full unit.
     */
    function getPendingInterestByTimeStamp(
        address _user,
        uint256 _timestamp
    )
        public
        view
        returns (uint256)
    {
        uint256 scaledPending = _pendingInterestScaledByTimeStamp(
            _user,
            _timestamp
        );

        if (scaledPending == 0) {
            return 0;
        }

        return (scaledPending + interestRemainder[_user])
            / PRECISION_FACTOR_E18;
    }

    function getPendingInterest(
        address _user
    )
        public
        view
        returns (uint256)
    {
        return getPendingInterestByTimeStamp(
            _user,
            block.timestamp
        );
    }

    function getPendingInterestBulkByTimeStamp(
        address[] memory _users,
        uint256 _timestamp
    )
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory pendingInterests = new uint256[](_users.length);

        for (uint256 i = 0; i < _users.length; i++) {
            pendingInterests[i] = getPendingInterestByTimeStamp(
                _users[i],
                _timestamp
            );
        }

        return pendingInterests;
    }

    function getPendingInterestBulk(
        address[] memory _users
    )
        external
        view
        returns (uint256[] memory)
    {
        return getPendingInterestBulkByTimeStamp(
            _users,
            block.timestamp
        );
    }

    function getTotalInterestUserByTimeStamp(
        address _user,
        uint256 _timestamp
    )
        public
        view
        returns (uint256)
    {
        return cashedInterest[_user]
            + getPendingInterestByTimeStamp(
                _user,
                _timestamp
            );
    }

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return getTotalInterestUserByTimeStamp(
            _user,
            block.timestamp
        );
    }

    function getTotalInterestUserBulkByTimeStamp(
        address[] memory _users,
        uint256 _timestamp
    )
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory totalInterests = new uint256[](_users.length);

        for (uint256 i = 0; i < _users.length; i++) {
            totalInterests[i] = getTotalInterestUserByTimeStamp(
                _users[i],
                _timestamp
            );
        }

        return totalInterests;
    }

    function getTotalInterestUserBulk(
        address[] memory _users
    )
        public
        view
        returns (uint256[] memory)
    {
        return getTotalInterestUserBulkByTimeStamp(
            _users,
            block.timestamp
        );
    }
}
