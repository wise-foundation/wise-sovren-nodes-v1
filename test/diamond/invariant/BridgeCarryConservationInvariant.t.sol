// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../referral/registry/ReferralRegistry.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {TwoVaultCohortHarness, TwoVaultMockUSD} from "../utils/TwoVaultCohortHarness.sol";

/**
 * @dev Deferred-delivery CCIP router stand-in for the bridge-carry
 * suites: `ccipSend` queues the message instead of relaying it, and
 * `deliver` pushes a queued message into the destination vault's
 * `ccipReceive` on demand, so the handler controls how long carry
 * payloads stay in flight and in which order they land. `dataOf`
 * exposes the raw wire bytes so the handler can decode the carried
 * aggregates it is about to deliver, and `oldestUndelivered` gives a
 * deterministic FIFO pick.
 */
contract MockDeferredCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    mapping(address => uint64) public selectorOf;

    struct QueuedMessage {
        address dest;
        bool delivered;
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sourceSender;
        bytes data;
    }

    QueuedMessage[] internal queue;

    function setSelector(
        address _diamond,
        uint64 _selector
    )
        external
    {
        selectorOf[_diamond] = _selector;
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

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                nonce
            )
        );

        nonce++;

        queue.push(
            QueuedMessage({
                dest: dest,
                delivered: false,
                messageId: messageId,
                sourceChainSelector: selectorOf[msg.sender],
                sourceSender: msg.sender,
                data: _message.data
            })
        );
    }

    function deliver(
        uint256 _index
    )
        external
    {
        QueuedMessage storage queued = queue[_index];

        Client.Any2EVMMessage memory any2 = Client.Any2EVMMessage({
            messageId: queued.messageId,
            sourceChainSelector: queued.sourceChainSelector,
            sender: abi.encode(queued.sourceSender),
            data: queued.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        IAny2EVMMessageReceiver(queued.dest).ccipReceive(
            any2
        );

        queued.delivered = true;
    }

    function queueLength()
        external
        view
        returns (uint256)
    {
        return queue.length;
    }

    function isDelivered(
        uint256 _index
    )
        external
        view
        returns (bool)
    {
        return queue[_index].delivered;
    }

    function destOf(
        uint256 _index
    )
        external
        view
        returns (address)
    {
        return queue[_index].dest;
    }

    function dataOf(
        uint256 _index
    )
        external
        view
        returns (bytes memory)
    {
        return queue[_index].data;
    }

    function oldestUndelivered()
        external
        view
        returns (
            bool found,
            uint256 index
        )
    {
        uint256 count = queue.length;

        for (uint256 i; i < count; ++i) {

            if (queue[i].delivered == false) {
                return (
                    true,
                    i
                );
            }
        }

        return (
            false,
            0
        );
    }
}

/**
 * @dev Fuzz actions over two cohort-armed bridge vaults sharing one
 * {ReferralRegistry} and a deferred router: referred deposits (both
 * vaults, referees pinned to one referrer), unreferred deposits,
 * transfers to a pure sink, bridge-outs (burn + carry capture +
 * queue), deferred deliveries (oldest-first or drain-all), sync
 * pokes, book advances and three warp granularities.
 *
 * Ghost ledger: `ghostCreditedTotal` accumulates every referred
 * credit ever granted. Every tracked-mutating action runs inside a
 * bracket that reads the global tracked contribution of both referees
 * on both vaults before and after, and compares the observed change
 * against the action's justified delta: a referred deposit justifies
 * `+amount`, a referee bridge-out justifies at most `-amount` (the
 * pre-burn sync makes the captured deficit at least the burn), a
 * delivery justifies the carried `trackedDelta` decoded from the wire
 * payload when it lands on a monitored referee (an unreferred user's
 * referrer-zero carry moves only that user's own tracked
 * contribution, which the bracket deliberately does not monitor and
 * which never touches any book), and everything else justifies zero.
 * Observed change above
 * the justification flips `ghostInflationViolations`; the shortfall
 * below it is a genuine clamp destruction and accumulates into
 * `ghostDestroyedTotal`, which the ledger invariant subtracts from
 * total credit.
 *
 * Demotion checks run per delivered referred carry: the handler first
 * flushes the recipient's own lazy deficit and advances the
 * destination book to the current week boundary (so the rotation
 * projection is consistent), snapshots the earliest week at which any
 * of the referrer's book mass could reach the mature lane, delivers,
 * and requires the landing never to move that earliest week later,
 * plus the sharp landing bounds, which read the capture week the
 * delivered payload carries and count the weekly boundaries crossed
 * in flight (zero when the capture week is not before the arrival
 * week): carried mature mass is mature now, and so is carried year-2
 * mass once at least one boundary crossed, and so is every carried
 * lane once more than fifty-two boundaries crossed; otherwise carried
 * year-2 mass, and carried year-1 mass once at least one boundary
 * crossed, matures no later than the next boundary; carried year-1
 * mass delivered in its capture week matures no later than
 * fifty-three weeks out (the oldest-live-slot landing rule after the
 * in-flight ageing). Failures increment
 * `ghostDemotionViolations` instead of reverting because the
 * invariant runner tolerates handler-call reverts.
 */
contract BridgeCarryHandler is Test {

    WiseSovrenNodesDiamond internal immutable vaultA;

    WiseSovrenNodesDiamond internal immutable vaultB;

    TwoVaultMockUSD internal immutable usdA;

    TwoVaultMockUSD internal immutable usdB;

    MockDeferredCCIPRouter internal immutable router;

    CohortRecorderFacet internal immutable recorderA;

    CohortRecorderFacet internal immutable recorderB;

    uint64 internal immutable selectorA;

    uint64 internal immutable selectorB;

    address internal immutable a1;

    address internal immutable a2;

    address internal immutable ref;

    address internal immutable u;

    address internal immutable outsider;

    uint256 internal constant FEE = 0.01 ether;

    uint256 internal constant MAX_ADVANCE_ROUNDS = 80;

    uint256 public ghostCreditedTotal;

    uint256 public ghostDestroyedTotal;

    uint256 public ghostInflationViolations;

    uint256 public ghostDemotionViolations;

    constructor(
        WiseSovrenNodesDiamond _vaultA,
        WiseSovrenNodesDiamond _vaultB,
        TwoVaultMockUSD _usdA,
        TwoVaultMockUSD _usdB,
        MockDeferredCCIPRouter _router,
        address[5] memory _actors,
        uint64 _selectorA,
        uint64 _selectorB,
        uint256 _initialCredited
    ) {
        vaultA = _vaultA;

        vaultB = _vaultB;

        usdA = _usdA;

        usdB = _usdB;

        router = _router;

        recorderA = CohortRecorderFacet(
            address(_vaultA)
        );

        recorderB = CohortRecorderFacet(
            address(_vaultB)
        );

        selectorA = _selectorA;

        selectorB = _selectorB;

        a1 = _actors[0];

        a2 = _actors[1];

        ref = _actors[2];

        u = _actors[3];

        outsider = _actors[4];

        ghostCreditedTotal = _initialCredited;
    }

    function depositReferred(
        uint256 _vaultSeed,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        uint256 trackedBefore = _trackedGlobal();

        _usdOfVault(vault).mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        _usdOfVault(vault).approve(
            address(vault),
            amount
        );

        vm.prank(
            actor
        );

        ReferralFacet(address(vault)).depositWithReferral(
            amount,
            ref
        );

        ghostCreditedTotal += amount;

        _settleLedger(
            trackedBefore,
            int256(amount)
        );
    }

    function depositUnreferred(
        uint256 _vaultSeed,
        uint256 _amountSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        uint256 trackedBefore = _trackedGlobal();

        _usdOfVault(vault).mint(
            u,
            amount
        );

        vm.prank(
            u
        );

        _usdOfVault(vault).approve(
            address(vault),
            amount
        );

        vm.prank(
            u
        );

        UserFacet(address(vault)).deposit(
            amount
        );

        _settleLedger(
            trackedBefore,
            0
        );
    }

    function transferOut(
        uint256 _vaultSeed,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = vault.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        uint256 trackedBefore = _trackedGlobal();

        vm.prank(
            actor
        );

        vault.transfer(
            outsider,
            amount
        );

        _settleLedger(
            trackedBefore,
            0
        );
    }

    function bridgeOut(
        uint256 _vaultSeed,
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
    {
        (
            WiseSovrenNodesDiamond src,
            uint64 dstSelector
        ) = _pickLane(
            _vaultSeed
        );

        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = src.balanceOf(
            actor
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        int256 justified = actor == u
            ? int256(0)
            : -int256(amount);

        uint256 trackedBefore = _trackedGlobal();

        vm.deal(
            actor,
            FEE
        );

        vm.prank(
            actor
        );

        BridgeFacet(address(src)).bridgeToVault{value: FEE}(
            dstSelector,
            amount
        );

        _settleLedger(
            trackedBefore,
            justified
        );
    }

    function deliverOldest()
        external
    {
        (
            bool found,
            uint256 index
        ) = router.oldestUndelivered();

        if (found == false) {
            return;
        }

        _deliverChecked(
            index
        );
    }

    function deliverAll()
        external
    {
        uint256 count = router.queueLength();

        for (uint256 i; i < count; ++i) {

            if (router.isDelivered(i)) {
                continue;
            }

            _deliverChecked(
                i
            );
        }
    }

    function syncPoke(
        uint256 _vaultSeed,
        uint256 _actorSeed
    )
        external
    {
        CohortRecorderFacet rec = _recorderOfVault(
            _pickVault(
                _vaultSeed
            )
        );

        address actor = _closedActor(
            _actorSeed
        );

        uint256 trackedBefore = _trackedGlobal();

        rec.syncReferee(
            actor
        );

        _settleLedger(
            trackedBefore,
            0
        );
    }

    function advanceBookAction(
        uint256 _vaultSeed,
        uint256 _chunkSeed
    )
        external
    {
        _recorderOfVault(
            _pickVault(
                _vaultSeed
            )
        ).advanceBook(
            ref,
            bound(
                _chunkSeed,
                1,
                104
            )
        );
    }

    function warpHours(
        uint256 _seed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 hours,
                2 days
            )
        );
    }

    function warpWeeks(
        uint256 _seed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 weeks,
                10 weeks
            )
        );
    }

    function warpDormant(
        uint256 _seed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                26 weeks,
                110 weeks
            )
        );
    }

    function _deliverChecked(
        uint256 _index
    )
        internal
    {
        CohortRecorderFacet rec = _recorderOfVault(
            router.destOf(_index) == address(vaultA)
                ? vaultA
                : vaultB
        );

        (
            address user,
            ,
            bytes memory referralData
        ) = abi.decode(
            router.dataOf(
                _index
            ),
            (address, uint256, bytes)
        );

        uint256 carriedDelta;

        uint256 carriedY1;

        uint256 carriedY2;

        uint256 carriedM;

        uint256 captureWeek;

        uint256 laneSum;

        uint256 carriedMaturity = type(uint256).max;

        if (referralData.length >= CohortWeeks.BRIDGE_CARRY_HEADER_BYTES) {

            uint256[] memory words = CohortWeeks._unpackBridgeCarry(
                referralData
            );

            captureWeek = CohortWeeks._bridgeCarryCaptureWeek(
                words[0]
            );

            carriedDelta = CohortWeeks._carryTrackedDelta(
                words[1]
            );

            (
                carriedY1,
                carriedY2
            ) = CohortWeeks._carryPairSums(
                words,
                CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
                CohortWeeks._bridgeCarryPairCount(
                    words[0]
                )
            );

            carriedM = CohortWeeks._carryPairLo(
                words[2]
            );

            carriedMaturity = _carriedMaturityWeek(
                words,
                captureWeek,
                carriedM
            );

            laneSum = carriedY1
                + carriedY2
                + carriedM;
        }

        uint256 trackedBefore = _trackedGlobal();

        rec.syncReferee(
            user
        );

        bool settled = _advanceToCurrentWeek(
            rec
        );

        uint256 maturityBefore = settled
            ? _earliestMaturityWeek(rec)
            : 0;

        router.deliver(
            _index
        );

        if (settled && laneSum > 0) {
            _checkDemotion(
                rec,
                maturityBefore,
                carriedMaturity
            );
        }

        int256 justified = user == a1 || user == a2
            ? int256(carriedDelta)
            : int256(0);

        _settleLedger(
            trackedBefore,
            justified
        );
    }

    function _checkDemotion(
        CohortRecorderFacet _rec,
        uint256 _maturityBefore,
        uint256 _carriedMaturity
    )
        internal
    {
        uint256 expected = _carriedMaturity < _maturityBefore
            ? _carriedMaturity
            : _maturityBefore;

        if (_earliestMaturityWeek(_rec) != expected) {
            ++ghostDemotionViolations;
        }
    }

    function _carriedMaturityWeek(
        uint256[] memory _words,
        uint256 _captureWeek,
        uint256 _mature
    )
        internal
        view
        returns (uint256 best)
    {
        uint256 nowWeek = block.timestamp / 1 weeks;

        best = _mature > 0
            ? nowWeek
            : type(uint256).max;

        uint256 pairCount = CohortWeeks._bridgeCarryPairCount(
            _words[0]
        );

        for (uint256 i; i < pairCount; ++i) {

            uint256 pair = CohortWeeks._carryPairOf(
                _words,
                CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
                i
            );

            if (CohortWeeks._carryPairAmount(pair) == 0) {
                continue;
            }

            (
                uint256 slot,
                uint256 lane
            ) = CohortWeeks._landedCarryPair(
                pair,
                _captureWeek,
                nowWeek
            );

            uint256 week = nowWeek;

            if (lane != CohortWeeks.CARRY_LANE_MATURE) {
                week = _nextRotationWeek(
                    slot,
                    nowWeek
                ) + (lane == CohortWeeks.CARRY_RING_YEAR1 ? 52 : 0);
            }

            if (week < best) {
                best = week;
            }
        }
    }

    function _advanceToCurrentWeek(
        CohortRecorderFacet _rec
    )
        internal
        returns (bool)
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _rec.getCohortBook(
            ref
        );

        if (lastSettle == 0) {
            return false;
        }

        uint256 nowWeek = block.timestamp / 1 weeks;

        uint256 rounds;

        while (lastSettle / 1 weeks < nowWeek && rounds < MAX_ADVANCE_ROUNDS) {

            _rec.advanceBook(
                ref,
                104
            );

            (
                ,
                ,
                ,
                lastSettle
            ) = _rec.getCohortBook(
                ref
            );

            ++rounds;
        }

        return lastSettle / 1 weeks == nowWeek;
    }

    function _earliestMaturityWeek(
        CohortRecorderFacet _rec
    )
        internal
        view
        returns (uint256)
    {
        (
            ,
            ,
            uint256 mature,
            uint256 lastSettle
        ) = _rec.getCohortBook(
            ref
        );

        if (mature > 0) {
            return block.timestamp / 1 weeks;
        }

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _rec.getCohortRings(
            ref
        );

        uint256 settleWeek = lastSettle / 1 weeks;

        uint256 best = type(uint256).max;

        for (uint256 slot; slot < 52; ++slot) {

            if (ring2[slot] == 0) {
                continue;
            }

            uint256 boundary = _nextRotationWeek(
                slot,
                settleWeek
            );

            if (boundary < best) {
                best = boundary;
            }
        }

        if (best != type(uint256).max) {
            return best;
        }

        for (uint256 slot; slot < 52; ++slot) {

            if (ring1[slot] == 0) {
                continue;
            }

            uint256 boundary = _nextRotationWeek(
                slot,
                settleWeek
            ) + 52;

            if (boundary < best) {
                best = boundary;
            }
        }

        return best;
    }

    function _nextRotationWeek(
        uint256 _slot,
        uint256 _fromWeek
    )
        internal
        pure
        returns (uint256)
    {
        uint256 offset = (_slot + 52 - ((_fromWeek + 1) % 52)) % 52;

        return _fromWeek
            + 1
            + offset;
    }

    function _settleLedger(
        uint256 _trackedBefore,
        int256 _justified
    )
        internal
    {
        int256 delta = int256(_trackedGlobal())
            - int256(_trackedBefore);

        int256 slack = _justified - delta;

        if (slack < 0) {

            ++ghostInflationViolations;

            return;
        }

        ghostDestroyedTotal += uint256(slack);
    }

    function _trackedGlobal()
        internal
        view
        returns (uint256)
    {
        return recorderA.getTrackedContribution(a1)
            + recorderA.getTrackedContribution(a2)
            + recorderB.getTrackedContribution(a1)
            + recorderB.getTrackedContribution(a2);
    }

    function _pickVault(
        uint256 _seed
    )
        internal
        view
        returns (WiseSovrenNodesDiamond)
    {
        return _seed % 2 == 0
            ? vaultA
            : vaultB;
    }

    function _pickLane(
        uint256 _seed
    )
        internal
        view
        returns (
            WiseSovrenNodesDiamond src,
            uint64 dstSelector
        )
    {
        if (_seed % 2 == 0) {
            return (
                vaultA,
                selectorB
            );
        }

        return (
            vaultB,
            selectorA
        );
    }

    function _usdOfVault(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (TwoVaultMockUSD)
    {
        return _vault == vaultA
            ? usdA
            : usdB;
    }

    function _recorderOfVault(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (CohortRecorderFacet)
    {
        return _vault == vaultA
            ? recorderA
            : recorderB;
    }

    function _refereeActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return _seed % 2 == 0
            ? a1
            : a2;
    }

    function _closedActor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 i = _seed % 3;

        if (i == 0) {
            return a1;
        }

        if (i == 1) {
            return a2;
        }

        return u;
    }
}

/**
 * @dev Stateful-fuzz invariants for the cross-chain bridge carry:
 * BC1 bounds both diamonds' combined referrer book by the ghost
 * credit ledger minus every observed clamp destruction (relocations
 * are book-neutral end to end, so no interleaving of sends and
 * deferred deliveries may ever inflate the global book past the
 * credit that entered the system); BC2 requires the step-level
 * tracked-justification bracket to have never observed an
 * unjustified rise (the conservation ceiling that prices any forged
 * or double-applied carry); BC3 is the exact global identity: the
 * two books together always equal the referees' combined tracked
 * contribution, even while carries are in flight, because capture
 * removes the carried slice from both sides and delivery restores it
 * to both; BC4 pins that a referee's balance never outruns the
 * tracked contribution on either vault (every minted bridge arrival
 * lands with its full tracked delta); BC5 re-checks the ring-to-lane
 * identity on both vaults, which a landing that touched a ring
 * without its book (or vice versa) would break; BC6 asserts the
 * per-delivery maturity checks stayed clean: a relocation never
 * changes a cohort's age, so after a delivery the book's earliest
 * maturity week is exactly the earlier of the book's own and the
 * carried pairs' maturity weeks, each pair aged only by the week
 * boundaries crossed between the capture week the payload carries and
 * the arrival.
 */
contract BridgeCarryConservationInvariantTest is TwoVaultCohortHarness {

    uint256 internal constant PIN_DEPOSIT = 1_000 * 1e6;

    uint64 internal constant SELECTOR_A = 1111;

    uint64 internal constant SELECTOR_B = 2222;

    address internal constant A1 = address(0xA1);

    address internal constant A2 = address(0xA2);

    address internal constant U = address(0xA3);

    address internal constant REF = address(0xB1);

    address internal constant OUTSIDER = address(0xC1);

    MockDeferredCCIPRouter internal router;

    BridgeCarryHandler internal handler;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdA = new TwoVaultMockUSD();

        usdB = new TwoVaultMockUSD();

        registry = new ReferralRegistry(
            address(this),
            0
        );

        router = new MockDeferredCCIPRouter();

        vaultA = _deployBridgedCohortVault(
            address(usdA)
        );

        vaultB = _deployBridgedCohortVault(
            address(usdB)
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridgeLane(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridgeLane(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();

        vaultB.finalizeSetup();

        _armBoth();

        _depositWithReferralOn(
            vaultA,
            A1,
            PIN_DEPOSIT,
            REF
        );

        _depositWithReferralOn(
            vaultB,
            A2,
            PIN_DEPOSIT,
            REF
        );

        address[5] memory actors = [
            A1,
            A2,
            REF,
            U,
            OUTSIDER
        ];

        handler = new BridgeCarryHandler(
            vaultA,
            vaultB,
            usdA,
            usdB,
            router,
            actors,
            SELECTOR_A,
            SELECTOR_B,
            2 * PIN_DEPOSIT
        );

        targetContract(
            address(handler)
        );
    }

    function _deployBridgedCohortVault(
        address _usd
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
            registry
        );
    }

    function _wireBridgeLane(
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

    function _globalScore()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getCohortScore(REF)
            + _recorderOf(vaultB).getCohortScore(REF);
    }

    function _globalTracked()
        internal
        view
        returns (uint256)
    {
        return _recorderOf(vaultA).getTrackedContribution(A1)
            + _recorderOf(vaultA).getTrackedContribution(A2)
            + _recorderOf(vaultB).getTrackedContribution(A1)
            + _recorderOf(vaultB).getTrackedContribution(A2);
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC1_bookBoundedByCreditLedger()
        public
        view
    {
        assertLe(
            _globalScore() + handler.ghostDestroyedTotal(),
            handler.ghostCreditedTotal(),
            "BC1: global book exceeds credit ledger minus destructions"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC2_trackedNeverRisesUnjustified()
        public
        view
    {
        assertEq(
            handler.ghostInflationViolations(),
            0,
            "BC2: tracked contribution rose beyond the justified delta"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC3_globalBookEqualsGlobalTracked()
        public
        view
    {
        assertEq(
            _globalScore(),
            _globalTracked(),
            "BC3: global book != global referee tracked"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC4_refereeBalanceFullyTracked()
        public
        view
    {
        assertGe(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                A1
            ),
            vaultA.balanceOf(
                A1
            ),
            "BC4-A1-A: balance outran tracked contribution"
        );

        assertGe(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                A2
            ),
            vaultA.balanceOf(
                A2
            ),
            "BC4-A2-A: balance outran tracked contribution"
        );

        assertGe(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                A1
            ),
            vaultB.balanceOf(
                A1
            ),
            "BC4-A1-B: balance outran tracked contribution"
        );

        assertGe(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                A2
            ),
            vaultB.balanceOf(
                A2
            ),
            "BC4-A2-B: balance outran tracked contribution"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC5_ringLaneIdentityBothVaults()
        public
        view
    {
        _assertVaultRings(
            vaultA,
            "BC5-A"
        );

        _assertVaultRings(
            vaultB,
            "BC5-B"
        );
    }

    function _assertVaultRings(
        WiseSovrenNodesDiamond d,
        string memory _tag
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorderOf(d).getCohortRings(
            REF
        );

        uint256 ring1Sum;

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {

            ring1Sum += uint256(ring1[i]);

            ring2Sum += uint256(ring2[i]);
        }

        (
            uint256 year1,
            uint256 year2,
            ,
        ) = _recorderOf(d).getCohortBook(
            REF
        );

        assertEq(
            ring1Sum,
            year1,
            string.concat(
                _tag,
                ": ring1 sum != bookY1"
            )
        );

        assertEq(
            ring2Sum,
            year2,
            string.concat(
                _tag,
                ": ring2 sum != bookY2"
            )
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BC6_deliveryNeverDemotesMaturity()
        public
        view
    {
        assertEq(
            handler.ghostDemotionViolations(),
            0,
            "BC6: a delivery moved the earliest maturity week later"
        );
    }
}
