// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {MoveOutProofHarness} from "./MoveOutProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @dev Minimal same-chain peer: a move-out DELEGATECALLs nothing here,
 * it makes a real external call `IPeerVault(dst).mintFromPeer(user,
 * dstAmount)` and reads `IERC20Metadata(dst).decimals()` to scale. The
 * mock answers both — `decimals() == 6` matches the source so the
 * amount scales 1:1 with no dust, and `mintFromPeer` is a no-op that
 * never reverts, so the destination leg never masks a source-side
 * accounting result. The proof is about the SOURCE vault's ledger.
 */
contract MockMovePeer {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mintFromPeer(
        address,
        uint256
    )
        external
    {}
}

/**
 * @title MoveOutPropertiesTest
 * @dev Dual-engine property suite for MOV-1, the same-chain move-out
 * cap-relocation law.
 *
 * A move-out relocates deposit-cap budget with the principal: after
 * `_burn(msg.sender, amount)` the helper calls `_reduceDepositCap`
 * (`totalDepositCap -= amount`), so cap and supply drop in lockstep,
 * per-vault room (`totalDepositCap - totalSupply`) is invariant and
 * the destination's matching `_raiseDepositCap` conserves mesh-wide
 * Σ totalDepositCap. Pending interest is no longer compounded by the
 * move — the facet's `assignInterest` modifier banks it into
 * `cashedInterest` without minting, and the internal `_executeMoveOut`
 * proven here touches no interest state at all, so the exact-delta law
 * carries no pending term and no `USD_TOKEN` moves.
 *
 * Tractability mirrors the interest suite: the mover and peer are
 * concrete (mapping keys stay concrete), `interestRate` is concrete
 * `2000` and the sync delta is a concrete one year, so a nonzero
 * pending `floor(balance / 5)` stands on the mover's balance ready to
 * expose any residual compound mint. Balance, move amount and cap are
 * symbolic under the reachable-state precondition
 * `totalSupply <= totalDepositCap` (cap-below-supply states are
 * unconstructible on-chain since `setTotalDepositCap` floors at the
 * live supply and every relocation shifts cap and supply equally).
 */
contract MoveOutPropertiesTest is Test {

    MoveOutProofHarness internal vault;
    MockMovePeer internal peer;

    uint256 internal constant MAX_BASE = 1e40;

    uint256 internal constant T0 = 1_700_000_000;

    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;

    address internal constant MOVER = address(0xBEEF);

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        vault = new MoveOutProofHarness(
            _params()
        );

        peer = new MockMovePeer();

        vault.harnessSetPeerVault(
            address(peer),
            true
        );
    }

    function _params()
        internal
        pure
        returns (WiseSovrenNodesInitParams memory params)
    {
        params.usdAddress = address(0xD15C);
        params.thirdPartyAddress = address(0x7777);
        params.workerAddress = address(0xD00D);
        params.oldVault = address(0);
        params.initialDistributionAddresses = new address[](0);
        params.initialDistributionAmounts = new uint256[](0);
        params.totalDepositCap = 1e30;
        params.interestRate = 2_000;
        params.decimalsValue = 6;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "wsnUSDC";
    }

    /**
     * @dev MOV-1: for ANY mover balance, move amount and deposit cap
     * in the reachable region (`totalSupply <= totalDepositCap`), a
     * successful move-out of `amount` moves the ledger by its exact
     * relocation deltas — the burn drops supply by `amount` and
     * `_reduceDepositCap` drops the cap by the same `amount` — so room
     * (`totalDepositCap - totalSupply`) is invariant and
     * `totalSupply <= totalDepositCap` is preserved. A full year of
     * accrued pending interest stands on the mover's balance, and the
     * exact supply delta proves none of it is minted by the move (the
     * deleted compound), while `cashedInterest` stays untouched
     * because banking lives in the facet's `assignInterest` modifier
     * above the helper proven here. A reverting move-out leaves supply
     * and cap untouched.
     */
    function testFuzz_MOV1_moveOutRelocatesCapWithPrincipal(
        uint256 _balance,
        uint256 _amount,
        uint256 _cap
    )
        public
    {
        vm.assume(
            _balance <= MAX_BASE
        );

        vm.assume(
            _amount > 0 && _amount <= _balance
        );

        vm.assume(
            _cap >= _balance && _cap <= 2 * MAX_BASE
        );

        vault.harnessMint(
            MOVER,
            _balance
        );

        vault.harnessSetLastSync(
            MOVER,
            T0
        );

        vault.harnessSetCap(
            _cap
        );

        vm.warp(
            T0 + SECONDS_IN_YEAR
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 capBefore = vault.totalDepositCap();
        uint256 roomBefore = capBefore - supplyBefore;

        vm.prank(
            MOVER
        );

        try vault.exposedExecuteMoveOut(address(peer), _amount) {
            uint256 supplyAfter = vault.totalSupply();
            uint256 capAfter = vault.totalDepositCap();

            assert(
                capAfter == capBefore - _amount
            );

            assert(
                supplyAfter == supplyBefore - _amount
            );

            assert(
                capAfter - supplyAfter == roomBefore
            );

            assert(
                supplyAfter <= capAfter
            );

            assert(
                vault.cashedInterest(MOVER) == 0
            );
        } catch {
            assert(
                vault.totalSupply() == supplyBefore
            );

            assert(
                vault.totalDepositCap() == capBefore
            );
        }
    }

    /**
     * @dev Concrete discriminator: a vault sitting exactly at its cap
     * (room 0) can always move out, and the move relocates the cap by
     * the full amount. Supply 5000 at cap 5000; a year accrues 1000
     * pending on the mover; moving 1000 leaves supply 4000 at cap
     * 4000 — room still exactly 0, nothing minted, nothing banked. A
     * naive implementation that forgets the `_reduceDepositCap`
     * relocation leaves the cap at 5000 (room falsely 1000); one that
     * treats the move as a cap-gated deposit, or reduces the cap
     * before the burn and validates supply against the already-reduced
     * cap, reverts at-cap. All three fail here.
     */
    function test_MOV1_atCapMoveOutSucceedsRoomStaysZero()
        public
    {
        vault.harnessMint(
            MOVER,
            5000
        );

        vault.harnessSetLastSync(
            MOVER,
            T0
        );

        vault.harnessSetCap(
            5000
        );

        vm.warp(
            T0 + SECONDS_IN_YEAR
        );

        vm.prank(
            MOVER
        );

        vault.exposedExecuteMoveOut(
            address(peer),
            1000
        );

        assert(
            vault.totalSupply() == 4000
        );

        assert(
            vault.totalDepositCap() == 4000
        );

        assert(
            vault.balanceOf(MOVER) == 4000
        );

        assert(
            vault.cashedInterest(MOVER) == 0
        );
    }
}
