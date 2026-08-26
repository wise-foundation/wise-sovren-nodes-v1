// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {CursorProofHarness, MockStable} from "./CursorProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @title CursorPropertiesTest
 * @dev Dual-engine property suite for QUE-10, the strict-FIFO cursor
 * law: for every incentive lane, `currentOrderIdByIncentive` always
 * points at the LOWEST live order id, and when the lane is empty it is
 * parked exactly at the allocation edge
 * `earliestValidQueMemberByIncentive`. Every `testFuzz_*` is (a)
 * fuzzable by Foundry (`forge test`) and (b) symbolically provable by
 * Kontrol (`kontrol prove --match-test 'CursorPropertiesTest.<fn>'`).
 *
 * The proof shape is the inductive step, one lemma per queue mutation:
 * each test seeds a small lane that satisfies QUE-10 (structure
 * concrete so mapping slots stay concrete for the symbolic engine,
 * amounts fully symbolic), runs one real mutation - join, leave-head,
 * leave-mid, full fulfill, partial fulfill - and asserts the predicate
 * still holds plus the exact expected cursor value. Together with the
 * base case (a fresh lane has cursor == edge == 0) this proves the
 * cursor law is preserved by every reachable queue transition; the
 * stateful-fuzz form over all 17 tiers lives in
 * `test/diamond/invariant/QueueCursorInvariant.t.sol`.
 *
 * The incentive tier is concrete 0 so the fulfillment discount factor
 * is exactly 1 and the USD leg moves precisely the order amount.
 */
contract CursorPropertiesTest is Test {

    CursorProofHarness internal vault;
    MockStable internal usd;

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant MIN_DEPOSIT = 50 * 1e6;
    uint256 internal constant MAX_AMOUNT = 1e30;

    int256 internal constant TIER = 0;

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        usd = new MockStable();

        vault = new CursorProofHarness(
            _params()
        );

        vault.harnessSetLastSync(
            address(this),
            T0
        );

        usd.mint(
            address(this),
            type(uint128).max
        );

        usd.approve(
            address(vault),
            type(uint256).max
        );
    }

    function _params()
        internal
        view
        returns (WiseSovrenNodesInitParams memory params)
    {
        params.usdAddress = address(usd);
        params.thirdPartyAddress = address(0x7777);
        params.workerAddress = address(0xD00D);
        params.oldVault = address(0);
        params.initialDistributionAddresses = new address[](0);
        params.initialDistributionAmounts = new uint256[](0);
        params.totalDepositCap = 1e40;
        params.interestRate = 2_000;
        params.decimalsValue = 6;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "wsnUSDC";
    }

    /**
     * @dev The QUE-10 predicate for one lane: the cursor equals the
     * lowest id with a live amount, or the allocation edge when no
     * live order exists.
     */
    function _assertCursorIsLowestActive(
        int256 _incentive
    )
        internal
        view
    {
        uint256 earliest = vault.earliestValidQueMemberByIncentive(_incentive);
        uint256 cursor = vault.currentOrderIdByIncentive(_incentive);

        bool found;
        uint256 lowest;

        for (uint256 id = 0; id < earliest; id++) {
            (
                ,
                uint256 amount,
                ,
            ) = vault.QueMemberByIdAndIncentive(
                id,
                _incentive
            );

            if (amount > 0) {
                found = true;
                lowest = id;
                break;
            }
        }

        if (found) {
            assert(
                cursor == lowest
            );
        } else {
            assert(
                cursor == earliest
            );
        }
    }

    /**
     * @dev Base case + join step: a fresh lane satisfies the empty
     * form (cursor == edge == 0); the first join makes the new order
     * the lowest live id without moving the cursor (it already points
     * there); a second join appends behind and the cursor still points
     * at the oldest order - for any amounts.
     */
    function testFuzz_QUE10_joinNeverMovesCursor(
        uint256 _amountA,
        uint256 _amountB
    )
        public
    {
        vm.assume(
            _amountA >= MIN_DEPOSIT && _amountA <= MAX_AMOUNT
        );

        vm.assume(
            _amountB >= MIN_DEPOSIT && _amountB <= MAX_AMOUNT
        );

        _assertCursorIsLowestActive(
            TIER
        );

        uint256 firstId = vault.harnessSeedOrder(
            _amountA,
            TIER
        );

        assert(
            firstId == 0
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 0
        );

        _assertCursorIsLowestActive(
            TIER
        );

        vault.harnessSeedOrder(
            _amountB,
            TIER
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 0
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }

    /**
     * @dev Leave step, head case: when the cursor order itself leaves,
     * the cursor advances to the next live order - for any amounts.
     */
    function testFuzz_QUE10_leaveHeadAdvancesCursorToNextActive(
        uint256 _amountA,
        uint256 _amountB
    )
        public
    {
        vm.assume(
            _amountA >= MIN_DEPOSIT && _amountA <= MAX_AMOUNT
        );

        vm.assume(
            _amountB >= MIN_DEPOSIT && _amountB <= MAX_AMOUNT
        );

        vault.harnessSeedOrder(
            _amountA,
            TIER
        );

        vault.harnessSeedOrder(
            _amountB,
            TIER
        );

        vault.exposedLeaveCore(
            0,
            TIER
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 1
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }

    /**
     * @dev Leave step, mid case: when a NON-cursor order leaves, the
     * cursor stays on the oldest live order and the list splice keeps
     * the predicate intact - for any amounts.
     */
    function testFuzz_QUE10_leaveMidKeepsCursor(
        uint256 _amountA,
        uint256 _amountB
    )
        public
    {
        vm.assume(
            _amountA >= MIN_DEPOSIT && _amountA <= MAX_AMOUNT
        );

        vm.assume(
            _amountB >= MIN_DEPOSIT && _amountB <= MAX_AMOUNT
        );

        vault.harnessSeedOrder(
            _amountA,
            TIER
        );

        vault.harnessSeedOrder(
            _amountB,
            TIER
        );

        vault.exposedLeaveCore(
            1,
            TIER
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 0
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }

    /**
     * @dev Leave step, last-order case: when the only live order
     * leaves, the cursor parks exactly at the allocation edge - the
     * empty-lane form of the predicate - for any amount.
     */
    function testFuzz_QUE10_leaveLastRestoresEmptyForm(
        uint256 _amount
    )
        public
    {
        vm.assume(
            _amount >= MIN_DEPOSIT && _amount <= MAX_AMOUNT
        );

        vault.harnessSeedOrder(
            _amount,
            TIER
        );

        vault.exposedLeaveCore(
            0,
            TIER
        );

        assert(
            vault.currentOrderIdByIncentive(TIER)
                == vault.earliestValidQueMemberByIncentive(TIER)
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }

    /**
     * @dev Fulfill step, full case: fulfilling the head order in full
     * (the real `_processOrder`, USD payment included) deletes it and
     * advances the cursor to the next live order - for any amounts.
     */
    function testFuzz_QUE10_fullFulfillAdvancesCursor(
        uint256 _amountA,
        uint256 _amountB
    )
        public
    {
        vm.assume(
            _amountA >= MIN_DEPOSIT && _amountA <= MAX_AMOUNT
        );

        vm.assume(
            _amountB >= MIN_DEPOSIT && _amountB <= MAX_AMOUNT
        );

        vault.harnessSeedOrder(
            _amountA,
            TIER
        );

        vault.harnessSeedOrder(
            _amountB,
            TIER
        );

        vault.exposedProcessOrder(
            0,
            TIER,
            _amountA,
            true
        );

        (
            ,
            uint256 removedAmount,
            ,
        ) = vault.QueMemberByIdAndIncentive(
            0,
            TIER
        );

        assert(
            removedAmount == 0
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 1
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }

    /**
     * @dev Fulfill step, partial case: a partial fulfillment shrinks
     * the head order but keeps it live, so the cursor must NOT move -
     * for any amount and any partial strictly below it.
     */
    function testFuzz_QUE10_partialFulfillKeepsCursor(
        uint256 _amount,
        uint256 _part
    )
        public
    {
        vm.assume(
            _amount >= MIN_DEPOSIT && _amount <= MAX_AMOUNT
        );

        vm.assume(
            _part > 0 && _part < _amount
        );

        vault.harnessSeedOrder(
            _amount,
            TIER
        );

        vault.exposedProcessOrder(
            0,
            TIER,
            _part,
            false
        );

        (
            ,
            uint256 remainingAmount,
            ,
        ) = vault.QueMemberByIdAndIncentive(
            0,
            TIER
        );

        assert(
            remainingAmount == _amount - _part
        );

        assert(
            vault.currentOrderIdByIncentive(TIER) == 0
        );

        _assertCursorIsLowestActive(
            TIER
        );
    }
}
