// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Inherit-harness over the real {WiseSovrenNodesDiamond}. It deploys
 * the genuine contract, so `InterestRateProxy == address(this)`, the
 * configured `interestRate`, and the whole interest-helper chain are
 * the real production code. It then exposes the otherwise-internal
 * accrual primitives plus narrow storage setters so a symbolic (Kontrol)
 * or fuzz (Foundry) driver can place the relevant slots - balanceOf,
 * proxyBalance, lastSyncTimeStamp, interestRate, cashedInterest and
 * currentProxyBenefactor - into an arbitrary state without routing
 * through the diamond fallback.
 *
 * Nothing here alters vault logic: every `exposed*` call forwards
 * verbatim into the inherited helper under test, and every `harness*`
 * setter writes a single declared storage field.
 */
contract InterestProofHarness is WiseSovrenNodesDiamond {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDiamond(
            _params
        )
    {}

    // ---- exposed accrual primitives (real code under test) ----

    function exposedAssignInterest(
        address _user
    )
        external
    {
        _assignInterest(
            _user
        );
    }

    function exposedCalculateInterest(
        uint256 _balance,
        uint256 _timeDelta
    )
        external
        view
        returns (uint256)
    {
        return _calculateInterest(
            _balance,
            _timeDelta
        );
    }

    function exposedMoveInterestTo(
        address _from,
        address _target,
        uint256 _amount,
        bool _all
    )
        external
    {
        _executeMoveInterestTo(
            _from,
            _target,
            _amount,
            _all
        );
    }

    function exposedPrepareClaim(
        address _user
    )
        external
        returns (uint256)
    {
        return _prepareClaim(
            _user
        );
    }

    function exposedPrepareExactAmountClaim(
        address _user,
        uint256 _amount
    )
        external
    {
        _prepareExactAmountClaim(
            _user,
            _amount
        );
    }

    // ---- narrow storage setters (proof scaffolding only) ----

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

    function harnessSetProxyBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        proxyBalance[_user] = _amount;
    }

    function harnessSetLastSync(
        address _user,
        uint256 _timestamp
    )
        external
    {
        lastSyncTimeStamp[_user] = _timestamp;
    }

    function harnessSetCashedInterest(
        address _user,
        uint256 _amount
    )
        external
    {
        cashedInterest[_user] = _amount;
    }

    function harnessSetTotalCashedInterest(
        uint256 _amount
    )
        external
    {
        totalCashedInterest = _amount;
    }

    function harnessTotalCashedInterest()
        external
        view
        returns (uint256)
    {
        return totalCashedInterest;
    }

    function harnessSetInterestRate(
        uint256 _rate
    )
        external
    {
        interestRate = _rate;
    }

    function harnessSetProxyBenefactor(
        address _benefactor
    )
        external
    {
        currentProxyBenefactor = _benefactor;
    }
}
