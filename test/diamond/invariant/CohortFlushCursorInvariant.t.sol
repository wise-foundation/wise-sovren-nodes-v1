// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortFlushFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";
import {CohortFlushCodec} from "../../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../../referral/registry/ReferralRegistry.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";
import {CohortSelfLogProbeFacet} from "../utils/CohortSelfLogProbeFacet.sol";

contract FlushCursorMockUSD is ERC20 {

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
 * @dev Recording CCIP router stand-in for the cursor campaign: a flat
 * fee, the exact fee demanded on send, and the raw envelope bytes of
 * the last send kept for the handler's decoder. Nothing is relayed;
 * the campaign pins the spoke side alone.
 */
contract FlushCursorRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 public sendCount;

    bytes public lastData;

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
        require(
            msg.value == FIXED_FEE,
            "WRONG_FEE"
        );

        lastData = _message.data;

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                sendCount
            )
        );

        sendCount++;
    }
}

/**
 * @dev Drives the flush transport of one fully wired cohort diamond in
 * CCIP mode through bounded random deposits, exits, book advances,
 * three warp granularities (hours, weeks, dormant spans that push a
 * book into the compressed gap log), the master's public-flush
 * switch, the master's recorder switch (a disarm only once every
 * non-empty book has settled past the last re-arm, the operator law
 * the engine's one-span stamps rely on; every flush while disarmed
 * must be refused with {CohortSyncDisabled}), and every flush shape
 * the facet offers: a referrer's own
 * batch (optionally carrying other books and a duplicate of its own
 * entry), a third-party batch by the allowlisted bot, by a referrer
 * that is itself allowlisted, or by a stranger while the public
 * switch is on (random subsets, duplicates included), a referrer's
 * own window from any week and gap index, a third-party window whose
 * acceptance the handler predicts from the pre-state cursors, a
 * referrer's own stake and its payout designation on the registry
 * (so the self runs of an entry, once the stake has been held through
 * a closed week, and its designation word are nonzero and mirrored; a redesignation within the second of the
 * previous one first steps the clock one second, because the
 * registry accepts only a strictly newer stamp), and every caller
 * the gate must refuse, called anyway so the refusal is observed.
 * The dormant spans push a book into the compressed gap log once its
 * unsettled lag passes 104 weeks.
 *
 * The handler is the sole observer of every envelope: after each
 * accepted flush it decodes the router's captured bytes word by word
 * and rebuilds, from the diamond's storage and the cursors captured
 * BEFORE the call, the plan the facet must have produced (the crumb
 * scan from the cursor-derived start week over the 104-week window,
 * the gap walk from the stored index and resume week, the shared
 * work budget across the batch in order, the through-week and gap
 * cursor each entry would store), so every deviation between the
 * shipped envelope, the stored cursors and the pre-state is a sticky
 * violation the invariants read. Ghost state: the last observed
 * cursors per referrer (monotonicity), whether the referrer's own
 * flush has ever run (the virgin rule), the largest word any envelope
 * carried per (referrer, week) (the stranding rule requires the final
 * word of every closed week a batch cursor advance passes), every
 * closed week the referrer's OWN flush shipped (the re-send rule),
 * and one violation counter per law. Reverts are never swallowed: a
 * third-party window is called under try/catch only to compare the
 * facet's verdict with the predicate the handler computed from the
 * pre-state, an unpermitted caller is called under try/catch only to
 * observe the gate's own revert, every flush while the recorder is
 * disarmed is called under try/catch only to observe the refusal of
 * the disarmed recorder, any other revert reason counts as a
 * violation, and every law runs with fail-on-revert so a reverting
 * action fails the campaign instead of being dropped.
 */
contract CohortFlushCursorHandler is Test {

    struct CursorSnap {
        uint256 through;
        uint256 gapIndex;
        uint256 gapResume;
    }

    struct FlushCall {
        address caller;
        bool isWindow;
        uint256 fromWeek;
        uint256 fromGapIndex;
        uint256 currentWeek;
    }

    struct SelfMirror {
        uint256[] log;
        uint256 settledAt;
        uint256 current;
        uint256 stake;
    }

    struct EntryPlan {
        uint256 fromWeek;
        uint256 gapIndex;
        uint256 gapResume;
        uint256[] crumbWeeks;
        uint256[] selfRuns;
        uint256 throughWeek;
        uint256 crumbWork;
        uint256[] slices;
        uint256 gapIndexAfter;
        uint256 gapResumeAfter;
        uint256 gapWork;
        bool truncated;
    }

    struct EntryCheck {
        FlushCall flushCall;
        address referrer;
        CursorSnap snap;
        CursorSnap predicted;
        bytes data;
        uint256 cursor;
        uint256 budgetLeft;
    }

    uint256 internal constant FIXED_FEE = 0.01 ether;

    WiseSovrenNodesDiamond internal immutable diamond;

    FlushCursorMockUSD internal immutable usd;

    FlushCursorRouter internal immutable router;

    CohortFlushFacet internal immutable flush;
    CohortFlushPolicyFacet internal immutable flushPolicy;

    CohortRecorderFacet internal immutable recorder;

    ReferralRegistry internal immutable registry;

    address internal immutable master;

    address internal immutable bot;

    address internal immutable stranger;

    address internal immutable outsider;

    address[3] internal referrers;

    address[4] internal referees;

    mapping(address => uint256) public ghostThrough;

    mapping(address => uint256) public ghostGapIndex;

    mapping(address => uint256) public ghostGapResume;

    mapping(address => bool) public ghostOwnFlushed;

    mapping(address => mapping(uint256 => bool)) public ghostShipped;

    mapping(address => mapping(uint256 => bool)) public ghostOwnShippedClosed;

    uint256 public ghostMonotoneViolations;

    uint256 public ghostVirginWriteViolations;

    uint256 public ghostThirdPartyWriteViolations;

    uint256 public ghostLogCountViolations;

    uint256 public ghostPlanMirrorViolations;

    uint256 public ghostStrandingViolations;

    uint256 public ghostWindowPredicateViolations;

    uint256 public ghostOwnWeekResendViolations;

    uint256 public flushCount;

    uint256 public windowRefusals;

    uint256 public thirdPartyWrites;

    uint256 public acceptedThirdPartyWindows;

    uint256 public budgetTruncations;

    uint256 public midRecordGapStops;

    uint256 public virginThirdPartyBatches;

    uint256 public callerRefusals;

    uint256 public outageRefusals;
    uint256 public laneRefusals;

    uint256 public designations;

    uint256 public ghostCallerGateViolations;

    mapping(address => mapping(uint256 => uint256)) public ghostShippedWord;

    uint256 public ghostDisarmViolations;

    uint256 public disarmedRefusals;

    uint256 public armToggles;

    uint256[] internal ghostSpanFrom;

    uint256[] internal ghostSpanTo;

    constructor(
        WiseSovrenNodesDiamond _diamond,
        FlushCursorMockUSD _usd,
        FlushCursorRouter _router,
        ReferralRegistry _registry,
        address _master,
        address[3] memory _referrers,
        address[4] memory _referees,
        address[3] memory _thirdParties
    ) {
        diamond = _diamond;

        usd = _usd;

        router = _router;

        registry = _registry;

        flush = CohortFlushFacet(
            address(_diamond)
        );

        flushPolicy = CohortFlushPolicyFacet(
            address(_diamond)
        );

        recorder = CohortRecorderFacet(
            address(_diamond)
        );

        master = _master;

        referrers = _referrers;

        referees = _referees;

        bot = _thirdParties[0];

        stranger = _thirdParties[1];

        outsider = _thirdParties[2];
    }

    // ---- views for the invariant contract ----

    function referrerAt(
        uint256 _index
    )
        external
        view
        returns (address)
    {
        return referrers[_index];
    }

    // ---- book actions ----

    function depositReferred(
        uint256 _refereeSeed,
        uint256 _amountSeed
    )
        external
    {
        address referee = referees[bound(_refereeSeed, 0, referees.length - 1)];

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usd.mint(
            referee,
            amount
        );

        vm.prank(
            referee
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            referee
        );

        UserFacet(address(diamond)).deposit(
            amount
        );
    }

    function transferOut(
        uint256 _refereeSeed,
        uint256 _amountSeed
    )
        external
    {
        address referee = referees[bound(_refereeSeed, 0, referees.length - 1)];

        uint256 held = diamond.balanceOf(
            referee
        );

        if (held == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            held
        );

        vm.prank(
            referee
        );

        diamond.transfer(
            outsider,
            amount
        );
    }

    function referrerDeposit(
        uint256 _referrerSeed,
        uint256 _amountSeed
    )
        external
    {
        address referrer = _pickReferrer(
            _referrerSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            20_000 * 1e6
        );

        usd.mint(
            referrer,
            amount
        );

        vm.prank(
            referrer
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            referrer
        );

        UserFacet(address(diamond)).deposit(
            amount
        );
    }

    function designate(
        uint256 _referrerSeed,
        uint256 _payoutSeed
    )
        external
    {
        address referrer = _pickReferrer(
            _referrerSeed
        );

        if (registry.payoutStamp(referrer) >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT >= block.timestamp) {
            vm.warp(
                block.timestamp + 1
            );
        }

        vm.prank(
            referrer
        );

        registry.setPayoutAddress(
            address(
                uint160(
                    bound(
                        _payoutSeed,
                        1,
                        type(uint160).max
                    )
                )
            )
        );

        ++designations;
    }

    function advanceBook(
        uint256 _referrerSeed,
        uint256 _chunkSeed
    )
        external
    {
        recorder.advanceBook(
            _pickReferrer(
                _referrerSeed
            ),
            bound(
                _chunkSeed,
                1,
                CohortWeeks.MAX_SETTLE_BOUNDARIES
            )
        );
    }

    function togglePublicFlush(
        uint256 _seed
    )
        external
    {
        if (bound(_seed, 0, 3) != 0) {
            return;
        }

        bool enabled = flushPolicy.getPublicFlushEnabled();

        vm.prank(
            master
        );

        flushPolicy.setPublicFlushEnabled(
            enabled == false
        );
    }

    function toggleRecorderArm(
        uint256 _seed
    )
        external
    {
        if (bound(_seed, 0, 3) != 0) {
            return;
        }

        bool armed = recorder.getCohortSyncEnabled();

        if (armed && _booksSettledSinceRearm() == false) {
            return;
        }

        vm.prank(
            master
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            armed == false
        );

        if (armed) {

            ghostSpanFrom.push(
                block.timestamp
            );

            ghostSpanTo.push(
                type(uint256).max
            );
        } else {
            ghostSpanTo[ghostSpanTo.length - 1] = block.timestamp;
        }

        ++armToggles;
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

    // ---- flush actions ----

    function ownBatch(
        uint256 _referrerSeed,
        uint256 _extraSeed
    )
        external
    {
        address caller = _pickReferrer(
            _referrerSeed
        );

        uint256 extra = bound(
            _extraSeed,
            0,
            3
        );

        bool withOther = extra >= 2 && _permitted(caller);

        uint256 count = 1
            + (withOther ? 1 : 0)
            + (extra % 2 == 1 ? 1 : 0);

        address[] memory batch = new address[](count);

        batch[0] = caller;

        uint256 next = 1;

        if (withOther) {
            batch[next] = _otherReferrer(
                caller,
                _extraSeed >> 8
            );

            ++next;
        }

        if (extra % 2 == 1) {
            batch[next] = caller;
        }

        if (batch.length > 1 && recorder.getCohortSyncEnabled()) {
            _advanceBooksToNow(
                batch
            );
        }

        if (_outageGatedBatch(
            caller,
            batch
        )) {
            _runRefusedBatch(
                caller,
                batch
            );

            return;
        }

        _runBatch(
            caller,
            batch
        );
    }

    function thirdPartyBatch(
        uint256 _callerSeed,
        uint256 _maskSeed,
        uint256 _dupSeed
    )
        external
    {
        address caller = _pickThirdParty(
            _callerSeed
        );

        uint256 mask = bound(
            _maskSeed,
            1,
            7
        );

        bool duplicate = bound(_dupSeed, 0, 2) == 0;

        uint256 count;

        for (uint256 i; i < referrers.length; ++i) {

            if ((mask >> i) & 1 != 0) {
                ++count;
            }
        }

        address[] memory batch = new address[](
            count + (duplicate ? 1 : 0)
        );

        uint256 next;

        for (uint256 i; i < referrers.length; ++i) {

            if ((mask >> i) & 1 != 0) {
                batch[next] = referrers[i];

                ++next;
            }
        }

        if (duplicate) {
            batch[next] = batch[0];
        }

        if (_permitted(caller) == false) {
            _runRefusedBatch(
                caller,
                batch
            );

            return;
        }

        if (batch.length > 1 && recorder.getCohortSyncEnabled()) {
            _advanceBooksToNow(
                batch
            );
        }

        if (_outageGatedBatch(
            caller,
            batch
        )) {
            _runRefusedBatch(
                caller,
                batch
            );

            return;
        }

        _runBatch(
            caller,
            batch
        );
    }

    function ownWindow(
        uint256 _referrerSeed,
        uint256 _fromSeed,
        uint256 _gapSeed
    )
        external
    {
        address referrer = _pickReferrer(
            _referrerSeed
        );

        (
            uint256 fromWeek,
            uint256 fromGapIndex
        ) = _windowStart(
            referrer,
            _fromSeed,
            _gapSeed
        );

        _runWindow(
            referrer,
            referrer,
            fromWeek,
            fromGapIndex
        );
    }

    function thirdPartyWindow(
        uint256 _callerSeed,
        uint256 _referrerSeed,
        uint256 _fromSeed,
        uint256 _gapSeed
    )
        external
    {
        address caller = _pickThirdParty(
            _callerSeed
        );

        address referrer = _pickReferrer(
            _referrerSeed
        );

        if (referrer == caller) {
            referrer = _otherReferrer(
                caller,
                _referrerSeed >> 8
            );
        }

        (
            uint256 fromWeek,
            uint256 fromGapIndex
        ) = _windowStart(
            referrer,
            _fromSeed,
            _gapSeed
        );

        if (_permitted(caller) == false) {
            _runRefusedWindow(
                caller,
                referrer,
                fromWeek,
                fromGapIndex
            );

            return;
        }

        _runWindow(
            caller,
            referrer,
            fromWeek,
            fromGapIndex
        );
    }

    function _runRefusedBatch(
        address _caller,
        address[] memory _batch
    )
        internal
    {
        if (recorder.getCohortSyncEnabled() == false) {

            _runDisarmedBatch(
                _caller,
                _batch
            );

            return;
        }

        CursorSnap[] memory snaps = _snapshotCursors(
            _batch
        );

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.prank(
            _caller
        );

        try flush.flushReferrals{value: FIXED_FEE}(
            _batch
        ) {
            ++ghostCallerGateViolations;
        } catch (bytes memory reason) {
            _noteCallerRefusal(
                reason
            );
        }

        _assertUnchanged(
            _batch,
            snaps
        );
    }

    function _runRefusedWindow(
        address _caller,
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        internal
    {
        if (recorder.getCohortSyncEnabled() == false) {

            _runDisarmedWindow(
                _caller,
                _referrer,
                _fromWeek,
                _fromGapIndex
            );

            return;
        }

        address[] memory batch = new address[](1);

        batch[0] = _referrer;

        CursorSnap[] memory snaps = _snapshotCursors(
            batch
        );

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.prank(
            _caller
        );

        try flush.flushReferralWindow{value: FIXED_FEE}(
            _referrer,
            _fromWeek,
            _fromGapIndex
        ) {
            ++ghostCallerGateViolations;
        } catch (bytes memory reason) {
            _noteCallerRefusal(
                reason
            );
        }

        _assertUnchanged(
            batch,
            snaps
        );
    }

    function _noteCallerRefusal(
        bytes memory _reason
    )
        internal
    {
        if (
            keccak256(_reason) == keccak256(
                abi.encodeWithSelector(
                    WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
                )
            )
        ) {
            ++outageRefusals;

            return;
        }

        if (
            keccak256(_reason) != keccak256(
                abi.encodeWithSelector(
                    WiseSovrenNodesDiamondErrors.NotFlushBot.selector
                )
            )
        ) {
            ++ghostCallerGateViolations;

            return;
        }

        ++callerRefusals;
    }

    function _latestReopenStamp()
        internal
        view
        returns (
            uint256 reopen,
            uint256 pauseGraceEnd
        )
    {
        uint256 slot = uint256(
            vm.load(
                address(diamond),
                bytes32(
                    uint256(
                        93
                    )
                )
            )
        );

        reopen = slot >> 128;

        uint256 pauseStamp = slot >> 192;

        uint64 rearmed = uint64(
            slot >> 64
        );

        uint64 disarmed = uint64(
            slot
        );

        pauseGraceEnd = reopen == 0
            ? 0
            : reopen + 1 days + (reopen - pauseStamp);

        uint256 disarmGraceEnd = rearmed > disarmed
            ? uint256(rearmed) + 1 days + (uint256(rearmed) - uint256(disarmed))
            : 0;

        if (pauseGraceEnd < disarmGraceEnd) {
            pauseGraceEnd = disarmGraceEnd;
        }

        if (
            rearmed > disarmed
                && rearmed > reopen
        ) {
            reopen = rearmed;
        }

        if (reopen == 0) {
            return (0, 0);
        }
    }

    function _outageGated(
        address _caller,
        address _referrer,
        uint256 _firstWeek,
        uint256 _gapIndex,
        uint256 _gapResumeWeek
    )
        internal
        returns (bool)
    {
        if (_caller == _referrer) {
            return false;
        }

        (
            uint256 reopen,
            uint256 deadline
        ) = _latestReopenStamp();

        if (reopen == 0) {
            return false;
        }

        uint256 earliest = _firstWeek;

        (
            bool gapPresent,
            uint256 gapEntry
        ) = _postSettleGapEntry(
            _referrer,
            _gapIndex
        );

        if (gapPresent) {

            uint256 gapFirstWeek = CohortWeeks._gapRecordFromWeek(
                gapEntry
            );

            if (_gapResumeWeek > gapFirstWeek) {
                gapFirstWeek = _gapResumeWeek;
            }

            if (gapFirstWeek < earliest) {
                earliest = gapFirstWeek;
            }
        }

        return (earliest + 1) * CohortWeeks.WEEK <= reopen
            && block.timestamp < deadline;
    }

    function _postSettleGapEntry(
        address _referrer,
        uint256 _gapIndex
    )
        internal
        returns (
            bool present,
            uint256 entry
        )
    {
        uint256 snapshot = vm.snapshotState();

        address[] memory own = new address[](1);

        own[0] = _referrer;

        vm.deal(
            _referrer,
            FIXED_FEE
        );

        vm.prank(
            _referrer
        );

        try flush.flushReferrals{value: FIXED_FEE}(
            own
        ) {} catch {}

        if (_gapIndex < recorder.getCohortGapLogLength(
            _referrer
        )) {
            present = true;

            entry = recorder.getCohortGapLogEntry(
                _referrer,
                _gapIndex
            );
        }

        vm.revertToState(
            snapshot
        );
    }

    function _outageGatedBatch(
        address _caller,
        address[] memory _batch
    )
        internal
        returns (bool)
    {
        (
            uint256[] memory throughWeeks,
            uint256[] memory gapIndexes,
            uint256[] memory gapResumeWeeks
        ) = flushPolicy.getFlushCursors(
            _batch
        );

        for (uint256 i; i < _batch.length; ++i) {

            if (
                _outageGated(
                    _caller,
                    _batch[i],
                    _cursorFromWeek(
                        throughWeeks[i],
                        block.timestamp / CohortWeeks.WEEK
                    ),
                    gapIndexes[i],
                    gapResumeWeeks[i]
                )
            ) {
                return true;
            }
        }

        return false;
    }

    function _runDisarmedBatch(
        address _caller,
        address[] memory _batch
    )
        internal
    {
        CursorSnap[] memory snaps = _snapshotCursors(
            _batch
        );

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.prank(
            _caller
        );

        try flush.flushReferrals{value: FIXED_FEE}(
            _batch
        ) {
            ++ghostDisarmViolations;
        } catch (bytes memory reason) {
            _noteDisarmedRefusal(
                reason
            );
        }

        _assertUnchanged(
            _batch,
            snaps
        );
    }

    function _runDisarmedWindow(
        address _caller,
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        internal
    {
        address[] memory batch = new address[](1);

        batch[0] = _referrer;

        CursorSnap[] memory snaps = _snapshotCursors(
            batch
        );

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.prank(
            _caller
        );

        try flush.flushReferralWindow{value: FIXED_FEE}(
            _referrer,
            _fromWeek,
            _fromGapIndex
        ) {
            ++ghostDisarmViolations;
        } catch (bytes memory reason) {
            _noteDisarmedRefusal(
                reason
            );
        }

        _assertUnchanged(
            batch,
            snaps
        );
    }

    function _noteDisarmedRefusal(
        bytes memory _reason
    )
        internal
    {
        if (
            keccak256(_reason) != keccak256(
                abi.encodeWithSelector(
                    WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
                )
            )
        ) {
            ++ghostDisarmViolations;

            return;
        }

        ++disarmedRefusals;
    }

    // ---- flush drivers ----

    function _runBatch(
        address _caller,
        address[] memory _batch
    )
        internal
    {
        if (recorder.getCohortSyncEnabled() == false) {

            _runDisarmedBatch(
                _caller,
                _batch
            );

            return;
        }

        CursorSnap[] memory snaps = _snapshotCursors(
            _batch
        );

        FlushCall memory flushCall = FlushCall({
            caller: _caller,
            isWindow: false,
            fromWeek: 0,
            fromGapIndex: 0,
            currentWeek: block.timestamp / CohortWeeks.WEEK
        });

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.recordLogs();

        vm.prank(
            _caller
        );

        try flush.flushReferrals{value: FIXED_FEE}(
            _batch
        ) {

            _afterFlush(
                flushCall,
                _batch,
                snaps
            );
        } catch (bytes memory reason) {

            if (_laneRefused(reason)) {

                ++laneRefusals;

                vm.recordLogs();

                _assertUnchanged(
                    _batch,
                    snaps
                );

                return;
            }

            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _advanceBooksToNow(
        address[] memory _batch
    )
        internal
    {
        for (uint256 i; i < _batch.length; ++i) {

            for (uint256 k; k < 8; ++k) {

                (
                    ,
                    ,
                    ,
                    uint256 lastSettle
                ) = recorder.getCohortBook(
                    _batch[i]
                );

                if (lastSettle / CohortWeeks.WEEK == block.timestamp / CohortWeeks.WEEK) {
                    break;
                }

                recorder.advanceBook(
                    _batch[i],
                    CohortWeeks.MAX_SETTLE_BOUNDARIES
                );
            }
        }
    }

    function _laneRefused(
        bytes memory _reason
    )
        internal
        pure
        returns (bool)
    {
        return keccak256(_reason) == keccak256(
            abi.encodeWithSelector(
                WiseSovrenNodesDiamondErrors.FlushCursorVirgin.selector
            )
        );
    }

    function _runWindow(
        address _caller,
        address _referrer,
        uint256 _fromWeek,
        uint256 _fromGapIndex
    )
        internal
    {
        if (recorder.getCohortSyncEnabled() == false) {

            _runDisarmedWindow(
                _caller,
                _referrer,
                _fromWeek,
                _fromGapIndex
            );

            return;
        }

        address[] memory batch = new address[](1);

        batch[0] = _referrer;

        CursorSnap[] memory snaps = _snapshotCursors(
            batch
        );

        bool expectAccepted = _caller == _referrer
            || (
                _fromWeek > snaps[0].through
                    && _fromGapIndex >= snaps[0].gapIndex
            );

        if (_outageGated(
            _caller,
            _referrer,
            _fromWeek,
            _fromGapIndex,
            _fromGapIndex == snaps[0].gapIndex
                ? snaps[0].gapResume
                : 0
        )) {
            expectAccepted = false;
        }

        FlushCall memory flushCall = FlushCall({
            caller: _caller,
            isWindow: true,
            fromWeek: _fromWeek,
            fromGapIndex: _fromGapIndex,
            currentWeek: block.timestamp / CohortWeeks.WEEK
        });

        vm.deal(
            _caller,
            FIXED_FEE
        );

        vm.recordLogs();

        vm.prank(
            _caller
        );

        try flush.flushReferralWindow{value: FIXED_FEE}(
            _referrer,
            _fromWeek,
            _fromGapIndex
        ) {

            if (expectAccepted == false) {
                ++ghostWindowPredicateViolations;
            }

            if (_caller != _referrer) {
                ++acceptedThirdPartyWindows;
            }

            _afterFlush(
                flushCall,
                batch,
                snaps
            );
        } catch (bytes memory reason) {

            bool windowStartRefusal = keccak256(reason) == keccak256(
                abi.encodeWithSelector(
                    WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
                )
            );

            bool outageRefusal = keccak256(reason) == keccak256(
                abi.encodeWithSelector(
                    WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
                )
            );

            if (_laneRefused(reason)) {

                ++laneRefusals;

            } else if (
                expectAccepted
                    || (windowStartRefusal == false && outageRefusal == false)
            ) {
                ++ghostWindowPredicateViolations;
            }

            if (outageRefusal) {
                ++outageRefusals;
            }

            ++windowRefusals;

            _assertUnchanged(
                batch,
                snaps
            );
        }
    }

    function _afterFlush(
        FlushCall memory _call,
        address[] memory _batch,
        CursorSnap[] memory _snaps
    )
        internal
    {
        ++flushCount;

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes memory data = router.lastData();

        uint256 header = _word(
            data,
            0
        );

        address courier = flushPolicy.getAllowedFlushBot(
            _call.caller
        )
            ? _call.caller
            : address(0);

        if (
            CohortFlushCodec._flushHeaderDeliverer(header) != courier
                || CohortFlushCodec._flushHeaderEntryCount(header) != _batch.length
                || CohortFlushCodec._flushHeaderStamp(header) != block.timestamp
        ) {
            ++ghostPlanMirrorViolations;
        }

        uint256 cursor = 1;

        uint256 budgetLeft = CohortFlushCodec.MAX_FLUSH_WORK;

        CursorSnap[] memory predicted = new CursorSnap[](
            _batch.length
        );

        for (uint256 i; i < _batch.length; ++i) {

            predicted[i] = CursorSnap({
                through: _snaps[i].through,
                gapIndex: _snaps[i].gapIndex,
                gapResume: _snaps[i].gapResume
            });

            (
                cursor,
                budgetLeft
            ) = _checkEntry(
                EntryCheck({
                    flushCall: _call,
                    referrer: _batch[i],
                    snap: _snaps[i],
                    predicted: predicted[i],
                    data: data,
                    cursor: cursor,
                    budgetLeft: budgetLeft
                })
            );
        }

        if (cursor * 32 != data.length) {
            ++ghostPlanMirrorViolations;
        }

        _checkCursorWrites(
            _call,
            _batch,
            _snaps,
            predicted,
            logs
        );
    }

    function _checkEntry(
        EntryCheck memory _check
    )
        internal
        returns (
            uint256 cursor,
            uint256 budgetLeft
        )
    {
        uint256 entryWord = _word(
            _check.data,
            _check.cursor
        );

        if (CohortFlushCodec._flushEntryReferrer(entryWord) != _check.referrer) {
            ++ghostPlanMirrorViolations;
        }

        EntryPlan memory plan = _mirrorPlan(
            _check.flushCall,
            _check.referrer,
            _check.snap,
            _check.budgetLeft
        );

        _noteEntryShapes(
            _check,
            plan
        );

        cursor = _check.cursor + 1;

        uint256 expectedDesignation = _mirrorDesignationWord(
            _check.referrer
        );

        if (CohortFlushCodec._flushEntryFlags(entryWord) & CohortFlushCodec.FLUSH_FLAG_DESIGNATION != 0) {

            if (expectedDesignation == 0 || _word(_check.data, cursor) != expectedDesignation) {
                ++ghostPlanMirrorViolations;
            }

            ++cursor;
        } else if (expectedDesignation != 0) {
            ++ghostPlanMirrorViolations;
        }

        cursor = _checkSelfRuns(
            _check,
            plan,
            CohortFlushCodec._flushEntrySelfRunCount(
                entryWord
            ),
            cursor
        );

        cursor = _checkCrumbs(
            _check,
            plan,
            CohortFlushCodec._flushEntryCrumbCount(
                entryWord
            ),
            cursor
        );

        cursor = _checkGaps(
            _check,
            plan,
            CohortFlushCodec._flushEntryGapCount(
                entryWord
            ),
            cursor
        );

        _foldPrediction(
            _check,
            plan
        );

        budgetLeft = _check.budgetLeft - plan.crumbWork - plan.gapWork;
    }

    function _checkSelfRuns(
        EntryCheck memory _check,
        EntryPlan memory _plan,
        uint256 _runCount,
        uint256 _cursor
    )
        internal
        returns (uint256)
    {
        if (_runCount != _plan.selfRuns.length) {
            ++ghostPlanMirrorViolations;
        }

        for (uint256 k; k < _runCount; ++k) {

            if (k < _plan.selfRuns.length && _word(_check.data, _cursor + k) != _plan.selfRuns[k]) {
                ++ghostPlanMirrorViolations;
            }
        }

        return _cursor + _runCount;
    }

    function _checkCrumbs(
        EntryCheck memory _check,
        EntryPlan memory _plan,
        uint256 _crumbCount,
        uint256 _cursor
    )
        internal
        returns (uint256 cursor)
    {
        cursor = _cursor;

        if (_crumbCount != _plan.crumbWeeks.length) {
            ++ghostPlanMirrorViolations;
        }

        bool own = _check.flushCall.caller == _check.referrer;

        for (uint256 k; k < _crumbCount; ++k) {

            uint256 week = _word(
                _check.data,
                cursor
            );

            if (
                k < _plan.crumbWeeks.length
                    && (
                        week != _plan.crumbWeeks[k]
                            || _word(_check.data, cursor + 1) != recorder.getCohortWeekCrumb(
                                _check.referrer,
                                week
                            )
                    )
            ) {
                ++ghostPlanMirrorViolations;
            }

            _noteCarriedWeek(
                _check.referrer,
                week,
                _word(_check.data, cursor + 1) & ~CohortWeeks.CRUMB_WRITTEN_BIT,
                own,
                week < _check.flushCall.currentWeek
            );

            cursor += 2;
        }
    }

    function _checkGaps(
        EntryCheck memory _check,
        EntryPlan memory _plan,
        uint256 _gapCount,
        uint256 _cursor
    )
        internal
        returns (uint256 cursor)
    {
        cursor = _cursor;

        if (_gapCount != _plan.slices.length) {
            ++ghostPlanMirrorViolations;
        }

        bool own = _check.flushCall.caller == _check.referrer;

        for (uint256 k; k < _gapCount; ++k) {

            uint256 slice = _word(
                _check.data,
                cursor
            );

            if (k < _plan.slices.length && slice != _plan.slices[k]) {
                ++ghostPlanMirrorViolations;
            }

            uint256 sliceTo = CohortWeeks._gapRecordToWeek(
                slice
            );

            uint256 sliceFrom = CohortWeeks._gapRecordFromWeek(
                slice
            );

            if (sliceTo <= sliceFrom || sliceTo - sliceFrom > CohortWeeks.MAX_SETTLE_BOUNDARIES) {
                ++ghostPlanMirrorViolations;

                ++cursor;

                continue;
            }

            for (uint256 week = sliceFrom; week < sliceTo; ++week) {
                _noteCarriedWeek(
                    _check.referrer,
                    week,
                    0,
                    own,
                    true
                );
            }

            ++cursor;
        }
    }

    function _foldPrediction(
        EntryCheck memory _check,
        EntryPlan memory _plan
    )
        internal
        pure
    {
        bool writes = _check.flushCall.caller == _check.referrer;

        if (writes == false) {
            return;
        }

        if (_plan.throughWeek > _check.predicted.through) {
            _check.predicted.through = _plan.throughWeek;
        }

        if (
            _plan.gapIndexAfter > _check.predicted.gapIndex
                || (
                    _plan.gapIndexAfter == _check.predicted.gapIndex
                        && _plan.gapResumeAfter > _check.predicted.gapResume
                )
        ) {
            _check.predicted.gapIndex = _plan.gapIndexAfter;
            _check.predicted.gapResume = _plan.gapResumeAfter;
        }
    }

    function _noteEntryShapes(
        EntryCheck memory _check,
        EntryPlan memory _plan
    )
        internal
    {
        if (_plan.truncated) {
            ++budgetTruncations;
        }

        if (_plan.gapResumeAfter != 0) {
            ++midRecordGapStops;
        }

        if (
            _check.flushCall.caller != _check.referrer
                && _check.flushCall.isWindow == false
                && _check.snap.through == 0
        ) {
            ++virginThirdPartyBatches;
        }
    }

    function _mirrorDesignationWord(
        address _owner
    )
        internal
        view
        returns (uint256)
    {
        (
            address payout,
            uint256 stamp
        ) = registry.getPayoutDesignation(
            _owner
        );

        if (stamp == 0 || (stamp >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT) > CohortWeeks.RING_LANE_MAX) {
            return 0;
        }

        return CohortFlushCodec._packFlushDesignation(
            payout,
            stamp >> CohortFlushCodec.DESIGNATION_STAMP_SHIFT,
            stamp & CohortWeeks.CARRY_BYTE_MASK
        );
    }

    function _noteCarriedWeek(
        address _referrer,
        uint256 _week,
        uint256 _shipped,
        bool _own,
        bool _closed
    )
        internal
    {
        if (_insideDisarmSpan(_week)) {
            ++ghostDisarmViolations;
        }

        ghostShipped[_referrer][_week] = true;

        if (_shipped > ghostShippedWord[_referrer][_week]) {
            ghostShippedWord[_referrer][_week] = _shipped;
        }

        if (_own) {

            if (
                _closed
                    && _week <= flushPolicy.getFlushedThroughWeek(
                        _referrer
                    )
            ) {
                ghostOwnShippedClosed[_referrer][_week] = true;
            }

            return;
        }

        if (ghostOwnShippedClosed[_referrer][_week]) {
            ++ghostOwnWeekResendViolations;
        }
    }

    function _checkCursorWrites(
        FlushCall memory _call,
        address[] memory _batch,
        CursorSnap[] memory _snaps,
        CursorSnap[] memory _predicted,
        Vm.Log[] memory _logs
    )
        internal
    {
        for (uint256 i; i < _batch.length; ++i) {

            if (_seenEarlier(_batch, i)) {
                continue;
            }

            _checkReferrerWrite(
                _call,
                _batch[i],
                _snaps[i],
                _predicted[i],
                _logs
            );
        }
    }

    function _checkReferrerWrite(
        FlushCall memory _call,
        address _referrer,
        CursorSnap memory _snap,
        CursorSnap memory _predicted,
        Vm.Log[] memory _logs
    )
        internal
    {
        CursorSnap memory stored = _readCursors(
            _referrer
        );

        bool changed = stored.through != _snap.through
            || stored.gapIndex != _snap.gapIndex
            || stored.gapResume != _snap.gapResume;

        if (
            stored.through < _snap.through
                || stored.gapIndex < _snap.gapIndex
                || (
                    stored.gapIndex == _snap.gapIndex
                        && stored.gapResume < _snap.gapResume
                )
        ) {
            ++ghostMonotoneViolations;
        }

        if (
            stored.through != _predicted.through
                || stored.gapIndex != _predicted.gapIndex
                || stored.gapResume != _predicted.gapResume
        ) {
            ++ghostPlanMirrorViolations;
        }

        if (_countFlushedLogs(_logs, _referrer) != (changed ? 1 : 0)) {
            ++ghostLogCountViolations;
        }

        bool own = _call.caller == _referrer;

        if (changed && own == false) {

            if (_call.isWindow || _snap.through == 0) {
                ++ghostThirdPartyWriteViolations;
            }

            ++thirdPartyWrites;
        }

        if (changed && (own == false || _call.isWindow == false)) {
            _checkNoStranding(
                _referrer,
                _snap,
                stored,
                _strandingFromWeek(
                    _snap.through,
                    _call.currentWeek
                )
            );
        }

        if (ghostOwnFlushed[_referrer] == false && own == false) {

            if (stored.through != 0 || stored.gapIndex != 0 || stored.gapResume != 0) {
                ++ghostVirginWriteViolations;
            }
        }

        if (own) {
            ghostOwnFlushed[_referrer] = true;
        }

        ghostThrough[_referrer] = stored.through;

        ghostGapIndex[_referrer] = stored.gapIndex;

        ghostGapResume[_referrer] = stored.gapResume;
    }

    function _strandingFromWeek(
        uint256 _through,
        uint256 _currentWeek
    )
        internal
        pure
        returns (uint256)
    {
        uint256 planned = _cursorFromWeek(
            _through,
            _currentWeek
        );

        return planned > _through + 1
            ? planned
            : _through + 1;
    }

    function _checkNoStranding(
        address _referrer,
        CursorSnap memory _before,
        CursorSnap memory _after,
        uint256 _fromWeek
    )
        internal
    {
        if (_after.through >= block.timestamp / CohortWeeks.WEEK) {
            ++ghostStrandingViolations;

            return;
        }

        for (uint256 week = _fromWeek; week <= _after.through; ++week) {

            uint256 word = recorder.getCohortWeekCrumb(
                _referrer,
                week
            ) & ~CohortWeeks.CRUMB_WRITTEN_BIT;

            if (word != 0 && ghostShippedWord[_referrer][week] != word) {
                ++ghostStrandingViolations;
            }
        }

        uint256 length = recorder.getCohortGapLogLength(
            _referrer
        );

        uint256 index = _before.gapIndex;

        uint256 resume = _before.gapResume;

        while (
            index < length
                && (
                    index < _after.gapIndex
                        || (index == _after.gapIndex && resume < _after.gapResume)
                )
        ) {

            uint256 record = recorder.getCohortGapLogEntry(
                _referrer,
                index
            );

            uint256 week = CohortWeeks._gapRecordFromWeek(
                record
            );

            if (resume > week) {
                week = resume;
            }

            uint256 stop = CohortWeeks._gapRecordToWeek(
                record
            );

            if (index == _after.gapIndex && _after.gapResume < stop) {
                stop = _after.gapResume;
            }

            for (; week < stop; ++week) {

                if (ghostShipped[_referrer][week] == false) {
                    ++ghostStrandingViolations;
                }
            }

            ++index;

            resume = 0;
        }
    }

    function _assertUnchanged(
        address[] memory _batch,
        CursorSnap[] memory _snaps
    )
        internal
    {
        for (uint256 i; i < _batch.length; ++i) {

            CursorSnap memory stored = _readCursors(
                _batch[i]
            );

            if (
                stored.through != _snaps[i].through
                    || stored.gapIndex != _snaps[i].gapIndex
                    || stored.gapResume != _snaps[i].gapResume
            ) {
                ++ghostThirdPartyWriteViolations;
            }
        }
    }

    // ---- the plan mirror ----

    function _mirrorPlan(
        FlushCall memory _call,
        address _referrer,
        CursorSnap memory _snap,
        uint256 _budgetLeft
    )
        internal
        view
        returns (EntryPlan memory plan)
    {
        if (_call.isWindow) {
            plan.fromWeek = _call.fromWeek;
            plan.gapIndex = _call.fromGapIndex;
            plan.gapResume = _call.fromGapIndex == _snap.gapIndex
                ? _snap.gapResume
                : 0;
        } else {
            plan.fromWeek = _cursorFromWeek(
                _snap.through,
                _call.currentWeek
            );
            plan.gapIndex = _snap.gapIndex;
            plan.gapResume = _snap.gapResume;
        }

        uint256 crumbBudget = _budgetLeft;

        if (_gapWorkWaitingAt(_referrer, plan.gapIndex, plan.gapResume)) {

            crumbBudget = _budgetLeft > GAP_WORK_RESERVE_MIRROR
                ? _budgetLeft - GAP_WORK_RESERVE_MIRROR
                : 0;
        }

        _mirrorWeeks(
            _referrer,
            crumbBudget,
            _call.currentWeek,
            plan
        );

        (
            plan.slices,
            plan.gapIndexAfter,
            plan.gapResumeAfter,
            plan.gapWork
        ) = _mirrorGaps(
            _referrer,
            plan.gapIndex,
            plan.gapResume,
            _budgetLeft - plan.crumbWork
        );
    }

    function _cursorFromWeek(
        uint256 _stored,
        uint256 _currentWeek
    )
        internal
        pure
        returns (uint256)
    {
        if (_stored > 0) {
            return _stored + 1;
        }

        if (_currentWeek < CohortWeeks.MAX_SETTLE_BOUNDARIES) {
            return 0;
        }

        return _currentWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES + 1;
    }

    function _mirrorWeeks(
        address _referrer,
        uint256 _budget,
        uint256 _currentWeek,
        EntryPlan memory _plan
    )
        internal
        view
    {
        uint256 lastWeek = _scanEnd(
            _plan.fromWeek,
            _currentWeek
        );

        if (lastWeek == _currentWeek) {
            lastWeek = _currentWeek - 1;
        }

        lastWeek = _mirrorParkCap(
            _referrer,
            lastWeek
        );

        _plan.throughWeek = lastWeek;

        uint256 span = lastWeek + 1 > _plan.fromWeek
            ? lastWeek + 1 - _plan.fromWeek
            : 0;

        _plan.crumbWeeks = new uint256[](span);

        _plan.selfRuns = new uint256[](span);

        SelfMirror memory self = _selfMirrorOf(
            _referrer
        );

        uint256 crumbCount;

        uint256 runCount;

        for (uint256 week = _plan.fromWeek; week <= lastWeek; ++week) {

            uint256 selfAvg = _mirrorSelfWeekSeconds(
                self,
                week
            ) / CohortWeeks.WEEK;

            bool hasCrumb = recorder.getCohortWeekCrumb(_referrer, week) & ~CohortWeeks.CRUMB_WRITTEN_BIT != 0;

            uint256 cost = (selfAvg > 0 ? 1 : 0) + (hasCrumb ? 1 : 0);

            if (_plan.crumbWork + cost > _budget) {
                _plan.truncated = true;
                _plan.throughWeek = week > 0
                    ? week - 1
                    : 0;
                break;
            }

            _plan.crumbWork += cost;

            if (hasCrumb) {
                _plan.crumbWeeks[crumbCount] = week;
                ++crumbCount;
            }

            if (selfAvg == 0) {
                continue;
            }

            if (
                runCount > 0
                    && CohortFlushCodec._selfRunToWeek(_plan.selfRuns[runCount - 1]) == week
                    && CohortFlushCodec._selfRunAverage(_plan.selfRuns[runCount - 1]) == selfAvg
            ) {
                _plan.selfRuns[runCount - 1] = CohortFlushCodec._packSelfRun(
                    CohortFlushCodec._selfRunFromWeek(_plan.selfRuns[runCount - 1]),
                    week + 1,
                    selfAvg
                );

                continue;
            }

            _plan.selfRuns[runCount] = CohortFlushCodec._packSelfRun(
                week,
                week + 1,
                selfAvg
            );

            ++runCount;
        }

        _plan.crumbWeeks = _trimmed(
            _plan.crumbWeeks,
            crumbCount
        );

        _plan.selfRuns = _trimmed(
            _plan.selfRuns,
            runCount
        );
    }

    function _trimmed(
        uint256[] memory _words,
        uint256 _count
    )
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](_count);

        for (uint256 i; i < _count; ++i) {
            out[i] = _words[i];
        }
    }

    function _selfMirrorOf(
        address _referrer
    )
        internal
        view
        returns (SelfMirror memory self)
    {
        self.log = CohortSelfLogProbeFacet(address(recorder)).probeSelfLog(
            _referrer
        );

        (
            self.settledAt,
            self.current,
        ) = recorder.getCohortSelfCrumb(
            _referrer
        );

        self.stake = CohortWeeks._clampLane80(
            recorder.getTrackedContribution(
                _referrer
            )
        );
    }

    function _mirrorSelfWeekSeconds(
        SelfMirror memory _self,
        uint256 _week
    )
        internal
        pure
        returns (uint256)
    {
        if (_self.settledAt > 0 && _week >= _self.settledAt / CohortWeeks.WEEK) {

            if (_week > _self.settledAt / CohortWeeks.WEEK) {
                return CohortWeeks._clampLane80(
                    _self.stake * CohortWeeks.WEEK
                );
            }

            return CohortWeeks._completedPreviousSeconds(
                _self.current,
                _self.stake,
                _self.settledAt,
                _week + 1
            );
        }

        uint256 found = type(uint256).max;

        for (uint256 i; i < _self.log.length; ++i) {

            if (CohortWeeks._selfLogFromWeek(_self.log[i]) <= _week) {
                found = i;
            }
        }

        if (found == type(uint256).max) {
            return 0;
        }

        uint256 record = _self.log[found];

        if (CohortWeeks._selfLogFromWeek(record) == _week) {
            return CohortWeeks._selfLogSeconds(
                record
            );
        }

        return CohortWeeks._clampLane80(
            CohortWeeks._selfLogStake(
                record
            ) * CohortWeeks.WEEK
        );
    }

    function _mirrorParkCap(
        address _referrer,
        uint256 _throughWeek
    )
        internal
        view
        returns (uint256)
    {
        if (ghostSpanTo.length == 0) {
            return _throughWeek;
        }

        uint256 disarmedAt = ghostSpanFrom[ghostSpanFrom.length - 1];

        uint256 rearmedAt = ghostSpanTo[ghostSpanTo.length - 1];

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = recorder.getCohortBook(
            _referrer
        );

        if (
            year1 + year2 + mature + lastSettle == 0
                || lastSettle > disarmedAt
                || rearmedAt <= disarmedAt
                || block.timestamp >= rearmedAt + CohortWeeks.WEEK
        ) {
            return _throughWeek;
        }

        uint256 cap = disarmedAt / CohortWeeks.WEEK - 1;

        return _throughWeek < cap
            ? _throughWeek
            : cap;
    }

    function _scanEnd(
        uint256 _fromWeek,
        uint256 _currentWeek
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scanCap = _fromWeek + CohortWeeks.MAX_SETTLE_BOUNDARIES - 1;

        return scanCap < _currentWeek
            ? scanCap
            : _currentWeek;
    }

    uint256 internal constant GAP_WORK_RESERVE_MIRROR = 40;

    function _gapWorkWaitingAt(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResume
    )
        internal
        view
        returns (bool)
    {
        uint256 length = recorder.getCohortGapLogLength(
            _referrer
        );

        if (_gapIndex >= length) {
            return false;
        }

        uint256 record = recorder.getCohortGapLogEntry(
            _referrer,
            _gapIndex
        );

        uint256 sliceFrom = CohortWeeks._gapRecordFromWeek(record);

        if (_gapResume > sliceFrom) {
            sliceFrom = _gapResume;
        }

        return sliceFrom < CohortWeeks._gapRecordToWeek(record);
    }

    function _mirrorGaps(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResume,
        uint256 _budget
    )
        internal
        view
        returns (
            uint256[] memory slices,
            uint256 gapIndex,
            uint256 gapResume,
            uint256 workUsed
        )
    {
        uint256 count = _walkGaps(
            _referrer,
            _gapIndex,
            _gapResume,
            _budget,
            new uint256[](0)
        );

        slices = new uint256[](count);

        (
            gapIndex,
            gapResume,
            workUsed
        ) = _walkGapsFilling(
            _referrer,
            _gapIndex,
            _gapResume,
            _budget,
            slices
        );
    }

    function _walkGaps(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResume,
        uint256 _budget,
        uint256[] memory _fill
    )
        internal
        view
        returns (uint256 count)
    {
        (
            count,
            ,
            ,
        ) = _walkGapsCore(
            _referrer,
            _gapIndex,
            _gapResume,
            _budget,
            _fill
        );
    }

    function _walkGapsFilling(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResume,
        uint256 _budget,
        uint256[] memory _fill
    )
        internal
        view
        returns (
            uint256 gapIndex,
            uint256 gapResume,
            uint256 workUsed
        )
    {
        (
            ,
            gapIndex,
            gapResume,
            workUsed
        ) = _walkGapsCore(
            _referrer,
            _gapIndex,
            _gapResume,
            _budget,
            _fill
        );
    }

    function _walkGapsCore(
        address _referrer,
        uint256 _gapIndex,
        uint256 _gapResume,
        uint256 _budget,
        uint256[] memory _fill
    )
        internal
        view
        returns (
            uint256 count,
            uint256 gapIndex,
            uint256 gapResume,
            uint256 workUsed
        )
    {
        uint256 length = recorder.getCohortGapLogLength(
            _referrer
        );

        uint256 left = _budget;

        uint256 resume = _gapResume;

        uint256 index = _gapIndex;

        while (index < length) {

            uint256 record = recorder.getCohortGapLogEntry(
                _referrer,
                index
            );

            uint256 sliceFrom = CohortWeeks._gapRecordFromWeek(
                record
            );

            if (resume > sliceFrom) {
                sliceFrom = resume;
            }

            uint256 sliceTo = CohortWeeks._gapRecordToWeek(
                record
            );

            if (sliceFrom >= sliceTo) {
                ++index;
                resume = 0;
                continue;
            }

            if (left == 0) {
                break;
            }

            uint256 take = left < CohortWeeks.MAX_SETTLE_BOUNDARIES
                ? left
                : CohortWeeks.MAX_SETTLE_BOUNDARIES;

            if (take > sliceTo - sliceFrom) {
                take = sliceTo - sliceFrom;
            }

            if (_fill.length > 0) {
                _fill[count] = CohortWeeks._packGapRecord(
                    sliceFrom,
                    sliceFrom + take,
                    _clampMature(
                        CohortWeeks._gapRecordMature(
                            record
                        )
                    )
                );
            }

            ++count;

            left -= take;

            if (sliceFrom + take == sliceTo) {
                ++index;
                resume = 0;
            } else {
                resume = sliceFrom + take;
            }
        }

        return (
            count,
            index,
            resume,
            _budget - left
        );
    }

    function _clampMature(
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        uint256 ceiling = CohortWeeks.LANE_MASK_80 / CohortWeeks.WEEK;

        return _mature < ceiling
            ? _mature
            : ceiling;
    }

    // ---- small helpers ----

    function _snapshotCursors(
        address[] memory _batch
    )
        internal
        view
        returns (CursorSnap[] memory snaps)
    {
        snaps = new CursorSnap[](
            _batch.length
        );

        for (uint256 i; i < _batch.length; ++i) {
            snaps[i] = _readCursors(
                _batch[i]
            );
        }
    }

    function _readCursors(
        address _referrer
    )
        internal
        view
        returns (CursorSnap memory snap)
    {
        snap.through = flushPolicy.getFlushedThroughWeek(
            _referrer
        );

        (
            snap.gapIndex,
            snap.gapResume
        ) = flushPolicy.getFlushGapCursor(
            _referrer
        );
    }

    function _windowStart(
        address _referrer,
        uint256 _fromSeed,
        uint256 _gapSeed
    )
        internal
        view
        returns (
            uint256 fromWeek,
            uint256 fromGapIndex
        )
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 lo = currentWeek > 130
            ? currentWeek - 130
            : 0;

        fromWeek = bound(
            _fromSeed,
            lo,
            currentWeek
        );

        fromGapIndex = bound(
            _gapSeed,
            0,
            recorder.getCohortGapLogLength(
                _referrer
            )
        );
    }

    function _permitted(
        address _caller
    )
        internal
        view
        returns (bool)
    {
        return flushPolicy.getPublicFlushEnabled()
            || flushPolicy.getAllowedFlushBot(
                _caller
            );
    }

    function _insideDisarmSpan(
        uint256 _week
    )
        internal
        view
        returns (bool)
    {
        uint256 start = _week * CohortWeeks.WEEK;

        for (uint256 i; i < ghostSpanFrom.length; ++i) {

            if (start >= ghostSpanFrom[i] && start + CohortWeeks.WEEK <= ghostSpanTo[i]) {
                return true;
            }
        }

        return false;
    }

    function _booksSettledSinceRearm()
        internal
        view
        returns (bool)
    {
        if (ghostSpanTo.length == 0) {
            return true;
        }

        uint256 rearmedAt = ghostSpanTo[ghostSpanTo.length - 1];

        for (uint256 i; i < referrers.length; ++i) {

            (
                uint256 year1,
                uint256 year2,
                uint256 mature,
                uint256 lastSettle
            ) = recorder.getCohortBook(
                referrers[i]
            );

            uint256 lanes = year1
                + year2
                + mature;

            if (lanes > 0 && lastSettle < rearmedAt) {
                return false;
            }
        }

        return true;
    }

    function _pickReferrer(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return referrers[bound(_seed, 0, referrers.length - 1)];
    }

    function _otherReferrer(
        address _caller,
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 start = bound(
            _seed,
            0,
            referrers.length - 1
        );

        for (uint256 i; i < referrers.length; ++i) {

            address candidate = referrers[(start + i) % referrers.length];

            if (candidate != _caller) {
                return candidate;
            }
        }

        return referrers[0];
    }

    function _pickThirdParty(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 pick = bound(
            _seed,
            0,
            2
        );

        if (pick == 0) {
            return bot;
        }

        if (pick == 1) {
            return stranger;
        }

        return referrers[referrers.length - 1];
    }

    function _seenEarlier(
        address[] memory _batch,
        uint256 _index
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 j; j < _index; ++j) {

            if (_batch[j] == _batch[_index]) {
                return true;
            }
        }

        return false;
    }

    function _countFlushedLogs(
        Vm.Log[] memory _logs,
        address _referrer
    )
        internal
        pure
        returns (uint256 count)
    {
        bytes32 topic = keccak256(
            "CohortReferrerFlushed(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < _logs.length; ++i) {

            if (
                _logs[i].topics.length > 1
                    && _logs[i].topics[0] == topic
                    && address(uint160(uint256(_logs[i].topics[1]))) == _referrer
            ) {
                ++count;
            }
        }
    }

    function _word(
        bytes memory _data,
        uint256 _index
    )
        internal
        pure
        returns (uint256 w)
    {
        if ((_index + 1) * 32 > _data.length) {
            return 0;
        }

        assembly {
            w := mload(
                add(
                    _data,
                    add(
                        0x20,
                        mul(
                            _index,
                            0x20
                        )
                    )
                )
            )
        }
    }
}

/**
 * @dev Stateful-fuzz laws of the flush send cursors
 * (`flushedThroughWeek`, `flushGapCursor`) of {CohortFlushFacet},
 * driven by {CohortFlushCursorHandler} against one fully wired cohort
 * diamond in CCIP mode with a recording router. FC1: the cursors only
 * ever advance (the through week and the gap pair, lexicographically).
 * FC2: the through-week cursor sits below the open week and a nonzero
 * gap resume week below it too, the gap index never beyond the gap
 * log. FC3: both cursors are zero until the referrer's first own
 * flush. FC4: a third party writes a cursor only through a batch and
 * only over a stored through-week cursor, never through a window,
 * and every cursor change emits exactly one {CohortReferrerFlushed},
 * no change none, and a caller the gate refuses never flushes. FC5:
 * every envelope word mirrors the plan the pre-state cursors imply
 * (the header's deliverer, count and stamp, each entry's referrer,
 * counts and flags, the designation word, the self runs (each closed
 * week's realised self presence restated from the self log, read
 * through a routed probe facet, and the self crumb, merged into runs
 * of equal weekly averages), the crumb weeks and words of the closed
 * week scan from the cursor-derived start week (a crumb, a self week
 * and a gap week each costing one unit of work), the gap slices of the walk from the
 * stored pair, the shared work budget in batch order, the exact
 * payload length), and the cursors stored afterwards are exactly the
 * plan's through week and gap position folded with a max into the
 * pre-state, so only the referrer's own flush can set the initial
 * scan edge and only own actions ever skip work. FC6: a cursor
 * advance by a batch never passes a closed week whose final crumb
 * word no envelope carried or a gap week no envelope carried (the
 * documented lookback jump of a first own batch excepted). FC7: a third-party window is accepted exactly
 * when the pre-state predicate holds (the start week above the
 * stored through week and the gap index beyond the stored index, or
 * at it while nothing of that record has shipped) and refused with
 * {FlushWindowInvalid} otherwise, the cursors untouched on refusal;
 * the outage half of the predicate reads the gap log the flush's own
 * pre-plan settle leaves behind (the gate runs after that settle, and
 * a settle across a dormant stretch can append the record the gate
 * then measures), which the handler obtains by running the
 * referrer's own batch flush inside a state snapshot and reverting
 * it; the replay pin of a fuzzed counterexample keeps that case.
 * FC8: no envelope built by another sender carries a closed week the
 * referrer's own flush already shipped and moved its cursor over (the
 * open week's partial crumb is the accepted overlap and is excluded,
 * and so is a closed week a parked own flush shipped while the
 * planner kept the cursor below it: that week can still receive
 * crumbs, so it stays carriable and the hub pays only the increment). FC9: while the
 * recorder is disarmed every flush, own or third party, batch or
 * window, is refused with {CohortSyncDisabled} and leaves the cursors
 * untouched, and after the re-arm no envelope carries a crumb week or
 * a gap week lying wholly inside a disarm span (the engine writes
 * neither).
 */
contract CohortFlushCursorInvariantTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint64 internal constant REMOTE_SELECTOR = 4242;

    address internal constant REMOTE_HUB = address(0xB0B);

    address internal constant BOT = address(0xD1);

    address internal constant STRANGER = address(0xC1);

    address internal constant OUTSIDER = address(0xC2);

    FlushCursorMockUSD internal usd;

    FlushCursorRouter internal router;

    WiseSovrenNodesDiamond internal diamond;

    CohortFlushCursorHandler internal handler;

    address[3] internal referrers;

    receive()
        external
        payable
    {}

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new FlushCursorMockUSD();

        router = new FlushCursorRouter();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        ReferralRegistry registry = _wireReferralRegistry(
            diamond
        );

        _wireOne(
            diamond,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortFlushPolicyFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        _wireOne(
            diamond,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        bytes4[] memory probeSelectors = new bytes4[](1);

        probeSelectors[0] = CohortSelfLogProbeFacet.probeSelfLog.selector;

        _wireOne(
            diamond,
            address(new CohortSelfLogProbeFacet()),
            probeSelectors
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            address(router)
        );

        AdminFacet(address(diamond)).proposeFlushHub(
            REMOTE_HUB,
            REMOTE_SELECTOR
        );

        AdminFacet(address(diamond)).executeFlushHubChange();

        diamond.finalizeSetup();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        referrers = [
            address(0xB1),
            address(0xB2),
            address(0xB3)
        ];

        address[4] memory referees = [
            address(0xA1),
            address(0xA2),
            address(0xA3),
            address(0xA4)
        ];

        _depositWithReferral(
            referees[0],
            referrers[0]
        );

        _depositWithReferral(
            referees[1],
            referrers[0]
        );

        _depositWithReferral(
            referees[2],
            referrers[1]
        );

        _depositWithReferral(
            referees[3],
            referrers[2]
        );

        CohortFlushPolicyFacet(address(diamond)).setAllowedFlushBot(
            BOT,
            true
        );

        CohortFlushPolicyFacet(address(diamond)).setAllowedFlushBot(
            referrers[2],
            true
        );

        handler = new CohortFlushCursorHandler(
            diamond,
            usd,
            router,
            registry,
            address(this),
            referrers,
            referees,
            [
                BOT,
                STRANGER,
                OUTSIDER
            ]
        );

        targetContract(
            address(handler)
        );
    }

    function _depositWithReferral(
        address _user,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            10_000 * 1e6
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            10_000 * 1e6
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            10_000 * 1e6,
            _referrer
        );
    }

    // ---- scripted reach ----

    function test_handlerReplay_settleAppendedGapGatesThirdPartyWindow()
        public
    {
        handler.warpDormant(
            115792089237316195423570985008687907853269984665640564039457584007913129639933
        );

        handler.toggleRecorderArm(
            0
        );

        handler.warpDormant(
            1547545373120615929669237568251541007839163953047551959689939
        );

        handler.toggleRecorderArm(
            8644
        );

        handler.warpDormant(
            23
        );

        handler.thirdPartyWindow(
            2211291614156386789555752862896873712359141431855889811494948025847656974,
            13837711511597233963561096681013434553950750953513667090934174905834171005925,
            918087112182918584186338142516192406836647346444479041532852177647620796,
            3097994091005929883265454200404157240299974264166637388968950747762
        );

        assertEq(handler.outageRefusals(), 1);
        assertEq(handler.ghostWindowPredicateViolations(), 0);
    }

    function test_handlerReach_scriptedSequenceExercisesEveryFlushShape()
        public
    {
        handler.thirdPartyBatch(
            1,
            7,
            0
        );

        handler.referrerDeposit(
            0,
            type(uint256).max
        );

        handler.referrerDeposit(
            1,
            type(uint256).max
        );

        handler.referrerDeposit(
            2,
            type(uint256).max
        );

        handler.designate(
            0,
            0xD5
        );

        handler.thirdPartyBatch(
            0,
            2,
            1
        );

        handler.ownBatch(
            0,
            0
        );

        handler.ownBatch(
            1,
            0
        );

        handler.ownBatch(
            2,
            0
        );

        handler.referrerDeposit(
            0,
            type(uint256).max
        );

        handler.referrerDeposit(
            1,
            type(uint256).max
        );

        handler.referrerDeposit(
            2,
            type(uint256).max
        );

        handler.warpWeeks(
            40
        );

        handler.ownBatch(
            0,
            3
        );

        handler.warpWeeks(
            5
        );

        handler.thirdPartyBatch(
            0,
            1,
            5
        );

        handler.thirdPartyWindow(
            0,
            0,
            0,
            0
        );

        handler.warpWeeks(
            5
        );

        handler.thirdPartyWindow(
            0,
            0,
            type(uint256).max,
            0
        );

        handler.ownBatch(
            2,
            2
        );

        handler.thirdPartyWindow(
            2,
            0,
            type(uint256).max,
            0
        );

        handler.thirdPartyBatch(
            0,
            4,
            5
        );

        handler.warpDormant(
            type(uint256).max
        );

        handler.warpDormant(
            type(uint256).max
        );

        handler.ownBatch(
            0,
            0
        );

        handler.ownBatch(
            1,
            0
        );

        handler.ownBatch(
            2,
            0
        );

        handler.thirdPartyWindow(
            0,
            0,
            type(uint256).max,
            0
        );

        handler.thirdPartyBatch(
            0,
            1,
            5
        );

        handler.togglePublicFlush(
            0
        );

        handler.thirdPartyBatch(
            1,
            7,
            0
        );

        handler.ownWindow(
            2,
            0,
            0
        );

        handler.transferOut(
            0,
            type(uint256).max
        );

        handler.advanceBook(
            1,
            type(uint256).max
        );

        handler.toggleRecorderArm(
            0
        );

        handler.ownBatch(
            0,
            0
        );

        handler.thirdPartyWindow(
            0,
            0,
            type(uint256).max,
            0
        );

        handler.warpWeeks(
            3
        );

        handler.warpWeeks(
            3
        );

        handler.toggleRecorderArm(
            0
        );

        handler.ownBatch(
            0,
            0
        );

        handler.thirdPartyBatch(
            1,
            7,
            0
        );

        handler.thirdPartyWindow(
            0,
            0,
            0,
            0
        );

        handler.thirdPartyWindow(
            0,
            0,
            type(uint256).max,
            0
        );

        assertGe(
            handler.flushCount(),
            10,
            "reach: fewer accepted flushes than the script drives"
        );

        assertGe(
            handler.callerRefusals(),
            1,
            "reach: the stranger was not refused before the public switch"
        );

        assertGe(
            handler.windowRefusals(),
            2,
            "reach: the window start gate refused fewer than two staged windows"
        );

        assertGe(
            handler.acceptedThirdPartyWindows(),
            2,
            "reach: fewer accepted third-party windows than the script drives"
        );

        assertEq(
            handler.thirdPartyWrites(),
            0,
            "lane: a third-party flush wrote a send cursor"
        );

        assertGe(
            handler.laneRefusals(),
            1,
            "reach: the third-party lane gates never refused a flush"
        );

        assertGe(
            handler.midRecordGapStops(),
            1,
            "reach: the shared work budget never stopped an entry mid record"
        );

        assertGe(
            handler.midRecordGapStops(),
            1,
            "reach: no gap walk stopped inside a record"
        );

        assertGe(
            handler.designations(),
            1,
            "reach: no designation word was carried"
        );

        assertGt(
            CohortRecorderFacet(address(diamond)).getCohortGapLogLength(
                referrers[0]
            ),
            0,
            "reach: the dormant span wrote no gap record"
        );

        assertGe(
            handler.armToggles(),
            2,
            "reach: the recorder was not disarmed and re-armed"
        );

        assertGe(
            handler.disarmedRefusals(),
            2,
            "reach: a flush while disarmed was not refused with CohortSyncDisabled"
        );

        assertGe(
            handler.outageRefusals(),
            1,
            "reach: the outage gate never refused a third-party flush inside the grace"
        );

        invariant_FC1_cursorsMonotone();

        invariant_FC2_throughCursorBelowOpenWeek();

        invariant_FC3_cursorsZeroUntilFirstOwnFlush();

        invariant_FC4_thirdPartyWritesOnlyBatchOverStoredCursorOneLogPerChange();

        invariant_FC5_envelopeAndCursorsMirrorThePlanFromPreStateCursors();

        invariant_FC6_noStrandingBehindBatchCursorAdvances();

        invariant_FC7_thirdPartyWindowPredicateOnPreState();

        invariant_FC8_noLaterSenderCarriesOwnShippedClosedWeek();

        invariant_FC9_disarmRefusesFlushAndSpanWeeksShipNothing();
    }

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC1_cursorsMonotone()
        public
        view
    {
        assertEq(
            handler.ghostMonotoneViolations(),
            0,
            "FC1: a cursor moved backwards"
        );

        for (uint256 i; i < referrers.length; ++i) {

            (
                uint256 gapIndex,
                uint256 gapResume
            ) = CohortFlushPolicyFacet(address(diamond)).getFlushGapCursor(
                referrers[i]
            );

            assertEq(
                CohortFlushPolicyFacet(address(diamond)).getFlushedThroughWeek(
                    referrers[i]
                ),
                handler.ghostThrough(referrers[i]),
                "FC1: the through cursor moved outside a flush"
            );

            assertEq(
                gapIndex,
                handler.ghostGapIndex(referrers[i]),
                "FC1: the gap index moved outside a flush"
            );

            assertEq(
                gapResume,
                handler.ghostGapResume(referrers[i]),
                "FC1: the gap resume week moved outside a flush"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC2_throughCursorBelowOpenWeek()
        public
        view
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        for (uint256 i; i < referrers.length; ++i) {

            (
                uint256 gapIndex,
                uint256 gapResume
            ) = CohortFlushPolicyFacet(address(diamond)).getFlushGapCursor(
                referrers[i]
            );

            assertLt(
                CohortFlushPolicyFacet(address(diamond)).getFlushedThroughWeek(
                    referrers[i]
                ),
                currentWeek,
                "FC2: the through cursor reached the open week"
            );

            assertTrue(
                gapResume == 0 || gapResume < currentWeek,
                "FC2: the gap resume week reached the open week"
            );

            assertLe(
                gapIndex,
                CohortRecorderFacet(address(diamond)).getCohortGapLogLength(
                    referrers[i]
                ),
                "FC2: the gap index passed the gap log"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC3_cursorsZeroUntilFirstOwnFlush()
        public
        view
    {
        assertEq(
            handler.ghostVirginWriteViolations(),
            0,
            "FC3: a cursor was written before the referrer's own flush"
        );

        for (uint256 i; i < referrers.length; ++i) {

            if (handler.ghostOwnFlushed(referrers[i])) {
                continue;
            }

            (
                uint256 gapIndex,
                uint256 gapResume
            ) = CohortFlushPolicyFacet(address(diamond)).getFlushGapCursor(
                referrers[i]
            );

            assertEq(
                CohortFlushPolicyFacet(address(diamond)).getFlushedThroughWeek(
                    referrers[i]
                ),
                0,
                "FC3: a virgin through cursor is nonzero"
            );

            assertEq(
                gapIndex,
                0,
                "FC3: a virgin gap index is nonzero"
            );

            assertEq(
                gapResume,
                0,
                "FC3: a virgin gap resume week is nonzero"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC4_thirdPartyWritesOnlyBatchOverStoredCursorOneLogPerChange()
        public
        view
    {
        assertEq(
            handler.ghostThirdPartyWriteViolations(),
            0,
            "FC4: a third party wrote a cursor through a window or over a virgin cursor"
        );

        assertEq(
            handler.ghostLogCountViolations(),
            0,
            "FC4: a cursor change did not emit exactly one CohortReferrerFlushed"
        );

        assertEq(
            handler.ghostCallerGateViolations(),
            0,
            "FC4: a caller the gate must refuse flushed, or the gate reverted with another reason"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC5_envelopeAndCursorsMirrorThePlanFromPreStateCursors()
        public
        view
    {
        assertEq(
            handler.ghostPlanMirrorViolations(),
            0,
            "FC5: an envelope or a stored cursor departed from the plan the pre-state cursors imply"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC6_noStrandingBehindBatchCursorAdvances()
        public
        view
    {
        assertEq(
            handler.ghostStrandingViolations(),
            0,
            "FC6: a batch cursor advance passed a closed week whose final word no envelope carried"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC7_thirdPartyWindowPredicateOnPreState()
        public
        view
    {
        assertEq(
            handler.ghostWindowPredicateViolations(),
            0,
            "FC7: the window verdict disagreed with the pre-state predicate"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC8_noLaterSenderCarriesOwnShippedClosedWeek()
        public
        view
    {
        assertEq(
            handler.ghostOwnWeekResendViolations(),
            0,
            "FC8: another sender re-carried a closed week the referrer's own flush shipped"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FC9_disarmRefusesFlushAndSpanWeeksShipNothing()
        public
        view
    {
        assertEq(
            handler.ghostDisarmViolations(),
            0,
            "FC9: a flush ran or refused with another reason while disarmed, or an envelope carried a week inside a disarm span"
        );
    }
}
