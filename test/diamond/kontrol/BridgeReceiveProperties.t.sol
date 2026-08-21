// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {BridgeReceiveProofHarness} from "./BridgeReceiveProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @title BridgeReceivePropertiesTest
 * @dev Dual-engine property suite for QLV-5, the bridge-receive
 * atomicity law:
 *
 *   `processedMessageId[id] == true  ⟺  the mint for id succeeded`
 *
 * Between the burn on the source chain and the mint here, a user's
 * shares exist only as an in-flight CCIP message. The one failure mode
 * that would destroy them forever is a message marked processed
 * WITHOUT its mint (or a mint without its mark, allowing a double
 * spend). Because the flag write and the mint share one transaction,
 * the ⟺ reduces to per-execution lemmas Kontrol can prove over all
 * inputs: a successful delivery always sets the flag AND mints exactly
 * the payload amount; a failed delivery reverts wholesale, leaving the
 * flag unset so CCIP manual re-execution can retry; a marked message
 * can never mint again.
 *
 * Every `testFuzz_*` is (a) fuzzable by Foundry (`forge test`) and (b)
 * symbolically provable by Kontrol
 * (`kontrol prove --match-test 'BridgeReceivePropertiesTest.<fn>'`).
 * The payload is pinned to its two length shapes — the 64-byte legacy
 * `(address, uint256)` encoding and one referral-carrying
 * `(address, uint256, bytes)` encoding — because the decode branch is
 * selected purely by payload length; amounts, pre-balances and gate
 * flags stay symbolic. The message id is a concrete representative
 * (the symbolic engine does not terminate on a fully symbolic mapping
 * key, and no code path reads the id's content — it is only a lookup
 * key); the id dimension is covered by the Foundry fuzz campaign.
 *
 * The receive path carries NO economic gate: beyond the router
 * authentication, the peer enabled + match checks, the replay flag
 * and the `amount > 0` sanity check, delivery is unconditional. The
 * relocated deposit-cap budget arrives with the shares —
 * `totalDepositCap += amount` immediately before the uncapped mint —
 * so the mint can mathematically never exceed the raised cap. Each
 * lemma therefore also pins the cap delta: a successful delivery
 * raises `totalDepositCap` by exactly the payload amount, a failed
 * delivery leaves it untouched.
 */
contract BridgeReceivePropertiesTest is Test {

    BridgeReceiveProofHarness internal vault;

    uint256 internal constant MAX_BASE = 1e40;

    uint256 internal constant T0 = 1_700_000_000;

    uint64 internal constant SEL = 7777;

    bytes32 internal constant MSG_ID = bytes32(uint256(0xC0FFEE01));

    address internal constant PEER = address(0xFEED);
    address internal constant WRONG_PEER = address(0xBAD0);
    address internal constant USER = address(0xBEEF);

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        vault = new BridgeReceiveProofHarness(
            _params()
        );

        vault.harnessSetRouter(
            address(this)
        );

        vault.harnessSetPeer(
            SEL,
            PEER,
            true
        );

        vault.harnessSetLastSync(
            USER,
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
        params.decimalsValue = 6;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "WTN";
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

    function _referralMessage(
        bytes32 _messageId,
        uint256 _amount
    )
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: SEL,
            sender: abi.encode(PEER),
            data: abi.encode(USER, _amount, bytes("ref-code-01")),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /**
     * @dev Replay half of the ⟺: once a message id is marked
     * processed, delivery reverts for ANY payload amount, and neither
     * the supply, the user balance nor the deposit cap moves. A marked
     * message can never mint again.
     */
    function testFuzz_QLV5_replayAlwaysReverts(
        uint256 _amount
    )
        public
    {
        vault.harnessSetProcessed(
            MSG_ID
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 balanceBefore = vault.balanceOf(USER);
        uint256 capBefore = vault.totalDepositCap();

        try vault.exposedExecuteBridgeReceive(_legacyMessage(MSG_ID, PEER, _amount)) {
            assert(
                false
            );
        } catch {}

        assert(
            vault.processedMessageId(MSG_ID) == true
        );

        assert(
            vault.totalSupply() == supplyBefore
        );

        assert(
            vault.balanceOf(USER) == balanceBefore
        );

        assert(
            vault.totalDepositCap() == capBefore
        );
    }

    /**
     * @dev Success half of the ⟺: on a routed lane with a fresh id
     * and a positive amount, delivery always succeeds, marks the id
     * processed, raises the deposit cap by EXACTLY the payload amount
     * and mints EXACTLY the payload amount to the payload user — on
     * top of any pre-existing balance, for any amounts.
     */
    function testFuzz_QLV5_successSetsFlagAndMintsExactly(
        uint256 _amount,
        uint256 _preBalance
    )
        public
    {
        vm.assume(
            _amount > 0 && _amount <= MAX_BASE
        );

        vm.assume(
            _preBalance <= MAX_BASE
        );

        vault.harnessMint(
            USER,
            _preBalance
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 capBefore = vault.totalDepositCap();

        vault.exposedExecuteBridgeReceive(
            _legacyMessage(
                MSG_ID,
                PEER,
                _amount
            )
        );

        assert(
            vault.processedMessageId(MSG_ID) == true
        );

        assert(
            vault.balanceOf(USER) == _preBalance + _amount
        );

        assert(
            vault.totalSupply() == supplyBefore + _amount
        );

        assert(
            vault.totalDepositCap() == capBefore + _amount
        );
    }

    /**
     * @dev The full ⟺ over symbolic gates: for ANY combination of
     * lane-enabled, peer-match, already-processed and amount, the
     * delivery either succeeds — which happens EXACTLY when every gate
     * passes — setting the flag, raising the deposit cap by the amount
     * and minting the amount, or reverts wholesale leaving the flag,
     * the cap and the supply untouched. The four gates are the ENTIRE
     * revert surface of the receive path — there is no economic gate —
     * so no path marks without minting, no path mints without marking,
     * and a failed delivery stays retryable.
     */
    function testFuzz_QLV5_flagAndMintAreAtomic(
        uint256 _amount,
        bool _enabled,
        bool _peerMatches,
        bool _preProcessed
    )
        public
    {
        vm.assume(
            _amount <= MAX_BASE
        );

        vault.harnessSetPeer(
            SEL,
            PEER,
            _enabled
        );

        if (_preProcessed) {
            vault.harnessSetProcessed(
                MSG_ID
            );
        }

        address sender = _peerMatches
            ? PEER
            : WRONG_PEER;

        uint256 supplyBefore = vault.totalSupply();
        uint256 capBefore = vault.totalDepositCap();

        bool gatesPass = _enabled
            && _peerMatches
            && _preProcessed == false
            && _amount > 0;

        try vault.exposedExecuteBridgeReceive(_legacyMessage(MSG_ID, sender, _amount)) {
            assert(
                gatesPass
            );

            assert(
                vault.processedMessageId(MSG_ID) == true
            );

            assert(
                vault.totalSupply() == supplyBefore + _amount
            );

            assert(
                vault.totalDepositCap() == capBefore + _amount
            );
        } catch {
            assert(
                gatesPass == false
            );

            assert(
                vault.processedMessageId(MSG_ID) == _preProcessed
            );

            assert(
                vault.totalSupply() == supplyBefore
            );

            assert(
                vault.totalDepositCap() == capBefore
            );
        }
    }

    /**
     * @dev At-most-once, end to end: a successful delivery followed by
     * a redelivery of the identical message reverts the second time,
     * and the total minted — and the total deposit-cap budget imported
     * — over both attempts is exactly one payload amount.
     */
    function testFuzz_QLV5_secondDeliverySameIdReverts(
        uint256 _amount
    )
        public
    {
        vm.assume(
            _amount > 0 && _amount <= MAX_BASE
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 capBefore = vault.totalDepositCap();

        vault.exposedExecuteBridgeReceive(
            _legacyMessage(
                MSG_ID,
                PEER,
                _amount
            )
        );

        try vault.exposedExecuteBridgeReceive(_legacyMessage(MSG_ID, PEER, _amount)) {
            assert(
                false
            );
        } catch {}

        assert(
            vault.totalSupply() == supplyBefore + _amount
        );

        assert(
            vault.balanceOf(USER) == _amount
        );

        assert(
            vault.totalDepositCap() == capBefore + _amount
        );
    }

    /**
     * @dev The referral-carrying payload shape obeys the same law and
     * the referral bytes are transport-only: whether the referral
     * feature is on or off, delivery marks the id, raises the deposit
     * cap by exactly the payload amount and mints exactly the payload
     * amount — the referral data never changes what is minted.
     */
    function testFuzz_QLV5_referralShapeIsTransportOnly(
        uint256 _amount,
        bool _referralEnabled
    )
        public
    {
        vm.assume(
            _amount > 0 && _amount <= MAX_BASE
        );

        vault.harnessSetReferralEnabled(
            _referralEnabled
        );

        uint256 supplyBefore = vault.totalSupply();
        uint256 capBefore = vault.totalDepositCap();

        vault.exposedExecuteBridgeReceive(
            _referralMessage(
                MSG_ID,
                _amount
            )
        );

        assert(
            vault.processedMessageId(MSG_ID) == true
        );

        assert(
            vault.balanceOf(USER) == _amount
        );

        assert(
            vault.totalSupply() == supplyBefore + _amount
        );

        assert(
            vault.totalDepositCap() == capBefore + _amount
        );
    }
}
