// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesInterestHelper} from "./WiseSovrenNodesInterestHelper.sol";

/**
 * @dev Buffer / overhang sweep logic. The contract must hold at
 * least two weeks of forward interest at the configured
 * `bufferInterestRate` on the share supply PLUS the settled
 * `totalCashedInterest` liability users can already claim on
 * demand; anything above that combined reserve is "overhang" and
 * can be swept to the registered `workerAddress` by any address
 * master has granted in the `isSweeper` allowlist. The liability
 * term means a sweep can never take the cash a custodian
 * pre-funded for pending claims. With zero share supply the
 * reserve is the liability alone — cashed interest stays claimable
 * after every share has exited.
 *
 * Principal is `totalSupply()` — queued shares are already counted
 * there (they move from the user's `balanceOf` to the queue's
 * `balanceOf` on `joinQue`, never minted/burned).
 */
abstract contract WiseSovrenNodesBufferHelper is WiseSovrenNodesInterestHelper {

    using SafeERC20 for IERC20;

    function _calculateNeededBuffer()
        internal
        view
        returns (uint256)
    {
        uint256 principal = totalSupply();

        if (principal == 0) {
            return totalCashedInterest;
        }

        uint256 yearFactor = SECONDS_IN_TWO_WEEKS
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        uint256 forwardInterest = principal
            * bufferInterestRate
            * yearFactor
            / PRECISION_RATE
            / PRECISION_FACTOR_E18;

        return forwardInterest
            + totalCashedInterest;
    }

    function _calculateOverhang()
        internal
        view
        returns (uint256)
    {
        uint256 needed = _calculateNeededBuffer();
        uint256 actual = USD_TOKEN.balanceOf(
            address(this)
        );

        if (actual <= needed) {
            return 0;
        }

        return actual - needed;
    }

    function _executeSweepOverhang()
        internal
        returns (uint256 amount)
    {
        require(
            isSweeper[msg.sender],
            NotSweeper()
        );

        amount = _calculateOverhang();

        require(
            amount > 0,
            NoOverhang()
        );

        address worker = workerAddress;

        USD_TOKEN.safeTransfer(
            worker,
            amount
        );

        emit OverhangSwept(
            worker,
            msg.sender,
            amount
        );
    }
}
