// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {BridgeHeadroomProofHarness} from "./BridgeHeadroomProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @title BridgeHeadroomPropertiesTest
 * @dev Dual-engine property suite for BRG-5, the bridge
 * room-conservation law behind the plain deposit-cap check
 * (`WiseSovrenNodesCrossChainHelper` + `_checkDepositCap`):
 *
 *   room := totalDepositCap - totalSupply
 *
 * Relocations MOVE deposit-cap budget with the shares. A bridge-IN
 * raises `totalDepositCap` by `amount` (`_raiseDepositCap`, before
 * the mint) and mints `amount`, so the two sides move in lockstep and
 * room is preserved — the receive-path mint can mathematically never
 * exceed the raised cap, and `ccipReceive` carries no economic revert
 * path at all (only the router, peer, replay and zero-amount guards).
 * A bridge-OUT burns `amount` and lowers `totalDepositCap` by
 * `amount` (`_reduceDepositCap` after the burn), so room is preserved
 * on the way out as well and the mesh-wide cap sum is conserved by
 * user flows.
 *
 * Both properties compare room in all-addition form —
 *
 *   capAfter + supplyBefore == capBefore + supplyAfter
 *
 * with the per-side deltas stated additively as well
 * (`capAfter == capBefore + amount` on receive,
 * `capAfter + amount == capBefore` on bridge-out) — because
 * subtraction forms would demand underflow side conditions on the
 * symbolic pre-state. Every operand is bounded by `MAX_BASE`, so the
 * sums stay far below 2**256. The pre-state assumes
 * `supply <= cap`, the reachable-state invariant the cap-setter
 * floor (`DepositCapBelowSupply`) and cap-checked mints enforce
 * on-chain.
 *
 * Every `testFuzz_*` is (a) fuzzable by Foundry (`forge test`) and (b)
 * symbolically provable by Kontrol
 * (`kontrol prove --match-test 'BridgeHeadroomPropertiesTest.<fn>'`).
 * As in the QLV-5 suite, the payload is pinned to the 64-byte legacy
 * `(address, uint256)` shape and the message id is a concrete
 * representative (a fully symbolic mapping key does not terminate);
 * the amount, the pre-supply and the pre-cap stay symbolic. The
 * out-path runs against this test contract acting as a zero-fee CCIP
 * router (`getFee` / `ccipSend` below) with the peer pinned to the
 * local decimals, so the burned local amount and the relocated cap
 * budget coincide exactly as they do on a live same-decimals lane;
 * the decimals-scaling dimension only affects the DESTINATION amount,
 * never the local burn the cap relocation records.
 */
contract BridgeHeadroomPropertiesTest is Test {

    BridgeHeadroomProofHarness internal vault;

    uint256 internal constant MAX_BASE = 1e40;

    uint256 internal constant T0 = 1_700_000_000;

    uint64 internal constant SEL = 7777;

    bytes32 internal constant MSG_ID = bytes32(uint256(0xC0FFEE02));

    address internal constant PEER = address(0xFEED);
    address internal constant USER = address(0xBEEF);

    uint8 internal constant DECIMALS = 6;

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        vault = new BridgeHeadroomProofHarness(
            _params()
        );

        vault.harnessSetRouter(
            address(this)
        );

        vault.harnessSetPeer(
            SEL,
            PEER,
            DECIMALS,
            true
        );

        vault.harnessSetLastSync(
            USER,
            T0
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
        params.totalDepositCap = 1e30;
        params.interestRate = 2_000;
        params.decimalsValue = DECIMALS;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "wsnUSDC";
    }

    function _legacyMessage(
        bytes32 _messageId,
        address _sender,
        uint256 _amount
    )
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: SEL,
            sender: abi.encode(_sender),
            data: abi.encode(USER, _amount),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    // ---- zero-fee CCIP router mock (out-path scaffolding) ----

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        payable
        returns (bytes32)
    {
        return MSG_ID;
    }

    /**
     * @dev Bridge-in half of BRG-5: for ANY payload amount and ANY
     * cap/supply pre-state, a delivered `ccipReceive` raises the cap
     * and mints in lockstep — `capAfter == capBefore + amount`,
     * `supplyAfter == supplyBefore + amount`, the mint exact — so the
     * room is preserved term for term; or it reverts wholesale
     * (router / peer / replay / zero amount — there is no economic
     * gate), leaving cap and supply untouched. Relocation is never
     * origination: arriving shares bring their deposit-cap budget
     * along and change nothing about the local room.
     */
    function testFuzz_BRG5_receivePreservesRoom(
        uint256 _amount,
        uint256 _preSupply,
        uint256 _preCap
    )
        public
    {
        vm.assume(
            _amount <= MAX_BASE
        );

        vm.assume(
            _preSupply <= MAX_BASE
        );

        vm.assume(
            _preCap <= MAX_BASE
        );

        vm.assume(
            _preSupply <= _preCap
        );

        vault.harnessMint(
            USER,
            _preSupply
        );

        vault.harnessSetCap(
            _preCap
        );

        uint256 capBefore = vault.totalDepositCap();
        uint256 supplyBefore = vault.totalSupply();
        uint256 balanceBefore = vault.balanceOf(USER);

        try vault.exposedExecuteBridgeReceive(_legacyMessage(MSG_ID, PEER, _amount)) {
            assert(
                vault.totalDepositCap() == capBefore + _amount
            );

            assert(
                vault.totalSupply() == supplyBefore + _amount
            );

            assert(
                vault.balanceOf(USER) == balanceBefore + _amount
            );

            assert(
                vault.totalDepositCap() + supplyBefore
                    == capBefore + vault.totalSupply()
            );
        } catch {
            assert(
                vault.totalDepositCap() == capBefore
            );

            assert(
                vault.totalSupply() == supplyBefore
            );
        }
    }

    /**
     * @dev Bridge-out half of BRG-5: for ANY amount and ANY cap/supply
     * pre-state, `bridgeToVault`'s burn-and-send core lowers the cap
     * and burns in lockstep — `capAfter + amount == capBefore`,
     * `supplyAfter + amount == supplyBefore` — so the room is
     * preserved term for term; or it reverts wholesale (zero amount,
     * insufficient balance), leaving cap and supply untouched.
     * Departing shares take their deposit-cap budget with them:
     * bridging away neither frees nor strands local origination
     * budget.
     */
    function testFuzz_BRG5_bridgeOutPreservesRoom(
        uint256 _amount,
        uint256 _preBalance,
        uint256 _preCap
    )
        public
    {
        vm.assume(
            _amount <= MAX_BASE
        );

        vm.assume(
            _preBalance <= MAX_BASE
        );

        vm.assume(
            _preCap <= MAX_BASE
        );

        vm.assume(
            _preBalance <= _preCap
        );

        vault.harnessMint(
            address(this),
            _preBalance
        );

        vault.harnessSetCap(
            _preCap
        );

        uint256 capBefore = vault.totalDepositCap();
        uint256 supplyBefore = vault.totalSupply();

        try vault.exposedExecuteBridgeOut(SEL, _amount, "") {
            assert(
                vault.totalDepositCap() + _amount == capBefore
            );

            assert(
                vault.totalSupply() + _amount == supplyBefore
            );

            assert(
                vault.totalDepositCap() + supplyBefore
                    == capBefore + vault.totalSupply()
            );
        } catch {
            assert(
                vault.totalDepositCap() == capBefore
            );

            assert(
                vault.totalSupply() == supplyBefore
            );
        }
    }
}
