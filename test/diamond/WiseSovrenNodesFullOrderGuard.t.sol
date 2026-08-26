// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesQueueHelper} from "../../src/diamond/vault/helpers/WiseSovrenNodesQueueHelper.sol";
import {WiseSovrenNodesDeclarations} from "../../src/diamond/vault/declarations/WiseSovrenNodesDeclarations.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }
}

/**
 * @dev Inherit-harness exposing `_processFullOrdersForIncentive` and
 * `_validateOrderProcessing`. The `amt == 0 || amt > newRemainingAmount`
 * skip is unreachable through the public solve/predict path (the
 * producing traverse only yields ids with `amount > 0` that fit the
 * remaining budget), so it is a defensive guard. The harness hands the
 * consumer a full-ids list that trips both legs. Likewise the
 * full-fulfill `amount > 0` liveness guard is defensive: every
 * cursor-advancing path keeps the current order live, so a zero-amount
 * current order is unreachable via the public surface — the guard makes
 * that state revert explicitly instead of leaning on the downstream
 * `safeTransferFrom(sender, address(0), 0)` revert of standard ERC20s.
 */
contract FullOrdersHarness is WiseSovrenNodesQueueHelper {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDeclarations(
            _params
        )
    {}

    function harnessSetAmount(
        uint256 _id,
        int256 _incentive,
        uint256 _amount
    )
        external
    {
        QueMemberByIdAndIncentive[_id][_incentive].amount = _amount;
    }

    function harnessSetQueueCursor(
        int256 _incentive,
        uint256 _currentOrderId,
        uint256 _earliestValidId
    )
        external
    {
        currentOrderIdByIncentive[_incentive] = _currentOrderId;
        earliestValidQueMemberByIncentive[_incentive] = _earliestValidId;
    }

    function exposedProcessFull(
        uint256[] calldata _fullIds,
        int256 _incentive,
        uint256 _remaining
    )
        external
        view
        returns (uint256)
    {
        return _processFullOrdersForIncentive(
            _initializeSolveVars(),
            _fullIds,
            _incentive,
            _remaining
        );
    }

    function exposedValidateOrderProcessing(
        uint256 _queMemberId,
        int256 _incentive,
        uint256 _amount,
        bool _isFullFulfill
    )
        external
        view
    {
        _validateOrderProcessing(
            _queMemberId,
            _incentive,
            _amount,
            _isFullFulfill
        );
    }
}

contract WiseSovrenNodesFullOrderGuardTest is Test {

    FullOrdersHarness harness;
    MockUSD usd;

    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        harness = new FullOrdersHarness(
            _params()
        );
    }

    function _params()
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: thirdPty,
            workerAddress: worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: 1_000_000_000 * 1e6,
            interestRate: 2000,
            decimalsValue: 6,
            tokenName: "Wise Sovren Nodes",
            tokenSymbol: "wsnUSDC"
        });
    }

    function test_processFullOrders_skipsZeroAndOversizedAmounts()
        public
    {
        harness.harnessSetAmount(
            1,
            0,
            100 * 1e6
        );

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;

        uint256 remaining = harness.exposedProcessFull(
            ids,
            0,
            1
        );

        assertEq(
            remaining,
            1
        );
    }

    function test_validateOrderProcessing_fullFulfillEmptyOrder_reverts()
        public
    {
        harness.harnessSetQueueCursor(
            0,
            0,
            1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ZeroAmount.selector
        );

        harness.exposedValidateOrderProcessing(
            0,
            0,
            0,
            true
        );
    }

    function test_validateOrderProcessing_fullFulfillLiveOrder_passes()
        public
    {
        harness.harnessSetQueueCursor(
            0,
            0,
            1
        );

        harness.harnessSetAmount(
            0,
            0,
            100 * 1e6
        );

        harness.exposedValidateOrderProcessing(
            0,
            0,
            100 * 1e6,
            true
        );
    }
}
