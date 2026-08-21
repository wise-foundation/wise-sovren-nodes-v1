// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {SwitchProofHarness} from "./SwitchProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @title SwitchPropertiesTest
 * @dev Dual-engine property suite for `switchQueIncentive`. Every
 * `testFuzz_*` is (a) fuzzable by Foundry (`forge test`) and (b)
 * symbolically provable by Kontrol
 * (`kontrol prove --match-test 'SwitchPropertiesTest.<fn>'`). Inputs are
 * plain parameters — concrete under Foundry, symbolic under Kontrol — and
 * postconditions use raw `assert` (Panic 0x01).
 *
 * The harness replays the real internal-helper sequence of
 * `switchQueIncentive`, so these prove the two guarantees the differential
 * suite checks by example, but over ALL amounts:
 *
 *   1. VALUE-NEUTRAL — a switch mints/burns/transfers nothing and its
 *      proxy accounting round-trips, so `totalSupply`, the owner's token
 *      balance, and the owner's `proxyBalance` are invariant.
 *
 *   2. CONSERVATION — a switch moves exactly one order from the source
 *      count to the destination count, leaving `totalActiveOrders` and the
 *      moved amount unchanged (the queue-conservation invariant).
 *
 * Incentive tiers are concrete (0 → 100) so mapping slots stay concrete
 * for the symbolic engine; the moved amount is fully symbolic.
 */
contract SwitchPropertiesTest is Test {

    SwitchProofHarness internal vault;

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant MIN_DEPOSIT = 50 * 1e6;
    uint256 internal constant MAX_AMOUNT = 1e30;

    int256 internal constant SRC = 0;
    int256 internal constant DST = 100;

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        vault = new SwitchProofHarness(
            _params()
        );

        vault.harnessSetLastSync(
            address(this),
            T0
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
        params.totalDepositCap = 1e40;
        params.interestRate = 2_000;
        params.decimalsValue = 6;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "wsnUSDC";
    }

    /**
     * @dev A switch is value-neutral: it never mints, burns or transfers,
     * and its `-amount` then `+amount` proxy accounting round-trips, so the
     * owner's token balance, the total supply, and the owner's proxy
     * balance are all exactly what they were before — for any amount.
     */
    function testFuzz_switchIsValueNeutral(
        uint256 _amount
    )
        public
    {
        vm.assume(
            _amount >= MIN_DEPOSIT && _amount <= MAX_AMOUNT
        );

        vault.harnessMint(
            address(this),
            MAX_AMOUNT
        );

        uint256 id = vault.harnessSeedOrder(
            _amount,
            SRC
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 balanceBefore = vault.balanceOf(address(this));
        uint256 proxyBefore = vault.proxyBalance(address(this));

        vault.exposedSwitchCore(
            id,
            SRC,
            DST
        );

        assert(
            vault.totalSupply() == supplyBefore
        );

        assert(
            vault.balanceOf(address(this)) == balanceBefore
        );

        assert(
            vault.proxyBalance(address(this)) == proxyBefore
        );
    }

    /**
     * @dev A switch conserves order accounting: `totalActiveOrders` is
     * unchanged, exactly one order moves from the source count to the
     * destination count, and the moved order carries the full original
     * amount into the destination queue — for any amount.
     */
    function testFuzz_switchConservesOrders(
        uint256 _amount
    )
        public
    {
        vm.assume(
            _amount >= MIN_DEPOSIT && _amount <= MAX_AMOUNT
        );

        uint256 id = vault.harnessSeedOrder(
            _amount,
            SRC
        );

        uint256 totalBefore = vault.totalActiveOrders();

        uint256 newId = vault.exposedSwitchCore(
            id,
            SRC,
            DST
        );

        assert(
            vault.totalActiveOrders() == totalBefore
        );

        assert(
            vault.activeOrderCountByIncentive(SRC)
                + vault.activeOrderCountByIncentive(DST) == totalBefore
        );

        assert(
            vault.activeOrderCountByIncentive(SRC) == 0
        );

        assert(
            vault.activeOrderCountByIncentive(DST) == 1
        );

        (
            ,
            uint256 movedAmount,
            ,
        ) = vault.QueMemberByIdAndIncentive(
            newId,
            DST
        );

        assert(
            movedAmount == _amount
        );
    }
}
