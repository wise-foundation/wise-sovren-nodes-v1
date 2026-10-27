// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {BridgeCarryTestCodec} from "./utils/BridgeCarryTestCodec.sol";

contract CarryMockUSD is ERC20 {

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

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Simulates the CCIP router + DON for the bridge-carry suite:
 * `getFee` returns a flat fee and `ccipSend` records the outbound
 * message (data, sender, receiver, id) and then synchronously relays
 * it to the destination diamond's `ccipReceive` (as the DON would
 * after finality). Relay can be switched off so a recorded message
 * can be delivered later via `deliverLast`: after a warp, simulating
 * in-flight time, or a second time, simulating a replay. Each
 * registered diamond maps to the chain selector it lives on so the
 * relayed `Any2EVMMessage` carries the correct source selector.
 */
contract CarryMockRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    bool public relayEnabled = true;

    bytes public lastData;

    address public lastSender;

    address public lastReceiver;

    bytes32 public lastMessageId;

    mapping(address => uint64) public selectorOf;

    function setSelector(
        address _diamond,
        uint64 _selector
    )
        external
    {
        selectorOf[_diamond] = _selector;
    }

    function setRelayEnabled(
        bool _enabled
    )
        external
    {
        relayEnabled = _enabled;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return FIXED_FEE;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        address dest = abi.decode(
            _message.receiver,
            (address)
        );

        lastData = _message.data;
        lastSender = msg.sender;
        lastReceiver = dest;

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                nonce
            )
        );

        nonce++;

        lastMessageId = messageId;

        if (relayEnabled == false) {
            return messageId;
        }

        _deliver(
            dest,
            messageId,
            msg.sender,
            _message.data
        );
    }

    function deliverLast()
        external
    {
        _deliver(
            lastReceiver,
            lastMessageId,
            lastSender,
            lastData
        );
    }

    function _deliver(
        address _dest,
        bytes32 _messageId,
        address _srcSender,
        bytes memory _data
    )
        internal
    {
        IAny2EVMMessageReceiver(_dest).ccipReceive(
            Client.Any2EVMMessage({
                messageId: _messageId,
                sourceChainSelector: selectorOf[_srcSender],
                sender: abi.encode(_srcSender),
                data: _data,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }
}

/**
 * @dev End-to-end suite for the cross-chain cohort bridge carry. Two
 * fully wired diamonds simulate two chains on one EVM, each consulting
 * its OWN {ReferralRegistry} (the per-chain production topology, with
 * distinct chain ranks), joined by a {CarryMockRouter} that relays
 * synchronously so a bridge can be asserted end to end inside one
 * test transaction. Both diamonds route the
 * `cohortBridgeHookSelectors()` and `cohortMoveHookSelectors()` groups
 * and run {CohortHookFacet} as the
 * transfer hook, so the armed path exercises the real capture
 * (`_captureBridgeOutCohort`: clamp to held, reduce the source
 * referrer's book by exactly `carryDelta = min(deficit, burned)`,
 * aggregate lanes onto the wire) and the real apply
 * (`_applyBridgeInCohort`: wholesale payload validation with the
 * `trackedDelta <= mintedAmount` conservation ceiling and the post-mint
 * headroom ceiling, origin-key merge into the local registry unless
 * that registry quarantines the source chain, lanes aged by the weekly
 * boundaries crossed in flight and landed under the post-merge
 * effective referrer at ring slot `(arrivalWeek + 1) % 52`).
 *
 * Covered behaviors: per-lane conservation across a partial bridge; a
 * full round trip landing at the oldest ring position on each hop
 * without inflating any lane; tracked-only carry for unreferred users;
 * the earliest-key merge on arrival in both directions: a local
 * earlier key keeps the lanes under the local referrer, while a
 * carried earlier key flips the registry but defers the lanes to the
 * OLD referrer through the pending-flip marker (cover preservation)
 * until the permissionless poke migrates the book; the degrade
 * matrix (unarmed destination mints with zero recorder state, and
 * malformed or forged payloads (wrong length, wrong version, forged
 * tracked delta above the mint, referrer-zero with lanes) are
 * discarded while the mint stands); the armed source overriding
 * caller-supplied referral bytes with its own vault-built payload;
 * the unarmed source's carry-shape guard rejecting valid carry bytes
 * from callers while passing arbitrary bytes through; empty-payload
 * suppression for zero-deficit bridges; message replay; weekly
 * boundaries crossed in flight ageing the carried lanes before the
 * arrival landing; ring-lane saturation clipping
 * softly while the book keeps the full pre-clip aggregates; and the
 * applied carry suppressing the legacy `BridgeReferral` fallback even
 * with `referralEnabled` on. A partial bridge over a book that already
 * spans the year-one and year-two ring lanes is asserted lane by lane:
 * what the source rings and book lose equals what the destination
 * lands at its arrival slot, with tracked and score conserved across
 * both chains.
 *
 * Further pins: the armed source's wire is byte-identical between
 * `bridgeToVault` and `bridgeToVaultWithReferral` whatever the caller
 * bytes are, up to the 256-byte cap; a referred holder whose burned
 * slice is entirely untracked headroom sends an empty carry and leaves
 * every book on both chains untouched, a destination with prior
 * tracked credit included, with the fallback silent even under
 * `referralEnabled`; a queue-purchased slice bridged by its buyer sends
 * an empty carry and leaves the seller's book untouched; a lazy deficit
 * still pending from a transfer is destroyed newest lane first by the
 * pre-burn sync and never rides the wire, the two-stage event sequence
 * and the year1/year2 split of the wire pinning the order; a 52-week-old
 * cohort lands in the year2 ring at the arrival slot with the year1 ring
 * untouched; and a 104-week-old cohort lands in the mature lane with no
 * ring write on either chain, a return hop unable to rejuvenate it. A
 * bridge settles the mover's self crumb at both ends before either
 * tracked write: the source word to the bridge instant at the
 * pre-clamp stake, and the destination word stamped at the delivery
 * with no history before the carried tracked delta lands. Both
 * diamonds also route the queue facets so the purchase path can reach a
 * bridge.
 *
 * The wire is codec version 2: the envelope word carries the capture
 * week (the source chain's `block.timestamp / 1 weeks` at the send)
 * beside the origin sync key, and a version 1 payload is discarded. The
 * destination ages the three carried aggregates by the boundaries
 * crossed in flight before the oldest-position landing: one to 52
 * boundaries move the year-one total onto the year-two ring and the
 * year-two total onto the mature lane, more than 52 move everything to
 * the mature lane, and a capture week past the arrival week counts as
 * no boundary crossed, so a hop across a graduation boundary and
 * straight back cannot hold a stake at the year-one tier. A destination
 * registry that quarantines the source chain (a sync peer removed by
 * master, or a lane master braked without ever peering it) skips the
 * origin-key merge, so the carried key never flips the local answer
 * and the lanes land under the local referrer; the peer executed
 * again lifts the flag and the merge applies as before.
 *
 * Corrected pairs ride the carry like any other pair. A correction
 * executed at clock T mints the timestamp field
 * SYNC_KEY_MIRROR - T (SYNC_KEY_MIRROR = 2 * 1_700_000_000 - 1 =
 * 3_399_999_999, the registry's floor mirrored) with the executing
 * registry's rank, so a bridge-out right after the execute puts the
 * corrected referrer and that mirrored key on the wire, and a
 * record-less destination adopts the corrected pair from the carry
 * alone, before any sync, with no flip marked and the lanes landing
 * under the corrected referrer. A stale carry of the old genuine pair
 * arriving after the corrected pair is already held loses the merge
 * (its key is larger), so the destination keeps the corrected answer
 * and lands the lanes under it while the applied event still reports
 * the carried referrer. A forged carry whose timestamp field is one,
 * far below the lowest key the destination registry admits, is
 * refused inside the guarded merge: the user stays unassigned, the
 * tracked delta lands, and the carried book is dropped with
 * {CohortBridgeCarryBookDropped}.
 *
 * While a flip marker stands on the source the sent event names both
 * referrers: the raw one the envelope carries (indexed) and the book
 * the capture charged.
 */
contract WiseSovrenNodesCohortBridgeCarryTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DEPOSIT_B = 1_000 * 1e6;

    uint256 internal constant BRIDGE_AMOUNT = 2_000 * 1e6;

    uint256 internal constant FEE = 0.01 ether;

    uint64 internal constant SELECTOR_A = 1111;

    uint64 internal constant SELECTOR_B = 2222;

    uint256 internal constant SYNC_KEY_MIRROR = 3_399_999_999;

    bytes32 internal constant APPLIED_TOPIC = keccak256(
        "CohortBridgeCarryApplied(address,uint64,address,address,uint256,uint256,uint256,uint256)"
    );

    bytes32 internal constant DISCARDED_TOPIC = keccak256(
        "CohortBridgeCarryDiscarded(address,uint64)"
    );

    bytes32 internal constant BRIDGE_REFERRAL_TOPIC = keccak256(
        "BridgeReferral(address,uint64,bytes32,bytes)"
    );

    bytes32 internal constant SENT_TOPIC = keccak256(
        "CohortBridgeCarrySent(address,uint64,address,uint256,uint256,uint256,uint256,address)"
    );

    bytes32 internal constant SKIPPED_TOPIC = keccak256(
        "CohortBridgeCarrySkipped(address,uint64)"
    );

    bytes32 internal constant SYNCED_TOPIC = keccak256(
        "CohortContributionSynced(address,address,uint256,uint256)"
    );

    bytes32 internal constant FLIP_MARKED_TOPIC = keccak256(
        "FlipMarked(address,address,address)"
    );

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal buyer = address(0xC2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal refC = address(0xB3);

    WiseSovrenNodesDiamond internal vaultA;
    WiseSovrenNodesDiamond internal vaultB;

    CarryMockUSD internal usdA;
    CarryMockUSD internal usdB;

    ReferralRegistry internal registryA;
    ReferralRegistry internal registryB;

    CarryMockRouter internal router;

    event CohortBridgeCarrySent(
        address indexed user,
        uint64 indexed dstChainSelector,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        address bookReferrer
    );

    event CohortBridgeCarryApplied(
        address indexed user,
        uint64 indexed srcChainSelector,
        address indexed effectiveReferrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarryDiscarded(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortBridgeCarryBookDropped(
        address indexed user,
        uint64 indexed srcChainSelector,
        address carriedReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortBookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortDivestDrained(
        address indexed user
    );

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdA = new CarryMockUSD();

        usdB = new CarryMockUSD();

        registryA = new ReferralRegistry(
            address(this),
            0
        );

        registryB = new ReferralRegistry(
            address(this),
            1
        );

        router = new CarryMockRouter();

        vaultA = _deployCarryVault(
            address(usdA),
            registryA
        );

        vaultB = _deployCarryVault(
            address(usdB),
            registryB
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridge(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridge(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();
        vaultB.finalizeSetup();

        vm.deal(
            user1,
            100 ether
        );

        vm.deal(
            buyer,
            100 ether
        );
    }

    // ---- fixture helpers ----

    function _deployCarryVault(
        address _usd,
        ReferralRegistry _registry
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireQueueFacets(
            d
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new CohortBridgeHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            d,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            d,
            _registry
        );
    }

    function _wireBridge(
        WiseSovrenNodesDiamond _vault,
        uint64 _peerSelector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _peerSelector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _peerSelector
        );
    }

    function _armBoth()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _armSource()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );
    }

    function _armDest()
        internal
    {
        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _quarantineSourceOnB()
        internal
    {
        registryB.proposeSyncPeer(
            SELECTOR_A,
            address(registryA)
        );

        registryB.executeSyncPeerChange(
            SELECTOR_A
        );

        registryB.removeSyncPeer(
            SELECTOR_A
        );
    }

    function _recorderOf(
        WiseSovrenNodesDiamond d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(d)
        );
    }

    function _usdOf(
        WiseSovrenNodesDiamond d
    )
        internal
        view
        returns (CarryMockUSD)
    {
        return d == vaultA
            ? usdA
            : usdB;
    }

    function _fundAndApproveOn(
        WiseSovrenNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _usdOf(d).mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usdOf(d).approve(
            address(d),
            _amount
        );
    }

    function _depositOn(
        WiseSovrenNodesDiamond d,
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(d)).deposit(
            _amount
        );
    }

    function _depositWithReferralOn(
        WiseSovrenNodesDiamond d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApproveOn(
            d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _bridgeAs(
        address _user,
        WiseSovrenNodesDiamond _src,
        uint64 _destChainSelector,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _user
        );

        BridgeFacet(address(_src)).bridgeToVault{value: FEE}(
            _destChainSelector,
            _amount
        );
    }

    function _deliverCarry(
        uint256 _messageId,
        address _user,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(_messageId),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(
                _user,
                _amount,
                _referralData
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    function _packCarry(
        address _referrer,
        uint256 _version,
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
        returns (bytes memory)
    {
        return _packCarryFromWeek(
            block.timestamp / 1 weeks,
            _referrer,
            _version,
            _trackedDelta,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );
    }

    function _packCarryFromWeek(
        uint256 _captureWeek,
        address _referrer,
        uint256 _version,
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        pure
        returns (bytes memory)
    {
        return BridgeCarryTestCodec._pack(
            _referrer,
            _version,
            _captureWeek,
            _trackedDelta,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );
    }

    function _wireReferralBytes()
        internal
        view
        returns (bytes memory referralData)
    {
        (
            ,
            ,
            referralData
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );
    }

    function _correctedAt(
        uint256 _at
    )
        internal
        pure
        returns (uint256)
    {
        return SYNC_KEY_MIRROR - _at;
    }

    function _landSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks + 1) % 52;
    }

    function _creditSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks) % 52;
    }

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _referralLogData(
        Vm.Log[] memory _logs
    )
        internal
        pure
        returns (bytes memory)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == BRIDGE_REFERRAL_TOPIC) {
                return abi.decode(
                    _logs[i].data,
                    (bytes)
                );
            }
        }

        return "";
    }

    function _assertRingSlotsOf(
        WiseSovrenNodesDiamond d,
        address _referrer,
        uint256 _slot,
        uint256 _year1,
        uint256 _year2
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );

        assertEq(
            uint256(ring1[_slot]),
            _year1
        );

        assertEq(
            uint256(ring2[_slot]),
            _year2
        );
    }

    function _assertWireLanes(
        uint256 _trackedDelta,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
    {
        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            _wireReferralBytes()
        );

        (
            uint256 year1,
            uint256 year2
        ) = CohortWeeks._carryPairSums(
            words,
            3,
            CohortWeeks._bridgeCarryPairCount(
                words[0]
            )
        );

        assertEq(
            words[1] & ((uint256(1) << 128) - 1),
            _trackedDelta
        );

        assertEq(
            year1,
            _year1
        );

        assertEq(
            year2,
            _year2
        );

        assertEq(
            words[2],
            _mature
        );
    }

    function _assertBookOn(
        WiseSovrenNodesDiamond d,
        address _referrer,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
        ) = _recorderOf(d).getCohortBook(
            _referrer
        );

        assertEq(
            year1,
            _year1
        );

        assertEq(
            year2,
            _year2
        );

        assertEq(
            mature,
            _mature
        );
    }

    function _assertRingsZero(
        WiseSovrenNodesDiamond d,
        address _referrer
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );

        for (uint256 i; i < 52; ++i) {
            assertEq(
                uint256(ring1[i]),
                0
            );

            assertEq(
                uint256(ring2[i]),
                0
            );
        }
    }

    function _assertRingOneZero(
        WiseSovrenNodesDiamond d,
        address _referrer
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
        ) = _recorderOf(d).getCohortRings(
            _referrer
        );

        for (uint256 i; i < 52; ++i) {
            assertEq(
                uint256(ring1[i]),
                0
            );
        }
    }

    function _sendYearOneInFlight(
        uint256 _inFlight
    )
        internal
        returns (uint256 sendSlot)
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        sendSlot = _creditSlot();

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            0
        );

        vm.warp(
            block.timestamp + _inFlight
        );
    }

    function _assertSelfCrumbOn(
        WiseSovrenNodesDiamond d,
        address _user,
        uint256 _settledAt,
        uint256 _current,
        uint256 _previous
    )
        internal
        view
    {
        (
            uint256 settledAt,
            uint256 current,
            uint256 previous
        ) = _recorderOf(d).getCohortSelfCrumb(
            _user
        );

        assertEq(
            settledAt,
            _settledAt
        );

        assertEq(
            current,
            _current
        );

        assertEq(
            previous,
            _previous
        );
    }

    // ---- 1. referred partial bridge conserves the book per lane ----

    function test_bridgeToVault_referredPartial_carriesBookAcrossChains()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 landSlot = _creditSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        (
            uint256 year1B,
            uint256 year2B,
            uint256 matureB,
        ) = _recorderOf(vaultB).getCohortBook(
            refA
        );

        assertEq(
            year1B,
            BRIDGE_AMOUNT
        );

        assertEq(
            year2B,
            0
        );

        assertEq(
            matureB,
            0
        );

        (
            uint64[52] memory ring1B,
            uint64[52] memory ring2B
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[landSlot]),
            BRIDGE_AMOUNT
        );

        assertEq(
            uint256(ring2B[landSlot]),
            0
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            )
                + _recorderOf(vaultB).getCohortScore(refA),
            DEPOSIT
        );
    }

    // ---- 2. round trip keeps every slot on both hops, no inflation ----

    function test_bridgeToVault_roundTrip_keepsCreditSlotNoInflation()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        uint256 controlScore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            controlScore
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[creditSlot]),
            DEPOSIT
        );

        _bridgeAs(
            user1,
            vaultB,
            SELECTOR_A,
            DEPOSIT
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            controlScore
        );

        (
            uint64[52] memory ring1A,
        ) = _recorderOf(vaultA).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1A[creditSlot]),
            DEPOSIT
        );

        assertEq(
            uint256(ring1A[landSlot]),
            0
        );

        uint256 ringSum;

        for (uint256 i; i < 52; ++i) {
            ringSum += uint256(ring1A[i]);
        }

        assertEq(
            ringSum,
            DEPOSIT
        );
    }

    // ---- 3. unreferred bridge carries tracked only ----

    function test_bridgeToVault_unreferred_carriesTrackedOnly()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            address(0),
            address(0),
            BRIDGE_AMOUNT,
            0,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            address(0)
        );

        bytes memory wireRef = _wireReferralBytes();

        assertEq(
            wireRef.length,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES
        );

        (
            uint256 word0,
            uint256 word1,
            uint256 word2
        ) = abi.decode(
            wireRef,
            (uint256, uint256, uint256)
        );

        assertEq(
            word0,
            (uint256(3) << 160) | ((block.timestamp / 1 weeks) << 168)
        );

        assertEq(
            word1,
            BRIDGE_AMOUNT
        );

        assertEq(
            word2,
            0
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            address(0)
        );

        assertEq(
            uint256(ring1B[_landSlot()]),
            0
        );
    }

    // ---- 3a. a zero raw referrer with a book answer carries tracked only ----

    function test_bridgeToVault_zeroRawReferrerWithBookAnswer_carriesTrackedOnly()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.mockCall(
            address(registryA),
            abi.encodeWithSelector(
                ReferralRegistry.getReferrerPair.selector,
                user1
            ),
            abi.encode(
                address(0),
                uint256(0),
                uint256(0)
            )
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        vm.clearMockedCalls();

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                CohortBridgeCarryDiscarded.selector
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );
    }

    // ---- 4. merge on arrival: local earlier key wins ----

    function test_ccipReceive_localEarlierKey_landsUnderLocalReferrer()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        uint256 localAssignedAt = block.timestamp;

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 landSlot = _creditSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refB
        );

        (
            address pairReferrer,
            uint256 pairAssignedAt,
            uint256 pairRank
        ) = registryB.getReferrerPair(
            user1
        );

        assertEq(
            pairReferrer,
            refB
        );

        assertEq(
            pairAssignedAt,
            localAssignedAt
        );

        assertEq(
            pairRank,
            1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refB
        );

        assertEq(
            uint256(ring1B[landSlot]),
            DEPOSIT_B + BRIDGE_AMOUNT
        );
    }

    function test_ccipReceive_parkedThirdParty_drainsAtParkThenSettlesToDelivery()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            DEPOSIT_B,
            refB
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        vm.prank(
            user2
        );

        vaultB.transfer(
            buyer,
            DEPOSIT_B
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        uint256 parkedAt = BASE_TIME + 1 days + 2 weeks;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBookSettled(
            refB,
            BASE_TIME,
            parkedAt,
            2
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortDivestDrained(
            user2
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBookSettled(
            refB,
            parkedAt,
            block.timestamp,
            3
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );
    }

    function test_ccipReceive_parkedThirdParty_stretchPricedAtReconciledLanes()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            DEPOSIT_B,
            refB
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        vm.prank(
            user2
        );

        vaultB.transfer(
            buyer,
            DEPOSIT_B
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        uint256 parkedAt = BASE_TIME + 1 days + 2 weeks;

        uint256 landedAt = block.timestamp;

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorderOf(vaultB).getCohortBook(
            refB
        );

        assertEq(
            lastSettle,
            landedAt
        );

        assertEq(
            year1 + year2 + mature,
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user2
            ),
            0
        );

        _recorderOf(vaultB).advanceBook(
            refB,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        assertEq(
            CohortWeeks._laneY1(
                _recorderOf(vaultB).getCohortWeekCrumb(
                    refB,
                    parkedAt / 1 weeks + 1
                )
            ),
            DEPOSIT_B * 1 weeks
        );

        assertEq(
            CohortWeeks._laneY1(
                _recorderOf(vaultB).getCohortWeekCrumb(
                    refB,
                    parkedAt / 1 weeks + 2
                )
            ),
            DEPOSIT_B * 1 weeks
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );
    }

    function test_ccipReceive_parkedSellerOfAnotherBook_landingBookSettlesToDelivery()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        _depositWithReferralOn(
            vaultB,
            user2,
            DEPOSIT_B,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        vm.prank(
            user2
        );

        vaultB.transfer(
            buyer,
            DEPOSIT_B
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        uint256 parkedAt = BASE_TIME + 1 days + 2 weeks;

        uint256 landedAt = block.timestamp;

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorderOf(vaultB).getCohortBook(
            refB
        );

        assertEq(
            lastSettle,
            landedAt
        );

        assertEq(
            year1 + year2 + mature,
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            CohortWeeks._laneY1(
                _recorderOf(vaultB).getCohortWeekCrumb(
                    refB,
                    parkedAt / 1 weeks + 1
                )
            ),
            DEPOSIT_B * 1 weeks
        );

        (
            uint256 year1A,
            uint256 year2A,
            uint256 matureA,
            uint256 lastSettleA
        ) = _recorderOf(vaultB).getCohortBook(
            refA
        );

        assertEq(
            year1A + year2A + matureA,
            DEPOSIT_B
        );

        assertEq(
            lastSettleA,
            BASE_TIME
        );
    }

    // ---- 5. merge on arrival: carried earlier key flips, lanes defer to
    // the old referrer until the poke migrates the book ----

    function test_ccipReceive_carriedEarlierKey_defersLanesToOldReferrerThenPokeMigrates()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        uint256 creditSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            refB
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refB
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refB,
            refA,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0,
            0,
            1
        );

        registryB.pokeMigration(
            user1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refA
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1B[creditSlot]),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            uint256(ring1B[landSlot]),
            0
        );
    }

    // ---- 5a. a destination registry that quarantines the source chain
    // skips the carried key merge and lands under the local referrer ----

    function test_ccipReceive_quarantinedSourceChain_landsUnderLocalReferrerNoMerge()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        uint256 localAssignedAt = block.timestamp;

        _quarantineSourceOnB();

        assertTrue(
            registryB.syncPeerQuarantined(
                SELECTOR_A
            )
        );

        uint256 landSlot = _creditSlot();

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                FLIP_MARKED_TOPIC
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refB
        );

        (
            address pairReferrer,
            uint256 pairAssignedAt,
            uint256 pairRank
        ) = registryB.getReferrerPair(
            user1
        );

        assertEq(
            pairReferrer,
            refB
        );

        assertEq(
            pairAssignedAt,
            localAssignedAt
        );

        assertEq(
            pairRank,
            1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refB,
            landSlot,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0
        );
    }

    // ---- 5b. the peer executed again lifts the quarantine and the
    // carried earlier key merges and flips as before ----

    function test_ccipReceive_quarantineLifted_mergesAgain()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        _quarantineSourceOnB();

        registryB.proposeSyncPeer(
            SELECTOR_A,
            address(registryA)
        );

        registryB.executeSyncPeerChange(
            SELECTOR_A
        );

        assertFalse(
            registryB.syncPeerQuarantined(
                SELECTOR_A
            )
        );

        uint256 landSlot = _creditSlot();

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                FLIP_MARKED_TOPIC
            ),
            1
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            refB
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refB,
            refA,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0,
            0,
            1
        );

        registryB.pokeMigration(
            user1
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            landSlot,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0
        );
    }

    // ---- 5c. a source chain the destination registry never peered,
    // braked there all the same, skips the carried key merge ----

    function test_ccipReceive_neverPeeredSourceBraked_landsUnderLocalReferrerNoMerge()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        assertEq(
            registryB.syncPeer(
                SELECTOR_A
            ),
            address(0)
        );

        registryB.removeSyncPeer(
            SELECTOR_A
        );

        assertTrue(
            registryB.syncPeerQuarantined(
                SELECTOR_A
            )
        );

        uint256 landSlot = _creditSlot();

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                FLIP_MARKED_TOPIC
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refB,
            landSlot,
            DEPOSIT_B + BRIDGE_AMOUNT,
            0
        );
    }

    // ---- 6. unarmed destination mints with zero recorder state ----

    function test_bridgeToVault_destUnarmed_mintsWithoutRecorderState()
        public
    {
        _armSource();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            1_000 * 1e6
        );

        logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            1
        );

        bytes memory fallbackData = _referralLogData(
            logs
        );

        assertEq(
            fallbackData.length,
            128
        );

        assertEq(
            keccak256(
                fallbackData
            ),
            keccak256(
                _wireReferralBytes()
            )
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- 7. garbage referral bytes are discarded, mint stands ----

    function test_ccipReceive_garbageReferralData_discardedMintFine()
        public
    {
        _armDest();

        bytes memory garbage = hex"deadbeef";

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x700,
            user1,
            1_000 * 1e6,
            garbage
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- 8. a version one payload is discarded as a version mismatch ----

    function test_ccipReceive_versionMismatch_discarded()
        public
    {
        _armDest();

        bytes memory payload = _packCarry(
            refA,
            1,
            1_000 * 1e6,
            block.timestamp,
            0,
            1_000 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x701,
            user1,
            1_000 * 1e6,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- 9. forged tracked delta above the mint is discarded ----

    function test_ccipReceive_trackedDeltaAboveMint_discarded()
        public
    {
        _armDest();

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            3,
            amount + 1,
            block.timestamp,
            0,
            amount + 1,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x702,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            amount
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- 10. zero referrer with lanes is discarded ----

    function test_ccipReceive_zeroReferrerWithLanes_discarded()
        public
    {
        _armDest();

        bytes memory payload = _packCarry(
            address(0),
            3,
            500 * 1e6,
            0,
            0,
            500 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        _deliverCarry(
            0x703,
            user1,
            500 * 1e6,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- 11. armed source ignores caller referral bytes ----

    function test_bridgeToVaultWithReferral_armedSource_ignoresUserBytes()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 assignedAt = block.timestamp;

        bytes memory userBytes = abi.encode(
            uint256(42),
            address(0xCAFE)
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            userBytes
        );

        (
            address wireUser,
            uint256 wireAmount,
            bytes memory wireRef
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );

        assertEq(
            wireUser,
            user1
        );

        assertEq(
            wireAmount,
            BRIDGE_AMOUNT
        );

        assertEq(
            wireRef.length,
            128
        );

        assertTrue(
            keccak256(wireRef) != keccak256(userBytes)
        );

        (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        ) = abi.decode(
            wireRef,
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            address(uint160(word0)),
            refA
        );

        assertEq(
            (word0 >> 160) & 0xff,
            3
        );

        assertEq(
            word1 & ((uint256(1) << 128) - 1),
            BRIDGE_AMOUNT
        );

        assertEq(
            (word1 >> 128) & type(uint64).max,
            assignedAt
        );

        assertEq(
            (word1 >> 192) & 0xff,
            0
        );

        assertEq(
            CohortWeeks._carryPairAmount(
                CohortWeeks._carryPairLo(
                    word3
                )
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            CohortWeeks._carryPairHi(
                word3
            ),
            0
        );

        assertEq(
            word2,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 12. unarmed source rejects valid carry bytes from callers ----

    function test_bridgeToVaultWithReferral_unarmedSource_validCarryBytes_reverts()
        public
    {
        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        bytes memory forged = _packCarry(
            address(0xBEEF),
            3,
            100,
            block.timestamp,
            0,
            100,
            0,
            0
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralDataReserved.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            forged
        );
    }

    // ---- 13. unarmed source passes arbitrary bytes through ----

    function test_bridgeToVaultWithReferral_unarmedSource_arbitraryBytesPassThrough()
        public
    {
        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        bytes memory userBytes = abi.encode(
            uint256(7),
            address(0xBEEF)
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            userBytes
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            keccak256(
                _wireReferralBytes()
            ),
            keccak256(
                userBytes
            )
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            1
        );

        assertEq(
            keccak256(
                _referralLogData(
                    logs
                )
            ),
            keccak256(
                userBytes
            )
        );
    }

    // ---- 14. zero deficit suppresses the wire payload ----

    function test_bridgeToVault_zeroDeficit_emptyWirePayload()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            buyer,
            BRIDGE_AMOUNT
        );

        uint256 scoreBefore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            buyer,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _wireReferralBytes().length,
            0
        );

        assertEq(
            vaultB.balanceOf(
                buyer
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                buyer
            ),
            0
        );

        assertEq(
            scoreBefore,
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                DISCARDED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );
    }

    // ---- 15. a replayed carry message cannot apply twice ----

    function test_ccipReceive_replayedCarryMessage_reverts()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        uint256 trackedAfter = _recorderOf(vaultB).getTrackedContribution(
            user1
        );

        uint256 scoreAfter = _recorderOf(vaultB).getCohortScore(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.MessageAlreadyProcessed.selector
        );

        router.deliverLast();

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            trackedAfter
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            scoreAfter
        );
    }

    // ---- 16. a message in flight over one week boundary lands its
    // year-one aggregate one tier older ----

    function test_bridgeToVault_weekBoundaryInFlight_keepsYearOneAndScore()
        public
    {
        uint256 sendSlot = _sendYearOneInFlight(
            1 weeks
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        router.deliverLast();

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            sendSlot,
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            BRIDGE_AMOUNT,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 16a. two week boundaries in flight still land the year-one
    // aggregate on the year-two ring ----

    function test_bridgeToVault_twoWeekBoundariesInFlight_year1KeepsItsSlot()
        public
    {
        uint256 sendSlot = _sendYearOneInFlight(
            2 weeks
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        router.deliverLast();

        _assertRingSlotsOf(
            vaultB,
            refA,
            sendSlot,
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            BRIDGE_AMOUNT,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 16b. a year-two cohort in flight over one week boundary lands
    // on the mature lane with no ring write ----

    function test_bridgeToVault_year2CohortBoundaryInFlight_staysOnRingTwoAtItsSlot()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        vm.warp(
            block.timestamp + 52 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            DEPOSIT,
            0
        );

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        router.deliverLast();

        _assertRingOneZero(
            vaultB,
            refA
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            0,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 16c. fifty-two boundaries in flight keep the year-one
    // aggregate on the year-two ring ----

    function test_bridgeToVault_fiftyTwoBoundariesInFlight_staysOnRingTwo()
        public
    {
        uint256 sendSlot = _sendYearOneInFlight(
            52 weeks
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        router.deliverLast();

        _assertRingOneZero(
            vaultB,
            refA
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            sendSlot,
            0,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );
    }

    // ---- 16d. fifty-three boundaries in flight move the year-one
    // aggregate to the mature lane ----

    function test_bridgeToVault_fiftyThreeBoundariesInFlight_landsOnRingTwoAtItsSlot()
        public
    {
        uint256 sendSlot = _sendYearOneInFlight(
            53 weeks
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        router.deliverLast();

        _assertRingOneZero(
            vaultB,
            refA
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            sendSlot,
            0,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 16e. a capture week past the arrival week lands as if no
    // boundary crossed ----

    function test_ccipReceive_captureWeekPastArrival_landsWithoutAgeing()
        public
    {
        _armDest();

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarryFromWeek(
            block.timestamp / 1 weeks + 5,
            refA,
            3,
            amount,
            block.timestamp,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            amount,
            amount,
            0,
            0
        );

        _deliverCarry(
            0x704,
            user1,
            amount,
            payload
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            _creditSlot(),
            amount,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            amount,
            0,
            0
        );
    }

    // ---- 16f. a hop across a graduation boundary and straight back
    // cannot hold the stake at the year-one tier ----

    function test_bridgeToVault_hopAcrossGraduationBoundary_cannotHoldYearOne()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            BRIDGE_AMOUNT,
            refA
        );

        uint256 creditWeek = block.timestamp / 1 weeks;

        vm.warp(
            (creditWeek + 52) * 1 weeks - 1 hours
        );

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        vm.warp(
            block.timestamp + 2 hours
        );

        assertEq(
            block.timestamp / 1 weeks,
            creditWeek + 52
        );

        router.deliverLast();

        uint256 creditSlot = creditWeek % 52;

        _assertRingOneZero(
            vaultB,
            refA
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            0,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );

        router.setRelayEnabled(
            true
        );

        _bridgeAs(
            user1,
            vaultB,
            SELECTOR_A,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        _assertRingOneZero(
            vaultA,
            refA
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            creditSlot,
            0,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- 16g. the wire of a real bridge-out carries version 3 and the
    // capture week ----

    function test_bridgeOut_wireCarriesCaptureWeekAndVersionThree()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 3 weeks + 2 days
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        uint256 word0 = CohortWeeks._unpackBridgeCarry(
            _wireReferralBytes()
        )[0];

        assertEq(
            CohortWeeks._carryEnvelopeReferrer(
                word0
            ),
            refA
        );

        assertEq(
            CohortWeeks._carryEnvelopeVersion(
                word0
            ),
            3
        );

        assertEq(
            CohortWeeks._bridgeCarryPairCount(
                word0
            ),
            1
        );

        assertEq(
            CohortWeeks._bridgeCarryCaptureWeek(
                word0
            ),
            block.timestamp / 1 weeks
        );

        assertEq(
            CohortWeeks._bridgeCarryCaptureWeek(
                word0
            ),
            BASE_TIME / 1 weeks + 3
        );

        assertEq(
            word0 >> 208,
            0
        );
    }

    // ---- 17. ring lane saturation clips softly, book keeps the full
    // aggregates ----

    function test_ccipReceive_laneSaturation_clipsRingKeepsBook()
        public
    {
        _armDest();

        address fUser = address(0xF1);
        address fRef = address(0xB3);

        uint256 big = uint256(type(uint64).max) - 5;
        uint256 topUp = 100;

        uint256 slot = _creditSlot();

        bytes memory first = _packCarry(
            fRef,
            3,
            big,
            block.timestamp,
            2,
            big,
            0,
            0
        );

        bytes memory second = _packCarry(
            fRef,
            3,
            topUp,
            block.timestamp,
            2,
            topUp,
            0,
            0
        );

        _deliverCarry(
            0x710,
            fUser,
            big,
            first
        );

        (
            uint64[52] memory ring1Before,
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring1Before[slot]),
            big
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultB)
        );

        emit CohortLaneSaturated(
            fRef,
            0,
            slot,
            95
        );

        _deliverCarry(
            0x711,
            fUser,
            topUp,
            second
        );

        (
            uint64[52] memory ring1After,
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring1After[slot]),
            uint256(type(uint64).max)
        );

        (
            uint256 year1B,
            ,
            ,
        ) = _recorderOf(vaultB).getCohortBook(
            fRef
        );

        assertEq(
            year1B,
            big + topUp
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                fUser
            ),
            big + topUp
        );
    }

    // ---- 18. an applied carry suppresses the legacy fallback event ----

    function test_ccipReceive_carryApplied_suppressesBridgeReferralFallback()
        public
    {
        _armBoth();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );
    }

    // ---- 19. bridge-out during a pending source flip reduces the
    // cover-holding referrer newest credit first, never the flip winner's
    // other referees, and lands under the destination's own answer at the
    // slot the taken credit held ----

    function test_bridgeOut_duringPendingFlip_reducesCoverReferrerNotWinner()
        public
    {
        _armBoth();

        uint256 olderSlot = _creditSlot();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        uint256 fresherSlot = _creditSlot();

        _depositWithReferralOn(
            vaultA,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            vaultA,
            buyer,
            DEPOSIT,
            refB
        );

        uint256 winnerScoreBefore = _recorderOf(vaultA).getCohortScore(
            refB
        );

        uint256 coverScoreBefore = _recorderOf(vaultA).getCohortScore(
            refA
        );

        vm.prank(
            address(vaultA)
        );

        registryA.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1_000,
            1
        );

        assertEq(
            registryA.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registryA.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refB
            ),
            winnerScoreBefore
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            coverScoreBefore - BRIDGE_AMOUNT
        );

        (
            uint64[52] memory ring1A,
        ) = _recorderOf(vaultA).getCohortRings(
            refA
        );

        assertEq(
            uint256(ring1A[fresherSlot]),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            uint256(ring1A[olderSlot]),
            DEPOSIT
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refB
        );

        (
            uint64[52] memory ring1B,
        ) = _recorderOf(vaultB).getCohortRings(
            refB
        );

        assertEq(
            uint256(ring1B[fresherSlot]),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            BRIDGE_AMOUNT
        );
    }

    function test_bridgeOut_duringPendingFlip_sentEventNamesRawAndChargedReferrer()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            address(vaultA)
        );

        registryA.mergeReferrer(
            user1,
            refB,
            BASE_TIME - 1_000,
            1
        );

        assertEq(
            registryA.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registryA.effectiveReferrerOf(
                user1,
                address(vaultA)
            ),
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refB,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0,
            refA
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                SENT_TOPIC
            ),
            1
        );
    }

    // ---- 20. a partial bridge over a two-lane book conserves every
    // lane across the chains ----

    function test_bridgeToVault_partialMultiLane_conservesPerLaneAcrossChains()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 53 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            2_000 * 1e6,
            refA
        );

        (
            uint256 year1ABefore,
            uint256 year2ABefore,
            uint256 matureABefore,
        ) = _recorderOf(vaultA).getCohortBook(
            refA
        );

        assertEq(
            year1ABefore,
            2_000 * 1e6
        );

        assertEq(
            year2ABefore,
            1_000 * 1e6
        );

        assertEq(
            matureABefore,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            37,
            2_000 * 1e6,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            36,
            0,
            1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        uint256 landSlot = _landSlot();

        assertEq(
            landSlot,
            38
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            2_500 * 1e6,
            2_000 * 1e6,
            500 * 1e6,
            0,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            2_500 * 1e6,
            2_000 * 1e6,
            500 * 1e6,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            2_500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            500 * 1e6
        );

        (
            uint256 year1AAfter,
            uint256 year2AAfter,
            uint256 matureAAfter,
        ) = _recorderOf(vaultA).getCohortBook(
            refA
        );

        assertEq(
            year1AAfter,
            0
        );

        assertEq(
            year2AAfter,
            500 * 1e6
        );

        assertEq(
            matureAAfter,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            37,
            0,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            36,
            0,
            500 * 1e6
        );

        _assertWireLanes(
            2_500 * 1e6,
            2_000 * 1e6,
            500 * 1e6,
            0
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            2_500 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            2_500 * 1e6
        );

        (
            uint256 year1B,
            uint256 year2B,
            uint256 matureB,
        ) = _recorderOf(vaultB).getCohortBook(
            refA
        );

        assertEq(
            year1B,
            2_000 * 1e6
        );

        assertEq(
            year2B,
            500 * 1e6
        );

        assertEq(
            matureB,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            landSlot,
            0,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            37,
            2_000 * 1e6,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            36,
            0,
            500 * 1e6
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            year1ABefore - year1AAfter,
            year1B
        );

        assertEq(
            year2ABefore - year2AAfter,
            year2B
        );

        assertEq(
            matureABefore - matureAAfter,
            matureB
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            )
                + _recorderOf(vaultB).getCohortScore(refA),
            3_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            )
                + _recorderOf(vaultB).getTrackedContribution(user1),
            3_000 * 1e6
        );
    }

    // ---- 21. armed source wire is byte-identical whatever the caller
    // bytes are ----

    function test_bridgeToVaultWithReferral_armedSource_wireByteIdenticalToBridgeToVault()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 snap = vm.snapshotState();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        bytes memory plainData = router.lastData();

        bytes32 plainId = router.lastMessageId();

        bytes memory plainRef = _wireReferralBytes();

        assertEq(
            plainRef.length,
            128
        );

        vm.revertToState(
            snap
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            abi.encode(
                uint256(42),
                address(0xCAFE)
            )
        );

        assertEq(
            keccak256(
                router.lastData()
            ),
            keccak256(
                plainData
            )
        );

        assertEq(
            router.lastMessageId(),
            plainId
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            BRIDGE_AMOUNT
        );

        vm.revertToState(
            snap
        );

        bytes memory junk = new bytes(256);

        for (uint256 i; i < junk.length; ++i) {
            junk[i] = bytes1(uint8(0xEE));
        }

        vm.prank(
            user1
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            BRIDGE_AMOUNT,
            junk
        );

        assertEq(
            keccak256(
                router.lastData()
            ),
            keccak256(
                plainData
            )
        );

        (
            address wireUser,
            uint256 wireAmount,
            bytes memory wireRef
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );

        assertEq(
            wireUser,
            user1
        );

        assertEq(
            wireAmount,
            BRIDGE_AMOUNT
        );

        assertEq(
            keccak256(
                wireRef
            ),
            keccak256(
                plainRef
            )
        );
    }

    // ---- 22. a referred holder's untracked headroom bridges with an
    // empty carry and leaves every book untouched ----

    function test_bridgeToVault_untrackedHeadroom_referredHolder_emptyCarryKeepsBooks()
        public
    {
        _armBoth();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            30 * 1e6,
            refA
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            100 * 1e6,
            refA
        );

        _depositOn(
            vaultA,
            buyer,
            50 * 1e6
        );

        vm.prank(
            buyer
        );

        vaultA.transfer(
            user1,
            50 * 1e6
        );

        uint256 creditSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            100 * 1e6
        );

        vm.recordLogs();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            50 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _wireReferralBytes().length,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            100 * 1e6
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            creditSlot,
            100 * 1e6,
            0
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            80 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            30 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            30 * 1e6
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            landSlot,
            0,
            0
        );

        assertEq(
            _countTopic(
                logs,
                SENT_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SKIPPED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                buyer
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                DISCARDED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );
    }

    // ---- 23. a queue-purchased slice bridged by its buyer sends an
    // empty carry and leaves the seller's book untouched ----

    function test_bridgeToVault_queuePurchasedSlice_emptyCarryKeepsSellerBook()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(vaultA)).joinQue(
            BRIDGE_AMOUNT,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        _fundAndApproveOn(
            vaultA,
            buyer,
            BRIDGE_AMOUNT
        );

        vm.prank(
            buyer
        );

        QueueFulfillFacet(address(vaultA)).fulfillOrder(
            queId,
            0
        );

        assertEq(
            vaultA.balanceOf(
                buyer
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                buyer
            ),
            0
        );

        vm.recordLogs();

        _bridgeAs(
            buyer,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _wireReferralBytes().length,
            0
        );

        assertEq(
            vaultB.balanceOf(
                buyer
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                buyer
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                buyer
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                buyer
            ),
            address(0)
        );

        assertEq(
            _countTopic(
                logs,
                SENT_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SKIPPED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                DISCARDED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                BRIDGE_REFERRAL_TOPIC
            ),
            0
        );

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == SYNCED_TOPIC) {
                assertTrue(
                    logs[i].topics[1] != bytes32(uint256(uint160(buyer)))
                );
            }
        }
    }

    // ---- 24. a lazy deficit pending from a transfer is destroyed newest
    // lane first by the pre-burn sync and never carried ----

    function test_bridgeToVault_pendingLazyDeficit_destroyedNewestFirstNeverCarried()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            30 * 1e6,
            refA
        );

        uint256 oldSlot = _creditSlot();

        vm.warp(
            block.timestamp + 53 weeks
        );

        _depositWithReferralOn(
            vaultA,
            user1,
            70 * 1e6,
            refA
        );

        uint256 newSlot = _creditSlot();

        uint256 landSlot = _landSlot();

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        _assertBookOn(
            vaultA,
            refA,
            70 * 1e6,
            30 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            buyer,
            30 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            100 * 1e6
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            70 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBookReduced(
            refA,
            30 * 1e6,
            30 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            100 * 1e6,
            70 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBookReduced(
            refA,
            50 * 1e6,
            40 * 1e6,
            10 * 1e6,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            70 * 1e6,
            20 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            50 * 1e6,
            40 * 1e6,
            10 * 1e6,
            0,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            50 * 1e6,
            40 * 1e6,
            10 * 1e6,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            50 * 1e6
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            20 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            20 * 1e6
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            20 * 1e6,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            newSlot,
            0,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            oldSlot,
            0,
            20 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            20 * 1e6
        );

        _assertWireLanes(
            50 * 1e6,
            40 * 1e6,
            10 * 1e6,
            0
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            50 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            50 * 1e6
        );

        _assertBookOn(
            vaultB,
            refA,
            40 * 1e6,
            10 * 1e6,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            newSlot,
            40 * 1e6,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            oldSlot,
            0,
            10 * 1e6
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            landSlot,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            50 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            )
                + _recorderOf(vaultB).getCohortScore(refA),
            70 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            )
                + _recorderOf(vaultB).getTrackedContribution(user1),
            70 * 1e6
        );
    }

    // ---- 25. a 52-week-old cohort lands in the year2 ring at its own
    // slot with the year1 ring untouched ----

    function test_bridgeToVault_year2Cohort_landsInYear2RingAtItsSlot()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        vm.warp(
            block.timestamp + 52 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            DEPOSIT,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            creditSlot,
            0,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            0,
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            DEPOSIT - BRIDGE_AMOUNT,
            0
        );

        _assertRingSlotsOf(
            vaultA,
            refA,
            creditSlot,
            0,
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            0,
            BRIDGE_AMOUNT
        );

        (
            uint64[52] memory ring1B,
            uint64[52] memory ring2B
        ) = _recorderOf(vaultB).getCohortRings(
            refA
        );

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {
            assertEq(
                uint256(ring1B[i]),
                0
            );

            ring2Sum += uint256(ring2B[i]);
        }

        assertEq(
            ring2Sum,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            )
                + _recorderOf(vaultB).getCohortScore(refA),
            DEPOSIT
        );
    }

    // ---- 26. a 104-week-old cohort lands in the mature lane with no
    // ring write on either chain and a return hop cannot rejuvenate it ----

    function test_bridgeToVault_matureCohort_landsInMatureLaneNoRingWrite()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 104 weeks
        );

        _recorderOf(vaultA).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            0,
            DEPOSIT
        );

        _assertRingsZero(
            vaultA,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_B,
            refA,
            BRIDGE_AMOUNT,
            0,
            0,
            BRIDGE_AMOUNT,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            BRIDGE_AMOUNT,
            0,
            0,
            BRIDGE_AMOUNT
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            0,
            0,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            0,
            DEPOSIT - BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            0,
            BRIDGE_AMOUNT
        );

        _assertRingsZero(
            vaultB,
            refA
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            )
                + _recorderOf(vaultB).getCohortScore(refA),
            DEPOSIT
        );

        _bridgeAs(
            user1,
            vaultB,
            SELECTOR_A,
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultA,
            refA,
            0,
            0,
            DEPOSIT
        );

        _assertRingsZero(
            vaultA,
            refA
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- 27. a bridge settles the self crumb at both ends ----

    function test_bridgeOut_andBridgeIn_settleSelfCrumbsAtBothEnds()
        public
    {
        _armBoth();

        uint256 bridged = DEPOSIT / 2;

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        uint256 bridgeAt = block.timestamp;

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            bridged
        );

        _assertSelfCrumbOn(
            vaultA,
            user1,
            bridgeAt,
            DEPOSIT * 3 hours,
            DEPOSIT * (1 weeks - 1 hours)
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - bridged
        );

        _assertSelfCrumbOn(
            vaultB,
            user1,
            bridgeAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            bridged
        );
    }

    // ---- 28. a corrected pair rides the carry and lands under the
    // corrected referrer before any sync ----

    function test_ccipReceive_correctedPairLandsBeforeSync()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        registryA.proposeCorrectReferrer(
            user1,
            refC
        );

        uint256 executeTime = BASE_TIME + 3 days;

        vm.warp(
            executeTime
        );

        registryA.executeCorrectReferrer(
            user1
        );

        uint256 correctedAt = _correctedAt(
            executeTime
        );

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        (
            uint256 word0,
            uint256 word1,
            ,
        ) = abi.decode(
            _wireReferralBytes(),
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            CohortWeeks._carryEnvelopeReferrer(
                word0
            ),
            refC
        );

        assertEq(
            CohortWeeks._bridgeCarryAssignedAt(
                word1
            ),
            correctedAt
        );

        assertEq(
            CohortWeeks._bridgeCarryRank(
                word1
            ),
            registryA.LOCAL_CHAIN_RANK()
        );

        _assertWireLanes(
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refC,
            refC,
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT,
            0,
            0
        );

        router.deliverLast();

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registryB.referrerKey(
                user1
            ),
            registryA.referrerKey(
                user1
            )
        );

        (
            address pairReferrer,
            uint256 pairAssignedAt,
            uint256 pairRank
        ) = registryB.getReferrerPair(
            user1
        );

        assertEq(
            pairReferrer,
            refC
        );

        assertEq(
            pairAssignedAt,
            correctedAt
        );

        assertEq(
            pairRank,
            registryA.LOCAL_CHAIN_RANK()
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        _assertRingSlotsOf(
            vaultB,
            refC,
            _creditSlot(),
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultB,
            refC,
            BRIDGE_AMOUNT,
            0,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            0,
            0
        );
    }

    // ---- 29. a stale genuine carry of the old pair arriving after the
    // corrected pair keeps the corrected answer and lands under it ----

    function test_ccipReceive_staleGenuineCarryAfterCorrection_landsUnderCorrected()
        public
    {
        _armDest();

        uint256 amount = 1_000 * 1e6;

        uint256 genuineAt = BASE_TIME - 1 days;

        uint256 correctedAt = _correctedAt(
            BASE_TIME
        );

        vm.prank(
            address(vaultB)
        );

        registryB.mergeReferrer(
            user1,
            refC,
            correctedAt,
            0
        );

        uint256 correctedKey = registryB.referrerKey(
            user1
        );

        (
            ,
            uint256 adoptedAt,
            uint256 adoptedRank
        ) = registryB.getReferrerPair(
            user1
        );

        assertEq(
            adoptedAt,
            correctedAt
        );

        assertEq(
            adoptedRank,
            0
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            genuineAt,
            0,
            amount,
            0,
            0
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refC,
            refA,
            amount,
            amount,
            0,
            0
        );

        _deliverCarry(
            0x801,
            user1,
            amount,
            payload
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                FLIP_MARKED_TOPIC
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refC
        );

        assertEq(
            registryB.referrerKey(
                user1
            ),
            correctedKey
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        _assertRingSlotsOf(
            vaultB,
            refC,
            _creditSlot(),
            amount,
            0
        );

        _assertBookOn(
            vaultB,
            refC,
            amount,
            0,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            0,
            0
        );
    }

    // ---- 30. a forged carry with a key below the admissible floor is
    // refused by the registry, the tracked delta lands, the book drops ----

    function test_ccipReceive_forgedDeepKeyRefused_bookDropped()
        public
    {
        _armDest();

        uint256 amount = 1_000 * 1e6;

        address forgedRef = address(0xBEEF);

        uint256 deepAssignedAt = 1;

        bytes memory payload = _packCarry(
            forgedRef,
            3,
            amount,
            deepAssignedAt,
            0,
            amount,
            0,
            0
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryBookDropped(
            user2,
            SELECTOR_A,
            forgedRef,
            amount,
            0,
            0
        );

        _deliverCarry(
            0x802,
            user2,
            amount,
            payload
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                APPLIED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                DISCARDED_TOPIC
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                user2
            ),
            address(0)
        );

        assertEq(
            registryB.referrerKey(
                user2
            ),
            0
        );

        assertEq(
            vaultB.balanceOf(
                user2
            ),
            amount
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user2
            ),
            amount
        );

        _assertBookOn(
            vaultB,
            forgedRef,
            0,
            0,
            0
        );

        _assertRingsZero(
            vaultB,
            forgedRef
        );
    }

    // ---- exact age: a bridged pair keeps its own slot and ages only by the
    // boundaries crossed in flight ----

    function test_bridgeToVault_freshCreditSameWeek_landsAtItsOwnSlot()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            BRIDGE_AMOUNT,
            0
        );

        _assertRingSlotsOf(
            vaultB,
            refA,
            _landSlot(),
            0,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            BRIDGE_AMOUNT,
            0,
            0
        );
    }

    function test_bridgeToVault_oneBoundaryInFlight_keepsYearOneAtItsSlot()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        router.deliverLast();

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            BRIDGE_AMOUNT,
            0,
            0
        );
    }

    function test_bridgeToVault_lastYearOneWeekInFlight_agesOnceAndGraduatesOnSchedule()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 creditSlot = _creditSlot();

        uint256 creditWeek = block.timestamp / 1 weeks;

        vm.warp(
            block.timestamp + 50 weeks
        );

        router.setRelayEnabled(
            false
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        router.deliverLast();

        _assertRingSlotsOf(
            vaultB,
            refA,
            creditSlot,
            BRIDGE_AMOUNT,
            0
        );

        _assertBookOn(
            vaultB,
            refA,
            BRIDGE_AMOUNT,
            0,
            0
        );

        vm.warp(
            (creditWeek + 52) * 1 weeks
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );

        vm.warp(
            (creditWeek + 104) * 1 weeks - 1
        );

        _recorderOf(vaultB).advanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _assertBookOn(
            vaultB,
            refA,
            0,
            BRIDGE_AMOUNT,
            0
        );
    }

    // ---- moved-amount pins: self log on bridge, unreferred bridges ----

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    function _selfLogsFrom(
        Vm.Log[] memory _logs,
        address _emitter
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (
                _logs[i].emitter == _emitter
                    && _logs[i].topics[0] == CohortSelfLogged.selector
            ) {
                ++count;
            }
        }
    }

    function test_bridgeOut_logsTheCompletedSelfWeekOnTheSourceOnly()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 hours
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortSelfLogged(
            user1,
            BASE_TIME / 1 weeks,
            DEPOSIT * (1 weeks - 1 hours),
            DEPOSIT
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            DEPOSIT / 2
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _selfLogsFrom(
                logs,
                address(vaultA)
            ),
            1
        );

        assertEq(
            _selfLogsFrom(
                logs,
                address(vaultB)
            ),
            0
        );
    }

    function test_bridgeToVault_unreferred_settlesBothCrumbsAttributesNothing()
        public
    {
        _armBoth();

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        uint256 bridgeAt = block.timestamp;

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        _assertSelfCrumbOn(
            vaultA,
            user1,
            bridgeAt,
            DEPOSIT * 1 days,
            0
        );

        _assertSelfCrumbOn(
            vaultB,
            user1,
            bridgeAt,
            0,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            BRIDGE_AMOUNT
        );

        _assertBookOn(
            vaultB,
            address(0),
            0,
            0,
            0
        );
    }

    function test_bridgeToVault_unreferredSourceReferredDestination_landsTrackedOnly()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT,
            refB
        );

        _depositOn(
            vaultA,
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            address(0),
            address(0),
            BRIDGE_AMOUNT,
            0,
            0,
            0
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getAttributedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refB
        );

        _assertBookOn(
            vaultB,
            refB,
            DEPOSIT,
            0,
            0
        );
    }
}
