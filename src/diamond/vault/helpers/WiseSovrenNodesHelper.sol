// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesCrossChainHelper} from "./WiseSovrenNodesCrossChainHelper.sol";

/**
 * @dev Top of the vault helper chain. Owns deposit, the combined
 * deposit-and-{claim,compound} flows, and the ERC20
 * `transfer`/`transferFrom` overrides that route through interest
 * assignment.
 */
abstract contract WiseSovrenNodesHelper is WiseSovrenNodesCrossChainHelper {

    using SafeERC20 for IERC20;

    function _checkValuesDeposit(
        uint256 _amount
    )
        internal
        view
    {
        if (depositsDisabled == true) {
            revert DepositsDisabled();
        }

        if (_amount == 0) {
            revert InvalidValue();
        }

        _checkDepositCap(
            _amount
        );
    }

    function _deposit(
        uint256 _amount
    )
        internal
    {
        _checkValuesDeposit(
            _amount
        );

        USD_TOKEN.safeTransferFrom(
            msg.sender,
            thirdPartyAddress,
            _amount
        );

        _recordDeposit(
            _amount
        );
    }

    function _recordDeposit(
        uint256 _amount
    )
        internal
    {
        _mint(
            msg.sender,
            _amount
        );

        emit Deposited(
            msg.sender,
            _amount
        );
    }

    function _executeDepositAndClaim(
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _deposit(
            _amount
        );

        return _handleSimpleClaim(
            msg.sender
        );
    }

    function _executeDepositAndCompound(
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        _deposit(
            _amount
        );

        return _handleCompoundInterest(
            msg.sender
        );
    }

    // ---- ERC20 transfer overrides ----

    function transfer(
        address to,
        uint256 amount
    )
        public
        virtual
        override
        assignInterest(msg.sender)
        assignInterest(to)
        nonReentrant
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _runTransferHook(
            msg.sender,
            to
        );

        return super.transfer(
            to,
            amount
        );
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        virtual
        override
        assignInterest(from)
        assignInterest(to)
        nonReentrant
        returns (bool)
    {
        require(
            amount > 0,
            InvalidValue()
        );

        _runTransferHook(
            from,
            to
        );

        return super.transferFrom(
            from,
            to,
            amount
        );
    }
}
