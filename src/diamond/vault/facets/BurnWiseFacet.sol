// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

import {IWiseToken} from "../interfaces/IWiseToken.sol";

/**
 * @dev Permissionless WISE burn. Anyone can trigger `burnWise()`, but
 * each call burns only a rotating slice of the diamond's current
 * `WISE_TOKEN` balance drawn from a fixed looping basis-point sequence
 * (`_burnPercentageForIndex`), and `burnWiseIndex` advances by one and
 * wraps on every successful burn. A per-caller `BURN_WISE_COOLDOWN`
 * (1 day) throttles spam; the first call from a fresh address is always
 * allowed. `getBurnableWise()` still reports the raw balance and
 * `getNextBurnPercentage()` exposes the scheduled slice bps for the
 * current rotation slot — it is balance-independent and so does not
 * reflect the sweep described next. Once the balance falls to
 * `BURN_WISE_SWEEP_THRESHOLD` (50 WISE) or
 * below, a call burns the whole remaining balance instead of a slice,
 * so the tail of the reserve is cleaned out rather than nibbled
 * forever. Both the schedule and the threshold live in facet bytecode,
 * so master can retune them by deploying a replacement facet and
 * re-pointing the selectors — no editable storage.
 * `WISE_TOKEN` is diamond storage configured by master through
 * `setWiseToken`; on chains that have no WISE token it stays
 * `address(0)` and `burnWise()` reverts `WiseTokenNotSet`.
 */
contract BurnWiseFacet is FacetBase {

    uint256 internal constant BURN_WISE_SEQUENCE_LENGTH = 6;

    uint256 internal constant BURN_WISE_SWEEP_THRESHOLD = 50 * 1e18;

    constructor()
        FacetBase()
    {}

    function burnWise()
        external
        onlyDelegateCall
        nonReentrant
        returns (uint256 amount)
    {
        address wiseToken = WISE_TOKEN;

        require(
            wiseToken != ZERO_ADDRESS,
            WiseTokenNotSet()
        );

        require(
            lastBurnWiseAt[msg.sender] == 0
                || block.timestamp >= lastBurnWiseAt[msg.sender] + BURN_WISE_COOLDOWN,
            WiseBurnCooldownNotElapsed()
        );

        uint256 balance = IWiseToken(wiseToken).balanceOf(
            address(this)
        );

        uint256 percentageBps = _burnPercentageForIndex(
            burnWiseIndex
        );

        if (balance <= BURN_WISE_SWEEP_THRESHOLD) {
            percentageBps = PRECISION_RATE;
        }

        amount = balance
            * percentageBps
            / PRECISION_RATE;

        require(
            amount > 0,
            NoWiseToBurn()
        );

        lastBurnWiseAt[msg.sender] = block.timestamp;

        burnWiseIndex = (burnWiseIndex + 1)
            % BURN_WISE_SEQUENCE_LENGTH;

        IWiseToken(wiseToken).burn(
            amount
        );

        emit WiseBurned(
            msg.sender,
            amount,
            percentageBps
        );
    }

    function getBurnableWise()
        external
        view
        returns (uint256)
    {
        address wiseToken = WISE_TOKEN;

        if (wiseToken == ZERO_ADDRESS) {
            return 0;
        }

        return IWiseToken(wiseToken).balanceOf(
            address(this)
        );
    }

    function getNextBurnPercentage()
        external
        view
        returns (uint256)
    {
        return _burnPercentageForIndex(
            burnWiseIndex
        );
    }

    function _burnPercentageForIndex(
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        uint256[BURN_WISE_SEQUENCE_LENGTH] memory sequence = [
            uint256(500),
            1000,
            2000,
            1500,
            500,
            100
        ];

        return sequence[
            _index % BURN_WISE_SEQUENCE_LENGTH
        ];
    }
}
