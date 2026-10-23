// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";

import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {IReferralHub} from "../referral/hub/IReferralHub.sol";
import {HubLeverGrants} from "../referral/hub/utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../referral/hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../referral/hub/ReferralHubReader.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {OnlyDelegateCall, FacetNotFound} from "../../src/diamond/shared/DiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

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
 * @dev Records outbound CCIP sends without relaying them: `getFee`
 * returns a flat fee, `ccipSend` demands exactly that fee (the flush
 * facet forwards `{value: fee}`), stores the raw message fields for
 * envelope decoding by the test, and derives a deterministic
 * messageId so `CohortFlushSent` can be asserted with `expectEmit`.
 */
contract MockFlushCcipRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 public sendCount;

    uint64 public lastSelector;

    bytes public lastReceiver;

    bytes public lastData;

    bytes public lastExtraArgs;

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

        lastSelector = _destChainSelector;
        lastReceiver = _message.receiver;
        lastData = _message.data;
        lastExtraArgs = _message.extraArgs;

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
 * @dev Records outbound CCIP sends with a payload-size-dependent
 * fee: `getFee` grows linearly with the message data length and
 * `ccipSend` demands exactly that fee, so the suite can prove that
 * `quoteFlushFee` (which plans on unsettled storage) is a strict
 * lower bound once execution settles and grows the envelope, and
 * that a window send over a subset slice never costs more than the
 * cursor-planned quote.
 */
contract SizeFeeCcipRouter {

    uint256 public constant BASE_FEE = 0.001 ether;

    uint256 public constant FEE_PER_BYTE = 1e12;

    uint256 public lastFee;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory _message
    )
        external
        pure
        returns (uint256)
    {
        return BASE_FEE + _message.data.length * FEE_PER_BYTE;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        require(
            msg.value == BASE_FEE + _message.data.length * FEE_PER_BYTE,
            "WRONG_FEE"
        );

        lastFee = msg.value;

        return bytes32(
            msg.value
        );
    }
}

/**
 * @dev Reverts on every call, used as etched code on the registry
 * address to prove the designation piggyback degrades silently.
 */
contract RevertingDesignationMock {

    fallback()
        external
    {
        revert();
    }
}

/**
 * @dev Returns a first word wider than an address, used as etched
 * code on the registry address to prove the guarded designation read
 * rejects dirty payout words.
 */
contract WideAddressDesignationMock {

    function getPayoutDesignation(
        address
    )
        external
        pure
        returns (
            uint256,
            uint256
        )
    {
        return (
            uint256(1) << 160,
            1
        );
    }
}

/**
 * @dev Returns a stamp whose timestamp half exceeds uint64, used as
 * etched code on the registry address to prove the guarded
 * designation read rejects out-of-range stamps.
 */
contract HugeStampDesignationMock {

    function getPayoutDesignation(
        address
    )
        external
        pure
        returns (
            uint256,
            uint256
        )
    {
        return (
            uint256(uint160(address(0xEE))),
            uint256(1) << 80
        );
    }
}

/**
 * @dev Calls `flushReferrals` on its own book with excess value and
 * rejects the native refund, exercising the `FlushRefundFailed`
 * revert path.
 */
contract FlushRefundRejector {

    function run(
        address _diamond
    )
        external
        payable
    {
        address[] memory refs = new address[](1);

        refs[0] = address(this);

        CohortFlushFacet(_diamond).flushReferrals{value: msg.value}(
            refs
        );
    }

    receive()
        external
        payable
    {
        revert();
    }
}

/**
 * @dev Vault-side flush transport suite: the flush-hub pointer's
 * propose/execute/cancel timelock (instant pre-finalize, 3-day
 * afterwards, zero-hub-nonzero-selector shape rejected at execute),
 * the flush policy levers (bot whitelist, public switch, CCIP gas
 * budget; a lever set to its current value writes and emits nothing),
 * the default-off guarantee while the pointer is unset, and
 * both delivery modes of {CohortFlushFacet}: LOCAL direct-call
 * delivery end-to-end against a REAL {ReferralHub} with every
 * expected claimable computed independently from recorder words and
 * `weeklyRates`, and REMOTE CCIP delivery asserted by decoding the
 * exact packed flush envelope out of a recording mock router:
 * header, entry, scores, designation, crumb pairs and pre-sliced gap
 * records word by word. Cursor behavior (catch-up window start,
 * ~104-week advance per flush, gap-record slicing across flushes,
 * work-budget degradation to entries without crumbs, a third-party
 * batch writing no cursor while the stored one is virgin and
 * advancing it once the referrer's own flush has set it) is pinned
 * against real recorder histories, never hand-built words. The window
 * entrypoint is additionally exercised in CCIP mode (payable fee and
 * exact-excess refund, envelope restricted to the requested slice
 * with the caller stamped as deliverer, the shared foreign-book
 * gate); in local mode a third-party window is refused unless it
 * starts after both stored cursors while an own window may start
 * anywhere; and a size-dependent fee mock pins `quoteFlushFee` as a
 * strict lower bound when storage settles and grows between quote
 * and execution, the courier's mandatory over-funding margin.
 * `previewFlushEnvelope` is pinned byte-identical to the CCIP send
 * for a settled book, header-decoded in local mode with the caller
 * as deliverer, a lower bound on the sent envelope before
 * settlement, and gated by the same three batch guards as the
 * quote. `getFlushCursors` is pinned element by element against
 * `getFlushedThroughWeek` and `getFlushGapCursor` over a batch that
 * mixes a fresh gap slice, a mid-walk gap cursor and a never-flushed
 * book, and returns three empty arrays for an empty batch. A book that
 * emptied between two of its own CCIP flushes is replayed to the real
 * hub through the mailbox on mirrored referrers, one whose full
 * envelope lands a week late behind the emptied one and one whose full
 * envelope landed in its own week, pinning the one-week skew of the
 * referred aggregate between the two (the late full envelope has its
 * score half refused as stale and retains nothing, the in-week one is
 * retained for the earlier bucket); nothing prices in that fixture
 * because no checkpoint precedes the delivered weeks. The self score is
 * pinned as the lower of the ledger value clamped to the held balance
 * and the referrer's own-stake presence during the completed previous
 * week, read from the per-account self crumb: a fresh deposit reports
 * zero until a week completes and is pro-rated for its arrival inside
 * the week, a top-up made in the flush week is floored at the stake
 * held through the previous week, a deposit moved away inside one block
 * counts nothing, and a transfer in the flush block (the sender still
 * parked, its ledger lagging) is clamped to the balance at once, every
 * clamp pin giving the stake a completed week first so it proves the
 * clamp and not the floor. The dormant-book builders ship the
 * referrer's completed first week through an allowlisted bot window
 * at week 3002, so the hub holds a nonzero self and referred
 * checkpoint while the referrer's own send cursors stay untouched (a
 * third-party window never writes a cursor). A planted gap record
 * whose mature principal
 * exceeds the per-week lane ceiling reads clamped on the referred
 * presence read exactly as on the wire. Both flush entrypoints
 * refuse a recorder that is not fully armed: a disarmed switch
 * ({CohortSyncDisabled}), a zero transfer-hook pointer
 * ({CohortHookNotInstalled}, written directly because the AdminFacet
 * refuses a zero hook while armed) and a zero registry pointer
 * ({ReferralRegistryNotSet}, written directly because the AdminFacet
 * refuses a registry change while armed; the pointer returns through
 * a disarm, the execute and a re-arm in one second); every refusal
 * leaves the cursors and
 * the hub claimable untouched, the weeks of the outage ship with the
 * first own flush once the pointer returns, and the quote and the
 * preview keep planning in all three states. Local mode never reads
 * the payout designation, so a local preview carries none even after
 * the referrer designated. A disarm span is zero-weighted: after the
 * re-arm the first own flush ships no crumb for the weeks the span
 * covered and leaves the hub claimable unchanged, and the book
 * resumes at the re-arm instant. A batch that lists one referrer
 * twice prices each week once at the hub, and the payout designation
 * of a rank-two registry rides the remote envelope as
 * `packFlushDesignation(payout, setAt, 2)` and lands on the hub under
 * the same packed stamp.
 */
contract WiseSovrenNodesCohortFlushTest is DiamondTestHarness, HubDiamondHarness {

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    event FlushHubSet(
        address flushHub,
        uint64 flushHubChainSelector
    );

    event FlushHubProposed(
        address indexed proposedFlushHub,
        uint64 proposedFlushHubChainSelector,
        uint256 executableAt
    );

    event FlushHubProposalCancelled(
        address indexed cancelledFlushHub
    );

    event FlushBotAllowedSet(
        address indexed bot,
        bool allowed
    );

    event PublicFlushEnabledSet(
        bool enabled
    );

    event FlushGasLimitSet(
        uint64 flushGasLimit
    );

    event CohortFlushSent(
        bytes32 indexed messageId,
        uint64 indexed destChainSelector,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortFlushDelivered(
        address indexed flushHub,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortReferrerFlushed(
        address indexed referrer,
        uint256 flushedThroughWeek,
        uint256 flushedGapIndex,
        uint256 gapResumeWeek
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant FLUSH_HUB_DELAY = 3 days;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint64 internal constant REMOTE_SELECTOR = 4242;

    uint256 internal constant FIXED_FEE = 0.01 ether;

    uint256 internal constant LOCAL_ENTRIES = 6;

    uint256 internal constant LOCAL_FLUSH_GAS_CEILING = 14_000_000;

    uint256 internal constant TRANSFER_HOOK_SLOT = 45;

    uint256 internal constant REGISTRY_SLOT = 77;

    uint256 internal constant REGISTRY_DELAY = 3 days;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal user3 = address(0xA3);
    address internal user4 = address(0xA4);
    address internal refA = address(0xB1);
    address internal bigR = address(0xB5);
    address internal smallR = address(0xB6);
    address internal refD = address(0xB7);
    address internal refE = address(0xB8);
    address internal stranger = address(0xC1);
    address internal bot = address(0xD1);
    address internal reporter2 = address(0xE2);

    MockUSD internal usd;
    IReferralHub internal hub;
    ReferralHubReader internal reader;
    MockFlushCcipRouter internal router;

    WiseSovrenNodesDiamond internal diamond;
    WiseSovrenNodesDiamond internal rdiamond;

    ReferralRegistry internal localRegistry;
    ReferralRegistry internal remoteRegistry;

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

        usd = new MockUSD();

        hub = _deployHub(
            address(usd)
        );

        reader = new ReferralHubReader(
            address(hub)
        );

        router = new MockFlushCcipRouter();

        (
            diamond,
            localRegistry
        ) = _buildFlushDiamond(
            0,
            false
        );

        (
            rdiamond,
            remoteRegistry
        ) = _buildFlushDiamond(
            REMOTE_SELECTOR,
            true
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(diamond),
                    true
                )
            )
        );

        vm.deal(
            address(this),
            100 ether
        );
    }

    // ---- helpers ----

    function _buildFlushDiamond(
        uint64 _selector,
        bool _withRouter
    )
        internal
        returns (
            WiseSovrenNodesDiamond d,
            ReferralRegistry reg
        )
    {
        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
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

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        reg = _wireReferralRegistry(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _wireOne(
            d,
            address(new CohortFlushPolicyFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        if (_withRouter) {

            _wireOne(
                d,
                address(new BridgeFacet()),
                WiseSovrenNodesDiamondSelectors._bridgeSelectors()
            );

            BridgeFacet(address(d)).setCcipRouter(
                address(router)
            );
        }

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            _selector
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    function _flush(
        WiseSovrenNodesDiamond _d
    )
        internal
        pure
        returns (CohortFlushFacet)
    {
        return CohortFlushFacet(
            address(_d)
        );
    }

    function _flushPolicy(
        WiseSovrenNodesDiamond _d
    )
        internal
        pure
        returns (CohortFlushPolicyFacet)
    {
        return CohortFlushPolicyFacet(
            address(_d)
        );
    }

    function _admin(
        WiseSovrenNodesDiamond _d
    )
        internal
        pure
        returns (AdminFacet)
    {
        return AdminFacet(
            address(_d)
        );
    }

    function _rec(
        WiseSovrenNodesDiamond _d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(_d)
        );
    }

    function _depositWithReferralOn(
        WiseSovrenNodesDiamond _d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_d),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _depositOn(
        WiseSovrenNodesDiamond _d,
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_d),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_d)).deposit(
            _amount
        );
    }

    function _advanceBooks(
        WiseSovrenNodesDiamond _d,
        address[] memory _refs
    )
        internal
    {
        for (uint256 i; i < _refs.length; ++i) {

            for (uint256 k; k < 8; ++k) {

                (
                    ,
                    ,
                    ,
                    uint256 lastSettle
                ) = _rec(_d).getCohortBook(
                    _refs[i]
                );

                if (lastSettle / 1 weeks == block.timestamp / 1 weeks) {
                    break;
                }

                _rec(_d).advanceBook(
                    _refs[i],
                    104
                );
            }
        }
    }

    function _oneRef(
        address _referrer
    )
        internal
        pure
        returns (address[] memory refs)
    {
        refs = new address[](1);

        refs[0] = _referrer;
    }

    function _flushOwnLocal(
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.prank(
            _referrer
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function _flushOwnOn(
        WiseSovrenNodesDiamond _d,
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.prank(
            _referrer
        );

        _flush(_d).flushReferrals(
            refs
        );
    }

    function _flushOwnRemote(
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.deal(
            _referrer,
            _referrer.balance + FIXED_FEE
        );

        vm.prank(
            _referrer
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            refs
        );
    }

    function _flushBotRemote(
        address[] memory _refs
    )
        internal
    {
        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            _refs
        );
    }

    function _expectedPay(
        uint256 _word,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        return (
            CohortWeeks._laneY1(_word) * y1Bps
                + CohortWeeks._laneY2(_word) * y2Bps
                + CohortWeeks._laneM(_word) * mBps
        ) / (10_000 * CohortWeeks.YEAR);
    }

    function _expectedGapPay(
        uint256 _mature,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return _expectedPay(
            CohortWeeks._packLanes(
                0,
                0,
                _mature * CohortWeeks.WEEK
            ),
            _referrer,
            _week
        );
    }

    function _expectedCrumbRangePay(
        WiseSovrenNodesDiamond _d,
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekInclusive
    )
        internal
        view
        returns (uint256 expected)
    {
        for (uint256 week = _fromWeek; week <= _toWeekInclusive; ++week) {

            expected += _expectedPay(
                _rec(_d).getCohortWeekCrumb(
                    _referrer,
                    week
                ),
                _referrer,
                week
            );
        }
    }

    function _expectedGapRangePay(
        uint256 _mature,
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekExclusive
    )
        internal
        view
        returns (uint256 expected)
    {
        for (uint256 week = _fromWeek; week < _toWeekExclusive; ++week) {

            expected += _expectedGapPay(
                _mature,
                _referrer,
                week
            );
        }
    }

    function _selfAverageInEnvelope(
        bytes memory _envelope,
        uint256 _week
    )
        internal
        pure
        returns (uint256)
    {
        uint256 entryWord = _envWord(
            _envelope,
            1
        );

        uint256 cursor = CohortFlushCodec._flushEntryFlags(entryWord) & CohortFlushCodec.FLUSH_FLAG_DESIGNATION != 0
            ? 3
            : 2;

        uint256 runCount = CohortFlushCodec._flushEntrySelfRunCount(
            entryWord
        );

        for (uint256 i; i < runCount; ++i) {

            uint256 run = _envWord(
                _envelope,
                cursor + i
            );

            if (
                CohortFlushCodec._selfRunFromWeek(run) <= _week
                    && _week < CohortFlushCodec._selfRunToWeek(run)
            ) {
                return CohortFlushCodec._selfRunAverage(
                    run
                );
            }
        }

        return 0;
    }

    function _envWord(
        bytes memory _data,
        uint256 _index
    )
        internal
        pure
        returns (uint256 w)
    {
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

    function _countReferrerFlushedLogs()
        internal
        view
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CohortReferrerFlushed(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _newBareFlushDiamond(
        uint64 _selector
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _wireOne(
            d,
            address(new CohortFlushPolicyFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            _selector
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();
    }

    function _buildSizeFeeDiamond()
        internal
        returns (
            WiseSovrenNodesDiamond d,
            SizeFeeCcipRouter sizeRouter
        )
    {
        sizeRouter = new SizeFeeCcipRouter();

        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
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

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _wireOne(
            d,
            address(new CohortFlushPolicyFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        BridgeFacet(address(d)).setCcipRouter(
            address(sizeRouter)
        );

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            REMOTE_SELECTOR
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    // ---- pointer lifecycle ----

    function test_flushHubPointer_wiredInstantlyPreFinalize()
        public
        view
    {
        (
            address localHub,
            uint64 localSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            localHub,
            address(hub)
        );

        assertEq(
            localSelector,
            0
        );

        (
            address remoteHub,
            uint64 remoteSelector
        ) = _admin(rdiamond).getFlushHub();

        assertEq(
            remoteHub,
            address(hub)
        );

        assertEq(
            remoteSelector,
            REMOTE_SELECTOR
        );

        (
            address proposedHub,
            uint64 proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0)
        );

        assertEq(
            proposedSelector,
            0
        );

        assertEq(
            _admin(
                diamond
            ).getFlushHubChangeQueuedAt(),
            0
        );
    }

    function test_flushHubPointer_lifecycleGettersAndCancel()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubProposed(
            address(0xF1),
            7,
            block.timestamp + FLUSH_HUB_DELAY
        );

        _admin(diamond).proposeFlushHub(
            address(0xF1),
            7
        );

        (
            address proposedHub,
            uint64 proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0xF1)
        );

        assertEq(
            proposedSelector,
            7
        );

        assertEq(
            _admin(
                diamond
            ).getFlushHubChangeQueuedAt(),
            block.timestamp
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubProposalCancelled(
            address(0xF1)
        );

        _admin(
            diamond
        ).cancelFlushHubChange();

        (
            proposedHub,
            proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0)
        );

        assertEq(
            proposedSelector,
            0
        );

        assertEq(
            _admin(
                diamond
            ).getFlushHubChangeQueuedAt(),
            0
        );

        (
            address keptHub,
            uint64 keptSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            keptHub,
            address(hub)
        );

        assertEq(
            keptSelector,
            0
        );
    }

    function test_flushHubPointer_timelockedExecuteAfterFinalize()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0xF1),
            9
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubTimelockNotElapsed.selector
        );

        _admin(
            diamond
        ).executeFlushHubChange();

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubSet(
            address(0xF1),
            9
        );

        _admin(
            diamond
        ).executeFlushHubChange();

        (
            address newHub,
            uint64 newSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            newHub,
            address(0xF1)
        );

        assertEq(
            newSelector,
            9
        );
    }

    function test_RevertWhen_executeFlushHubChange_nothingProposed()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoFlushHubChangeProposed.selector
        );

        _admin(
            diamond
        ).executeFlushHubChange();
    }

    function test_RevertWhen_executeFlushHubChange_zeroHubNonzeroSelector()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0),
            7
        );

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _admin(
            diamond
        ).executeFlushHubChange();
    }

    function test_flushHubPointer_zeroProposal_detachesToOffState()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0),
            0
        );

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        _admin(
            diamond
        ).executeFlushHubChange();

        (
            address detachedHub,
            uint64 detachedSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            detachedHub,
            address(0)
        );

        assertEq(
            detachedSelector,
            0
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushHubPointer_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(diamond).proposeFlushHub(
            address(0xF1),
            0
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(
            diamond
        ).executeFlushHubChange();

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(
            diamond
        ).cancelFlushHubChange();
    }

    // ---- flush policy ----

    function test_setAllowedFlushBot_setsAndEmits()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushBotAllowedSet(
            bot,
            true
        );

        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        assertTrue(
            _flushPolicy(diamond).getAllowedFlushBot(
                bot
            )
        );

        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            false
        );

        assertFalse(
            _flushPolicy(diamond).getAllowedFlushBot(
                bot
            )
        );
    }

    function test_setAllowedFlushBot_unchangedValue_emitsNothing()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.recordLogs();

        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _flushPolicy(diamond).setAllowedFlushBot(
            address(0xD2),
            false
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertTrue(
            _flushPolicy(diamond).getAllowedFlushBot(
                bot
            )
        );

        assertFalse(
            _flushPolicy(diamond).getAllowedFlushBot(
                address(0xD2)
            )
        );
    }

    function test_RevertWhen_setAllowedFlushBot_zeroBot()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _flushPolicy(diamond).setAllowedFlushBot(
            address(0),
            true
        );
    }

    function test_setPublicFlushEnabled_setsAndEmits()
        public
    {
        assertFalse(
            _flushPolicy(
                diamond
            ).getPublicFlushEnabled()
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit PublicFlushEnabledSet(
            true
        );

        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        assertTrue(
            _flushPolicy(
                diamond
            ).getPublicFlushEnabled()
        );

        _flushPolicy(diamond).setPublicFlushEnabled(
            false
        );

        assertFalse(
            _flushPolicy(
                diamond
            ).getPublicFlushEnabled()
        );
    }

    function test_setPublicFlushEnabled_unchangedValue_emitsNothing()
        public
    {
        vm.recordLogs();

        _flushPolicy(diamond).setPublicFlushEnabled(
            false
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertFalse(
            _flushPolicy(
                diamond
            ).getPublicFlushEnabled()
        );
    }

    function test_setFlushGasLimit_boundsAndEmits()
        public
    {
        assertEq(
            _flushPolicy(
                diamond
            ).getFlushGasLimit(),
            0
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushGasLimitSet(
            300_000
        );

        _flushPolicy(diamond).setFlushGasLimit(
            300_000
        );

        assertEq(
            _flushPolicy(
                diamond
            ).getFlushGasLimit(),
            300_000
        );

        _flushPolicy(diamond).setFlushGasLimit(
            2_000_000
        );

        assertEq(
            _flushPolicy(
                diamond
            ).getFlushGasLimit(),
            2_000_000
        );
    }

    function test_setFlushGasLimit_unchangedValue_emitsNothing()
        public
    {
        _flushPolicy(diamond).setFlushGasLimit(
            300_000
        );

        vm.recordLogs();

        _flushPolicy(diamond).setFlushGasLimit(
            300_000
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            _flushPolicy(
                diamond
            ).getFlushGasLimit(),
            300_000
        );
    }

    function test_RevertWhen_setFlushGasLimit_outOfBounds()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidFlushGasLimit.selector
        );

        _flushPolicy(diamond).setFlushGasLimit(
            299_999
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidFlushGasLimit.selector
        );

        _flushPolicy(diamond).setFlushGasLimit(
            2_000_001
        );
    }

    function test_RevertWhen_flushPolicy_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flushPolicy(diamond).setFlushGasLimit(
            300_000
        );
    }

    // ---- default-off ----

    function test_RevertWhen_flushHubUnset_allEntrypoints()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        _wireOne(
            bare,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        bare.finalizeSetup();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).flushReferralWindow(
            refA,
            0,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).quoteFlushFee(
            refs
        );
    }

    // ---- gating ----
    function test_RevertWhen_flushReferrals_localBatchOverLocalEntryCap()
        public
    {
        address[] memory refs = new address[](
            LOCAL_ENTRIES + 1
        );

        for (uint256 i; i < refs.length; ++i) {
            refs[i] = refA;
        }

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).previewFlushEnvelope(
            refs
        );
    }

    function test_flushReferrals_batchOverParkedBook_advancedToTheDisarm()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 1 days
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        address[] memory refs = new address[](2);

        refs[0] = refA;
        refs[1] = refA;

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBookNotAdvanced.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        _advanceBooks(
            diamond,
            refs
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _rec(diamond).getCohortBook(
            refA
        );

        assertEq(
            lastSettle,
            BASE_TIME + 2 weeks + 1 days
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function test_flushOwn_refereeGetsNoHubRecord()
        public
    {
        _depositWithReferralOn(
            diamond,
            user2,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                user2,
                3_000
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                user2,
                3_001
            ),
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                user2
            ),
            0
        );
    }

    function test_RevertWhen_flushReferrals_remoteBatchOverUnadvancedBook()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        address[] memory refs = new address[](2);

        refs[0] = refA;
        refs[1] = refA;

        vm.deal(
            refA,
            FIXED_FEE
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBookNotAdvanced.selector
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            refs
        );

        _advanceBooks(
            rdiamond,
            refs
        );

        vm.prank(
            refA
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            refs
        );

        assertEq(
            _flushPolicy(rdiamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function test_RevertWhen_flushReferrals_emptyBatch()
        public
    {
        address[] memory refs = new address[](0);

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToFlush.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToFlush.selector
        );

        _flush(diamond).quoteFlushFee(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_batchTooLarge()
        public
    {
        address[] memory refs = new address[](17);

        for (uint256 i; i < 17; ++i) {
            refs[i] = address(
                uint160(0x1000 + i)
            );
        }

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).quoteFlushFee(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_zeroReferrer()
        public
    {
        address[] memory refs = _oneRef(
            address(0)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_strangerFlushesForeignBook()
        public
    {
        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_allowedBotPasses()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            bot,
            1
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_publicFlushPasses()
        public
    {
        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_ownBookAlwaysPasses()
        public
    {
        address[] memory refs = _oneRef(
            stranger
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_thirdPartyBatchOnVirginCursor_refused()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushCursorVirgin.selector
        );

        _flush(diamond).flushReferrals(
            _oneRef(
                refA
            )
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            0
        );
    }

    function test_flushReferrals_botBatchOnQuietLiveBook_writesNoCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _seedOwnFlushedBook();

        vm.warp(
            BASE_TIME + 5 weeks
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            _oneRef(
                refA
            )
        );

        vm.warp(
            BASE_TIME + 10 weeks
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            _oneRef(
                refA
            )
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function test_flushWindow_allowedBotAheadOfCursor_passes()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _seedOwnFlushedBook();

        vm.warp(
            3_008 weeks + 1 days
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_007,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function test_RevertWhen_flushReferrals_mixedBatchForeignVirgin_refusesWholeBatch()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositWithReferralOn(
            diamond,
            user2,
            10_000 * 1e6,
            bot
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        address[] memory refs = new address[](2);

        refs[0] = refA;
        refs[1] = bot;

        _advanceBooks(
            diamond,
            refs
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushCursorVirgin.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                bot
            ),
            0
        );
    }

    function test_RevertWhen_flushReferrals_thirdPartyBatchOnVirginCursor_gapBook_refused()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushCursorVirgin.selector
        );

        _flush(diamond).flushReferrals(
            _oneRef(
                refA
            )
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            0
        );
    }

    function test_flushReferrals_thirdPartyBatch_deliversGapTailWithoutCursorWrite()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        _flushOwnLocal(
            refA
        );

        uint256 mature = CohortWeeks._gapRecordMature(
            _rec(diamond).getCohortGapLogEntry(
                refA,
                0
            )
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            _oneRef(
                refA
            )
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_055
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_288
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBefore
                + _expectedCrumbRangePay(
                    diamond,
                    refA,
                    3_056,
                    3_083
                )
                + _expectedGapRangePay(
                    mature,
                    refA,
                    3_288,
                    3_328
                )
        );

        _assertPaidCursorSet(
            3_083
        );

        _assertPaidCursorSet(
            3_327
        );
    }

    function _assertPaidCursorSet(
        uint256 _week
    )
        internal
        view
    {
        (
            uint256 y1Paid,
            uint256 y2Paid,
            uint256 mPaid
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            _week
        );

        assertGt(
            y1Paid + y2Paid + mPaid,
            0
        );
    }

    function test_RevertWhen_flush_paused()
        public
    {
        _admin(
            diamond
        ).pauseDeposits();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        _flush(diamond).flushReferralWindow(
            refA,
            0,
            0
        );
    }

    function _readReopenStamp()
        internal
        view
        returns (uint64)
    {
        bytes32 slot = vm.load(
            address(diamond),
            bytes32(
                uint256(
                    93
                )
            )
        );

        return uint64(
            uint256(
                slot
            ) >> 128
        );
    }

    function test_RevertWhen_flushReferrals_botFlushDuringOutageGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        assertEq(
            _readReopenStamp(),
            uint64(
                BASE_TIME + 12 hours
            )
        );

        vm.warp(
            BASE_TIME + 18 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_ownFlushDuringOutageGracePasses()
        public
    {
        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 18 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_botFlushAfterOutageGracePasses()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 36 hours
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 48 hours + 1 seconds
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_botFlushDuringGrace_midRecordGapCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            block.timestamp + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            block.timestamp + 6 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferralWindow_botWindowAfterReopenBoundaryPasses()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 18 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );
    }

    /**
     * @dev the settle-appended record spans only weeks that closed
     * after the reopen, so the first arm of the outage gate
     * carries it even inside the grace: the referrer never had
     * a window to flush those weeks before the outage, and the
     * own cursor the bot must stay behind still never moves
     */
    function test_flushWindow_thirdPartyGapSliceAfterReopenBoundary_carriesDuringGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );

        _flushOwnLocal(
            refA
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            3_400 weeks + 1 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            3_400 weeks + 7 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_400,
            1
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_400,
            1
        );
    }

    function test_flushWindow_thirdPartyGapSliceAfterGracePasses()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );

        _flushOwnLocal(
            refA
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            3_400 weeks + 1 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            3_442 weeks + 1 days - 3 hours + 1 seconds
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_400,
            1
        );
    }

    function test_flushReferrals_botFlushAtExactGraceBoundaryPasses()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 36 hours
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 48 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushWindow_rearmLaterThanUnpause_extendsGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 12 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 18 hours
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 36 hours + 1 seconds
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    /**
     * @dev a second, short pause of the SAME class must not collapse
     * the grace the long first span earned: the refusal instant
     * sits past the SHORT span own deadline (one grace day plus
     * six hours past its reopen) but inside the LONG span
     * deadline (one grace day plus two weeks)
     * past the LONG span grace plus the short span, the window
     * passes: the tail word kept the longer deadline
     */
    function test_RevertWhen_flushWindow_shortPauseAfterLongPause_holdsLongGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(
            diamond
        ).unpauseDeposits();

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks + 6 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 3 weeks
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks + 1 days + 1 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    function test_RevertWhen_flushWindow_shortDisarmAfterLongDisarm_holdsLongGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 6 hours
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks + 1 days + 1 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    /**
     * @dev the crumbs and the gap tail share the work budget with a
     * fixed slice held for the gap lane, so a crumb-heavy entry
     * ships a gap slice in the same envelope instead of
     * stranding the tail behind its own cursor
     */
    function test_flush_gapReservation_carriesGapTailInSameEnvelope()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        (
            uint256 gapIndexBefore,
            uint256 gapResumeBefore
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        _flushOwnLocal(
            refA
        );

        assertGt(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_027
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        bool gapAdvanced = gapIndex > gapIndexBefore
            || (
                gapIndex == gapIndexBefore
                    && gapResumeWeek > gapResumeBefore
            );

        assertTrue(
            gapAdvanced,
            "the gap lane shipped nothing beside the crumbs"
        );
    }

    function test_RevertWhen_flushWindow_twoWeekPause_strandedWeeksStayGatedPastFlatDay()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks + 1 days + 1 hours
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks + 1 days + 1 seconds
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    function test_RevertWhen_flushWindow_courierAtLogLengthDuringGrace_settleAppendedRecord()
        public
    {        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        assertEq(
            _rec(diamond).getCohortGapLogLength(
                refA
            ),
            0
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            3_358 weeks + 6 hours
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            0
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            0
        );
    }

    function test_RevertWhen_flushWindow_shortDisarmAfterLongPause_holdsBothGraces()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(
            diamond
        ).unpauseDeposits();

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 1 hours
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 4 weeks + 1 days + 1 seconds
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    function test_flushWindow_preUpgradePauseStamp_backfillsToOneDayGrace()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(
            diamond
        ).pauseDeposits();

        bytes32 slot93 = vm.load(
            address(diamond),
            bytes32(
                uint256(
                    93
                )
            )
        );

        vm.store(
            address(diamond),
            bytes32(
                uint256(
                    93
                )
            ),
            bytes32(
                uint256(slot93)
                    & ~(type(uint64).max << 192)
            )
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 2 weeks + 12 hours
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 2 weeks + 1 days + 1 seconds
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    function test_RevertWhen_flushWindow_equalSecondRearmAndUnpause_holdsDisarmSpan()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME - 8 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        _admin(
            diamond
        ).pauseDeposits();

        _admin(
            diamond
        ).unpauseDeposits();

        vm.warp(
            BASE_TIME + 1 weeks + 2 days
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );

        vm.warp(
            BASE_TIME + 2 weeks + 1 days + 1 seconds
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            2_999,
            0
        );
    }

    // ---- settle entrypoint guards ----

    function test_RevertWhen_applyCohortSettle_directFacetCall()
        public
    {
        CohortHookFacet facet = new CohortHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyCohortSettle(
            refA
        );
    }

    function test_applyCohortSettle_unroutedThenRoutedStaysGuarded()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                CohortHookFacet.applyCohortSettle.selector,
                refA
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );

        diamond.proposeSelector(
            CohortHookFacet.applyCohortSettle.selector,
            address(new CohortHookFacet())
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        diamond.executeSelectorChange(
            CohortHookFacet.applyCohortSettle.selector
        );

        (
            ok,
            ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                CohortHookFacet.applyCohortSettle.selector,
                refA
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );
    }

    // ---- local delivery end-to-end ----

    function test_localFlush_endToEnd_exactPricingAndCursors()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            12_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            3_000
        );

        assertEq(
            referredInput,
            0
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        (
            referredInput,
            selfInput
        ) = hub.ladderInputsAt(
            refA,
            3_001
        );

        assertEq(
            referredInput,
            10_000 * 1e6
        );

        assertEq(
            selfInput,
            _rec(diamond).getTrackedContribution(
                refA
            )
        );

        assertEq(
            _rec(diamond).getTrackedContribution(
                refA
            ),
            12_000 * 1e6
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks + 12 hours
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerFlushed(
            refA,
            3_003,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            refA,
            1
        );

        _flushOwnLocal(
            refA
        );

        uint256 expected = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_003
        );

        assertGt(
            expected,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );

        (
            uint256 y1Cursor,
            ,

        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_003
        );

        assertEq(
            y1Cursor,
            10_000 * 1e6 * CohortWeeks.WEEK
        );

        (
            uint256 openWeekCursor,
            ,
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_004
        );

        assertEq(
            openWeekCursor,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_003
        );
    }

    function test_flushReferrals_duplicateReferrer_pricesEachWeekOnce()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            12_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks + 12 hours
        );

        address[] memory refs = new address[](2);

        refs[0] = refA;

        refs[1] = refA;

        _advanceBooks(
            diamond,
            refs
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferrals(
            refs
        );

        uint256 expected = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_004
        );

        assertGt(
            expected,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_003
        );
    }

    function test_localFlush_sameWeekReflush_paysNothingUntilTheWeekCloses()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks + 12 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableBase = hub.claimable(
            block.chainid,
            refA
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBase
        );

        vm.warp(
            block.timestamp + 5 hours
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBase
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 closedWeekPrice = _weekPriceOracle(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_004
            ),
            0
        );

        assertGt(
            closedWeekPrice,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBase + closedWeekPrice
        );
    }

    /**
     * @dev the pre-plan settle parks the book at the disarm instant, so
     * the cursor stays below the disarm week instead of jumping over
     * the weeks the parked book has not written yet
     * one week past the re-arm the park ends, so the flush itself
     * settles the intact but quiet book through the span: the span
     * weeks stay unwritten and the week after the re-arm carries the
     * book's presence from the re-arm instant, shipped and priced
     */
    function test_RevertWhen_flush_disarmedRecorder()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableArmed = hub.claimable(
            block.chainid,
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        uint256 crumbAtDisarm = _rec(diamond).getCohortWeekCrumb(
            refA,
            3_003
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_003
            ),
            crumbAtDisarm
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_004
            ),
            0
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_005
            ),
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );

        vm.warp(
            BASE_TIME + 7 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_006
        );

        assertEq(
            CohortWeeks._laneY1(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    3_006
                )
            ),
            10_000 * 1e6 * (1 weeks - 1 hours)
        );

        assertEq(
            _paidLanes(
                refA,
                3_006
            ),
            10_000 * 1e6 * (1 weeks - 1 hours)
        );

        _depositWithReferralOn(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_005
            ),
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    3_006
                )
            ),
            10_000 * 1e6 * (1 weeks - 1 hours)
        );
    }

    function test_localFlush_neverCreditedReferrer_reportsNothingPinsCursor()
        public
    {
        address virgin = address(0xE1);

        address[] memory refs = _oneRef(
            virgin
        );

        vm.recordLogs();

        vm.prank(
            virgin
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _countReferrerFlushedLogs(),
            1
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                virgin
            ),
            2_999
        );

        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            virgin,
            2_999
        );

        assertEq(
            referredInput,
            0
        );

        assertEq(
            selfInput,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                virgin
            ),
            0
        );

        vm.recordLogs();

        vm.prank(
            virgin
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                virgin
            ),
            2_999
        );
    }

    function test_previewFlushEnvelope_unsettledSelfWeeks_matchesTheSentEnvelope()
        public
    {
        _depositOn(
            rdiamond,
            refD,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        bytes memory preview = _flush(rdiamond).previewFlushEnvelope(
            _oneRef(
                refD
            )
        );

        _flushOwnRemote(
            refD
        );

        assertEq(
            keccak256(
                preview
            ),
            keccak256(
                router.lastData()
            )
        );
    }

    function test_previewFlushEnvelope_zeroRegistryDiamond_noDesignationWord()
        public
    {
        WiseSovrenNodesDiamond bare = _newBareFlushDiamond(
            REMOTE_SELECTOR
        );

        bytes memory preview = _flush(bare).previewFlushEnvelope(
            _oneRef(
                refA
            )
        );

        assertEq(
            preview.length,
            2 * 32
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    preview,
                    1
                )
            ),
            0
        );
    }

    function test_RevertWhen_flush_neverArmedDiamond()
        public
    {
        WiseSovrenNodesDiamond bare = _newBareFlushDiamond(
            0
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );

        _flush(bare).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortSyncDisabled.selector
        );

        _flush(bare).flushReferralWindow(
            refA,
            3_000,
            0
        );
    }

    function test_RevertWhen_flush_armedWithZeroTransferHook()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableArmed = hub.claimable(
            block.chainid,
            refA
        );

        address hook = diamond.transferHookFacet();

        vm.store(
            address(diamond),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(0)
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortHookNotInstalled.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortHookNotInstalled.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );

        vm.store(
            address(diamond),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(uint256(uint160(hook)))
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_004
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );
    }

    function test_RevertWhen_flushReferrals_armedWithZeroRegistryPointer()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableArmed = hub.claimable(
            block.chainid,
            refA
        );

        vm.store(
            address(diamond),
            bytes32(REGISTRY_SLOT),
            bytes32(0)
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );

        _admin(diamond).proposeReferralRegistry(
            address(localRegistry)
        );

        vm.warp(
            BASE_TIME + 5 weeks + REGISTRY_DELAY
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        _admin(
            diamond
        ).executeReferralRegistryChange();

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_004
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );
    }

    function test_RevertWhen_flushReferralWindow_armedWithZeroRegistryPointer()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableArmed = hub.claimable(
            block.chainid,
            refA
        );

        vm.store(
            address(diamond),
            bytes32(REGISTRY_SLOT),
            bytes32(0)
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_003,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );

        _admin(diamond).proposeReferralRegistry(
            address(localRegistry)
        );

        vm.warp(
            BASE_TIME + 5 weeks + REGISTRY_DELAY
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        _admin(
            diamond
        ).executeReferralRegistryChange();

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_004,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_004
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableArmed
        );
    }

    function test_quoteAndPreview_ungatedWhileArmingIncomplete()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.prank(
            refA
        );

        remoteRegistry.setPayoutAddress(
            address(0xF2)
        );

        address[] memory refs = _oneRef(
            refA
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    _flush(rdiamond).previewFlushEnvelope(
                        refs
                    ),
                    1
                )
            ),
            CohortFlushCodec.FLUSH_FLAG_DESIGNATION
        );

        vm.store(
            address(rdiamond),
            bytes32(REGISTRY_SLOT),
            bytes32(0)
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                refs
            ),
            FIXED_FEE
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    _flush(rdiamond).previewFlushEnvelope(
                        refs
                    ),
                    1
                )
            ),
            0
        );

        vm.store(
            address(rdiamond),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(0)
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                refs
            ),
            FIXED_FEE
        );

        _admin(rdiamond).setCohortSyncEnabled(
            false
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                refs
            ),
            FIXED_FEE
        );

        assertGt(
            _flush(rdiamond).previewFlushEnvelope(
                refs
            ).length,
            0
        );
    }

    function test_previewFlushEnvelope_localMode_skipsDesignationRead()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.prank(
            refA
        );

        localRegistry.setPayoutAddress(
            address(0xF2)
        );

        bytes memory preview = _flush(diamond).previewFlushEnvelope(
            _oneRef(
                refA
            )
        );

        assertEq(
            preview.length,
            2 * 32
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    preview,
                    1
                )
            ),
            0
        );
    }

    function test_localFlush_designationNeverDelivered()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.prank(
            refA
        );

        localRegistry.setPayoutAddress(
            address(0xF2)
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            refA
        );

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            0
        );
    }

    function test_localFlush_windowReflush_idempotentKeepsCursorMax()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        assertGt(
            claimableBefore,
            0
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBefore
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_003
        );
    }

    function test_RevertWhen_flushWindow_futureFromWeek()
        public
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            currentWeek + 1,
            0
        );
    }

    function test_RevertWhen_flushWindow_gapIndexBeyondLog()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            1
        );
    }

    function test_flushWindow_virginReferrer_scoresOnly()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferralWindow(
            stranger,
            3_000,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                stranger
            ),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                stranger
            ),
            2_999
        );
    }

    function test_flushWindow_allowedBot_leavesCursorsUntouched()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _seedOwnFlushedBook();

        _assertThirdPartyWindowLeavesCursors(
            bot
        );
    }

    function test_flushWindow_publicFlush_leavesCursorsUntouched()
        public
    {
        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        _seedOwnFlushedBook();

        _assertThirdPartyWindowLeavesCursors(
            stranger
        );
    }

    function _seedOwnFlushedBook()
        internal
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function _assertThirdPartyWindowLeavesCursors(
        address _caller
    )
        internal
    {
        vm.warp(
            BASE_TIME + 6 weeks
        );

        (
            uint256 gapIndexBefore,
            uint256 gapResumeBefore
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        vm.recordLogs();

        vm.prank(
            _caller
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_005,
            0
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        (
            uint256 gapIndexAfter,
            uint256 gapResumeAfter
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndexAfter,
            gapIndexBefore
        );

        assertEq(
            gapResumeAfter,
            gapResumeBefore
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBefore
        );
    }

    /**
     * @dev the own window jumped the cursor past the early crumbs:
     * they stay deliverable by the referrer own window only, and
     * that window still carries them at their frozen rates
     */
    function test_flushWindow_ownSkipAhead_leavesOlderWeeksToOwnBatch()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            10_000 * 1e6
        );

        _rec(diamond).syncReferee(
            user1
        );

        assertEq(
            _rec(
                diamond
            ).getCohortScore(
                refA
            ),
            0
        );

        for (uint256 week = 3_001; week <= 3_003; ++week) {

            assertGt(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    week
                ),
                0
            );
        }

        vm.warp(
            BASE_TIME + 29 weeks
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerFlushed(
            refA,
            3_028,
            0,
            0
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_029,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_028
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_001,
            0
        );

        for (uint256 week = 3_001; week <= 3_003; ++week) {

            (
                uint256 y1Cursor,
                ,

            ) = reader.paidCursorAt(
                address(diamond),
                refA,
                week
            );

            assertEq(
                y1Cursor,
                CohortWeeks._laneY1(
                    _rec(diamond).getCohortWeekCrumb(
                        refA,
                        week
                    )
                )
            );
        }
    }

    function test_flushWindow_thirdPartyOverDormantBook_leavesGapCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_027
        );

        (
            uint256 gapIndexBefore,
            uint256 gapResumeBefore
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndexBefore,
            0
        );

        assertEq(
            gapResumeBefore,
            3_248
        );

        vm.recordLogs();

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            1
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_027
        );

        (
            uint256 gapIndexAfter,
            uint256 gapResumeAfter
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndexAfter,
            0
        );

        assertEq(
            gapResumeAfter,
            3_248
        );
    }

    function test_RevertWhen_flushWindow_allowedBotStartsAtOrBelowCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _seedOwnFlushedBook();

        _assertThirdPartyWindowBelowCursorReverts(
            bot
        );
    }

    function test_RevertWhen_flushWindow_publicFlushStartsAtOrBelowCursor()
        public
    {
        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        _seedOwnFlushedBook();

        _assertThirdPartyWindowBelowCursorReverts(
            stranger
        );
    }

    function _assertThirdPartyWindowBelowCursorReverts(
        address _caller
    )
        internal
    {
        vm.warp(
            BASE_TIME + 4 weeks
        );

        vm.prank(
            _caller
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_001,
            0
        );

        vm.prank(
            _caller
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );
    }

    function test_RevertWhen_flushWindow_thirdPartyGapIndexBehindCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        for (uint256 i; i < 8; ++i) {

            _flushOwnLocal(
                refA
            );

            vm.warp(
                block.timestamp + 1 hours
            );

            (
                uint256 walkedIndex,
            ) = _flushPolicy(diamond).getFlushGapCursor(
                refA
            );

            if (walkedIndex == 1) {
                break;
            }
        }

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            1
        );

        assertEq(
            gapResumeWeek,
            0
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            block.timestamp / 1 weeks,
            0
        );
    }

    function test_flushWindow_thirdPartyGapIndexAtCursorMidRecord_resumesWithoutWrite()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_248
        );

        uint256 mature = CohortWeeks._gapRecordMature(
            _rec(diamond).getCohortGapLogEntry(
                refA,
                0
            )
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        vm.recordLogs();

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            0
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        (
            gapIndex,
            gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_248
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_027
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBefore
        );

        (
            ,
            ,
            uint256 mCursorResumed
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_270
        );

        assertEq(
            mCursorResumed,
            mature * CohortWeeks.WEEK
        );

        (
            ,
            ,
            uint256 mCursorUntouched
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_360
        );

        assertEq(
            mCursorUntouched,
            0
        );
    }

    function test_flushWindow_thirdPartyGapIndexPastTheLog_shipsNoOpenWeekNorCursor()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        vm.recordLogs();

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            1
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_288
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_055
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableBefore
        );

        (
            uint256 y1Open,
            ,
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_358
        );

        assertEq(
            y1Open,
            0
        );
    }

    function test_flushWindow_ownGapIndexBehindCursor_allowed()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_358,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_357
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_344
        );
    }

    /**
     * @dev the referrer own window writes the cursors and carries the
     * weeks its own batch lookback had missed, up to the work budget
     * the carried weeks price at their frozen openings (the
     * pre-history zeros here), and the paid cursors prove the
     * delivery happened
     */
    function test_flushWindow_ownWindowReachesOlderWeeks_thenBotCarriesLapsedTail()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 110 weeks
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_055
        );

        (
            uint256 storedGapIndex,
            uint256 storedGapResume
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_055
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_110,
            storedGapResume == 0 ? storedGapIndex : storedGapIndex + 1
        );

        (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        ) = reader.paidCursorAt(
            address(diamond),
            refA,
            3_108
        );

        assertGt(
            y1Cursor + y2Cursor + mCursor,
            0
        );

    }

    function test_flushWindow_thirdPartyShipsGapSlice_leavesCursors()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _buildDormantMatureBook();

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            2_999
        );

        vm.recordLogs();

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_007,
            0
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            2_999
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            0
        );

        uint256 mature = CohortWeeks._gapRecordMature(
            _rec(diamond).getCohortGapLogEntry(
                refA,
                0
            )
        );

        uint256 expected = _expectedCrumbRangePay(
            diamond,
            refA,
            3_007,
            3_103
        ) + _expectedGapRangePay(
            mature,
            refA,
            3_208,
            3_271
        );

        assertGt(
            expected,
            0
        );

        uint256 botShare = hub.claimable(
            block.chainid,
            bot
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );

        assertApproxEqAbs(
            botShare,
            expected * 500 / 10_000,
            (3_103 - 3_007 + 1) + (3_271 - 3_208 + 1)
        );

        assertGt(
            botShare,
            0
        );
    }

    function test_localFlush_earlyChain_virginCursorClampsToWeekZero()
        public
    {
        vm.warp(
            50 weeks + 1 hours
        );

        address[] memory refs = _oneRef(
            stranger
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerFlushed(
            stranger,
            49,
            0,
            0
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                stranger
            ),
            49
        );
    }

    function test_RevertWhen_localFlush_refundRejected()
        public
    {
        FlushRefundRejector rejector = new FlushRefundRejector();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushRefundFailed.selector
        );

        rejector.run{value: 0.1 ether}(
            address(diamond)
        );
    }

    // ---- gap machinery + cursor catch-up (local) ----

    function _buildDormantMatureBook()
        internal
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        _reportCompletedWeekByBotWindow(
            refA
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );
    }

    function _reportCompletedWeekByBotWindow(
        address _referrer
    )
        internal
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.warp(
            3_010 weeks + 1 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            _referrer,
            3_008,
            0
        );

        vm.warp(
            3_011 weeks + 1 hours
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferralWindow(
            _referrer,
            3_008,
            0
        );
    }

    function test_localFlush_gapMachinery_slicesCursorsAndExactPay()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        assertEq(
            _rec(diamond).getCohortGapLogLength(
                refA
            ),
            1
        );

        uint256 record = _rec(diamond).getCohortGapLogEntry(
            refA,
            0
        );

        assertEq(
            CohortWeeks._gapRecordFromWeek(
                record
            ),
            3_208
        );

        assertEq(
            CohortWeeks._gapRecordToWeek(
                record
            ),
            3_358
        );

        uint256 mature = CohortWeeks._gapRecordMature(
            record
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_027
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_248
        );

        uint256 expectedStage1 = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_027
        ) + _expectedGapRangePay(
            mature,
            refA,
            3_208,
            3_248
        );

        assertGt(
            expectedStage1,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedStage1
        );

        _continueGapWalkAndAssertFinal(
            mature
        );
    }

    function _continueGapWalkAndAssertFinal(
        uint256 _mature
    )
        internal
    {
        uint256[3] memory throughWeeks = [
            uint256(3_055),
            3_083,
            3_111
        ];

        uint256[3] memory resumeWeeks = [
            uint256(3_288),
            3_328,
            0
        ];

        for (uint256 i; i < 3; ++i) {

            vm.warp(
                block.timestamp + 1 hours
            );

            _flushOwnLocal(
                refA
            );

            (
                uint256 gapIndex,
                uint256 gapResumeWeek
            ) = _flushPolicy(diamond).getFlushGapCursor(
                refA
            );

            assertEq(
                _flushPolicy(
                    diamond
                ).getFlushedThroughWeek(
                    refA
                ),
                throughWeeks[i]
            );

            assertEq(
                gapIndex,
                i == 2 ? 1 : 0
            );

            assertEq(
                gapResumeWeek,
                resumeWeeks[i]
            );
        }

        for (uint256 i; i < 6; ++i) {

            vm.warp(
                block.timestamp + 1 hours
            );

            _flushOwnLocal(
                refA
            );
        }

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_357
        );

        uint256 expectedFinal = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_207
        ) + _expectedGapRangePay(
            _mature,
            refA,
            3_208,
            3_358
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedFinal
        );
    }

    function test_localFlush_gapCursor_staleResumeSkipsExhaustedSlice()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        uint256 record = _rec(diamond).getCohortGapLogEntry(
            refA,
            0
        );

        uint256 mature = CohortWeeks._gapRecordMature(
            record
        );

        vm.store(
            address(diamond),
            keccak256(
                abi.encode(
                    refA,
                    uint256(87)
                )
            ),
            bytes32(
                uint256(3_358) << 128
            )
        );

        (
            uint256 staleIndex,
            uint256 staleResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            staleIndex,
            0
        );

        assertEq(
            staleResumeWeek,
            3_358
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flushPolicy(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            1
        );

        assertEq(
            gapResumeWeek,
            0
        );

        uint256 expectedAfterSkip = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_139
        ) + _expectedGapRangePay(
            mature,
            refA,
            3_208,
            3_248
        );

        assertGt(
            expectedAfterSkip,
            0
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedAfterSkip
        );
    }

    // ---- remote delivery (mock router) ----

    function test_remoteFlush_envelopeExactContent()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        bytes32 expectedId = keccak256(
            abi.encode(
                address(rdiamond),
                REMOTE_SELECTOR,
                uint256(0)
            )
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(rdiamond)
        );

        emit CohortFlushSent(
            expectedId,
            REMOTE_SELECTOR,
            refD,
            1
        );

        _flushOwnRemote(
            refD
        );

        assertEq(
            router.sendCount(),
            1
        );

        assertEq(
            router.lastSelector(),
            REMOTE_SELECTOR
        );

        assertEq(
            router.lastReceiver(),
            abi.encode(
                address(hub)
            )
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            6 * 32
        );

        assertEq(
            _envWord(
                data,
                0
            ),
            CohortFlushCodec._packFlushHeader(
                address(0),
                1,
                block.timestamp
            )
        );

        assertEq(
            _envWord(
                data,
                1
            ),
            CohortFlushCodec._packFlushEntry(
                refD,
                2,
                0,
                0,
                0
            )
        );

        for (uint256 i; i < 2; ++i) {

            assertEq(
                _envWord(
                    data,
                    2 + 2 * i
                ),
                3_000 + i
            );

            assertEq(
                _envWord(
                    data,
                    3 + 2 * i
                ),
                _rec(rdiamond).getCohortWeekCrumb(
                    refD,
                    3_000 + i
                )
            );
        }

        assertEq(
            _flushPolicy(rdiamond).getFlushedThroughWeek(
                refD
            ),
            3_001
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refD
            ),
            0
        );
    }

    function test_remoteFlush_quoteAndFees()
        public
    {
        address[] memory refs = _oneRef(
            refD
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                refs
            ),
            FIXED_FEE
        );

        assertEq(
            _flush(diamond).quoteFlushFee(
                refs
            ),
            0
        );

        vm.deal(
            refD,
            1 ether
        );

        vm.prank(
            refD
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE - 1}(
            refs
        );

        vm.prank(
            refD
        );

        _flush(rdiamond).flushReferrals{value: 0.5 ether}(
            refs
        );

        assertEq(
            refD.balance,
            1 ether - FIXED_FEE
        );
    }

    function test_RevertWhen_remoteFlush_routerUnset()
        public
    {
        (
            WiseSovrenNodesDiamond unrouted,
        ) = _buildFlushDiamond(
            REMOTE_SELECTOR,
            false
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.RouterNotSet.selector
        );

        _flush(unrouted).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.RouterNotSet.selector
        );

        _flush(unrouted).quoteFlushFee(
            refs
        );
    }

    function test_remoteFlush_gasLimitExtraArgs()
        public
    {
        _flushOwnRemote(
            refD
        );

        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 300_000,
                    allowOutOfOrderExecution: true
                })
            )
        );

        _flushPolicy(rdiamond).setFlushGasLimit(
            1_500_000
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnRemote(
            refD
        );

        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 1_500_000,
                    allowOutOfOrderExecution: true
                })
            )
        );
    }

    function test_remoteFlush_designationPiggyback()
        public
    {
        uint256 setAt = block.timestamp;

        vm.prank(
            refE
        );

        remoteRegistry.setPayoutAddress(
            address(0xF2)
        );

        _flushOwnRemote(
            refE
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            3 * 32
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    data,
                    1
                )
            ),
            CohortFlushCodec.FLUSH_FLAG_DESIGNATION
        );

        assertEq(
            _envWord(
                data,
                2
            ),
            CohortFlushCodec._packFlushDesignation(
                address(0xF2),
                setAt,
                0
            )
        );

        _flushOwnRemote(
            refD
        );

        data = router.lastData();

        assertEq(
            data.length,
            2 * 32
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    data,
                    1
                )
            ),
            0
        );
    }

    function test_remoteFlush_rankTwoDesignation_landsOnHubEndToEnd()
        public
    {
        ReferralRegistry rankTwoRegistry = new ReferralRegistry(
            address(this),
            2
        );

        rankTwoRegistry.setAllowedVault(
            address(rdiamond),
            true
        );

        _admin(rdiamond).proposeReferralRegistry(
            address(rankTwoRegistry)
        );

        vm.warp(
            BASE_TIME + REGISTRY_DELAY
        );

        _admin(rdiamond).setCohortSyncEnabled(
            false
        );

        _admin(
            rdiamond
        ).executeReferralRegistryChange();

        _admin(rdiamond).setCohortSyncEnabled(
            true
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    address(this)
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    REMOTE_SELECTOR,
                    address(rdiamond),
                    8_453
                )
            )
        );

        uint256 setAt = block.timestamp;

        vm.prank(
            refE
        );

        rankTwoRegistry.setPayoutAddress(
            address(0xF2)
        );

        _flushOwnRemote(
            refE
        );

        bytes memory data = router.lastData();

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    data,
                    1
                )
            ),
            CohortFlushCodec.FLUSH_FLAG_DESIGNATION
        );

        assertEq(
            _envWord(
                data,
                2
            ),
            CohortFlushCodec._packFlushDesignation(
                address(0xF2),
                setAt,
                2
            )
        );

        _applyVaultBuilt(
            bytes32(uint256(0xA8)),
            8_453,
            data
        );

        assertEq(
            hub.payoutStamp(
                8_453,
                refE
            ),
            (setAt << 8) | 2
        );

        assertEq(
            hub.payoutAddressOf(
                8_453,
                refE
            ),
            address(0xF2)
        );
    }

    function test_remoteFlush_hostileRegistry_degradesSilently()
        public
    {
        vm.prank(
            refE
        );

        remoteRegistry.setPayoutAddress(
            address(0xF2)
        );

        vm.etch(
            address(remoteRegistry),
            address(new RevertingDesignationMock()).code
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            hex"00"
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            address(new WideAddressDesignationMock()).code
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            address(new HugeStampDesignationMock()).code
        );

        _assertDesignationSkipped();
    }

    function _assertDesignationSkipped()
        internal
    {
        _flushOwnRemote(
            refE
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            2 * 32
        );

        assertEq(
            CohortFlushCodec._flushEntryFlags(
                _envWord(
                    data,
                    1
                )
            ),
            0
        );
    }

    function test_remoteFlush_catchUp_startsAtWindowEdge()
        public
    {
        vm.warp(
            3_254 weeks + 1 hours
        );

        _depositWithReferralOn(
            rdiamond,
            user2,
            5_000 * 1e6,
            refE
        );

        vm.warp(
            3_358 weeks + 3 hours
        );

        _flushOwnRemote(
            refE
        );

        assertEq(
            _rec(rdiamond).getCohortGapLogLength(
                refE
            ),
            0
        );

        bytes memory data = router.lastData();

        uint256 entryWord = _envWord(
            data,
            1
        );

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                entryWord
            ),
            103
        );

        assertEq(
            _envWord(
                data,
                2
            ),
            3_255
        );

        assertGt(
            _rec(rdiamond).getCohortWeekCrumb(
                refE,
                3_254
            ),
            0
        );

        assertEq(
            _flushPolicy(rdiamond).getFlushedThroughWeek(
                refE
            ),
            3_357
        );

        vm.warp(
            block.timestamp + 2 hours
        );

        _flushOwnRemote(
            refE
        );

        data = router.lastData();

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                _envWord(
                    data,
                    1
                )
            ),
            0
        );
    }

    /**
     * @dev the abandoned entry consumes the shared work budget with
     * its crumbs and its dormant gap slices, so the second entry
     * carries no crumbs or gaps until the next flush
     * the bot never writes the abandoned book send cursors
     */
    function test_remoteFlush_workBudget_abandonedEntryLeavesOwnEntryWithoutCrumbs()
        public
    {
        _flushPolicy(rdiamond).setAllowedFlushBot(
            address(this),
            true
        );

        _depositWithReferralOn(
            rdiamond,
            user3,
            10_000 * 1e6,
            bigR
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnRemote(
            bigR
        );

        _depositWithReferralOn(
            rdiamond,
            user2,
            5_000 * 1e6,
            address(this)
        );

        vm.warp(
            3_358 weeks + 5 hours
        );

        _flushOwnRemote(
            bigR
        );

        address[] memory pair = new address[](2);

        pair[0] = bigR;
        pair[1] = address(this);

        _advanceBooks(
            rdiamond,
            pair
        );

        _flushBotRemote(
            pair
        );

        bytes memory data = router.lastData();

        assertEq(
            CohortFlushCodec._flushHeaderEntryCount(
                _envWord(
                    data,
                    0
                )
            ),
            2
        );

        uint256 firstWord = _envWord(
            data,
            1
        );

        assertEq(
            CohortFlushCodec._flushEntryReferrer(
                firstWord
            ),
            bigR
        );

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                firstWord
            ),
            0
        );

        assertGt(
            CohortFlushCodec._flushEntryGapCount(
                firstWord
            ),
            0
        );

        uint256 secondOffset = 2
            + CohortFlushCodec._flushEntrySelfRunCount(firstWord)
            + CohortFlushCodec._flushEntryCrumbCount(firstWord) * 2
            + CohortFlushCodec._flushEntryGapCount(firstWord)
            + (CohortFlushCodec._flushEntryFlags(firstWord) != 0 ? 1 : 0);

        uint256 secondWord = _envWord(
            data,
            secondOffset
        );

        assertEq(
            CohortFlushCodec._flushEntryReferrer(
                secondWord
            ),
            address(this)
        );

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                secondWord
            ),
            0
        );

        assertEq(
            CohortFlushCodec._flushEntryGapCount(
                secondWord
            ),
            0
        );

        assertEq(
            _flushPolicy(rdiamond).getFlushedThroughWeek(
                bigR
            ),
            3_104
        );
    }

    // ---- window CCIP delivery ----

    function test_remoteFlushWindow_chargesFeeAndRefundsExcess()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        _flushOwnRemote(
            refD
        );

        vm.deal(
            refD,
            1 ether
        );

        vm.prank(
            refD
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(rdiamond).flushReferralWindow{value: FIXED_FEE - 1}(
            refD,
            3_000,
            0
        );

        bytes32 expectedId = keccak256(
            abi.encode(
                address(rdiamond),
                REMOTE_SELECTOR,
                uint256(1)
            )
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(rdiamond)
        );

        emit CohortFlushSent(
            expectedId,
            REMOTE_SELECTOR,
            refD,
            1
        );

        vm.prank(
            refD
        );

        _flush(rdiamond).flushReferralWindow{value: 0.5 ether}(
            refD,
            3_000,
            0
        );

        assertEq(
            refD.balance,
            1 ether - FIXED_FEE
        );

        assertEq(
            router.sendCount(),
            2
        );
    }

    function test_remoteFlushWindow_envelopeRestrictedToWindowSlice()
        public
    {
        _flushPolicy(rdiamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        _flushOwnRemote(
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        vm.deal(
            bot,
            FIXED_FEE
        );

        vm.prank(
            bot
        );

        _flush(rdiamond).flushReferralWindow{value: FIXED_FEE}(
            refD,
            3_001,
            0
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            4 * 32
        );

        assertEq(
            _envWord(
                data,
                0
            ),
            CohortFlushCodec._packFlushHeader(
                bot,
                1,
                block.timestamp
            )
        );

        assertEq(
            _envWord(
                data,
                1
            ),
            CohortFlushCodec._packFlushEntry(
                refD,
                1,
                0,
                0,
                0
            )
        );

        assertGt(
            _rec(rdiamond).getCohortWeekCrumb(
                refD,
                3_000
            ),
            0
        );

        for (uint256 i; i < 1; ++i) {

            assertEq(
                _envWord(
                    data,
                    2 + 2 * i
                ),
                3_001 + i
            );

            assertEq(
                _envWord(
                    data,
                    3 + 2 * i
                ),
                _rec(rdiamond).getCohortWeekCrumb(
                    refD,
                    3_001 + i
                )
            );
        }
    }

    function test_RevertWhen_flushWindow_strangerFlushesForeignBook()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );
    }

    function test_RevertWhen_flushReferrals_mixedBatchOwnThenForeign()
        public
    {
        address[] memory pair = new address[](2);

        pair[0] = stranger;
        pair[1] = refA;

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferrals(
            pair
        );
    }

    // ---- quote lower bound (size-dependent fee) ----

    function test_quoteFlushFee_lowerBound_depositBetweenQuoteAndFlush()
        public
    {
        (
            WiseSovrenNodesDiamond sdiamond,
            SizeFeeCcipRouter sizeRouter
        ) = _buildSizeFeeDiamond();

        _depositWithReferralOn(
            sdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        uint256 quoted = _flush(sdiamond).quoteFlushFee(
            refs
        );

        assertEq(
            quoted,
            sizeRouter.BASE_FEE() + 2 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        _depositWithReferralOn(
            sdiamond,
            user2,
            5_000 * 1e6,
            refA
        );

        vm.deal(
            refA,
            1 ether
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(sdiamond).flushReferrals{value: quoted}(
            refs
        );

        vm.prank(
            refA
        );

        _flush(sdiamond).flushReferrals{value: 0.5 ether}(
            refs
        );

        assertEq(
            sizeRouter.lastFee(),
            sizeRouter.BASE_FEE() + 6 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        assertEq(
            refA.balance,
            1 ether - sizeRouter.lastFee()
        );
    }

    function test_flushWindow_subsetCostsNoMoreThanCursorQuote()
        public
    {
        (
            WiseSovrenNodesDiamond sdiamond,
            SizeFeeCcipRouter sizeRouter
        ) = _buildSizeFeeDiamond();

        _depositWithReferralOn(
            sdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        _depositWithReferralOn(
            sdiamond,
            user2,
            5_000 * 1e6,
            refA
        );

        uint256 quoted = _flush(sdiamond).quoteFlushFee(
            _oneRef(
                refA
            )
        );

        vm.deal(
            refA,
            quoted
        );

        vm.prank(
            refA
        );

        _flush(sdiamond).flushReferralWindow{value: quoted}(
            refA,
            3_001,
            0
        );

        uint256 windowFee = sizeRouter.lastFee();

        assertEq(
            windowFee,
            sizeRouter.BASE_FEE() + 4 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        assertLt(
            windowFee,
            quoted
        );

        assertEq(
            refA.balance,
            quoted - windowFee
        );
    }

    function test_quoteFlushFee_disarmedRecorder_stillQuotes()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        _admin(rdiamond).setCohortSyncEnabled(
            false
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                _oneRef(
                    refD
                )
            ),
            FIXED_FEE
        );
    }

    // ---- preview ----

    function test_previewFlushEnvelope_matchesSentEnvelope_ccipMode()
        public
    {
        _flushPolicy(rdiamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        _depositWithReferralOn(
            rdiamond,
            user2,
            2_000 * 1e6,
            refD
        );

        _flushOwnRemote(
            refD
        );

        address[] memory refs = _oneRef(
            refD
        );

        vm.prank(
            bot
        );

        bytes memory preview = _flush(rdiamond).previewFlushEnvelope(
            refs
        );

        assertGt(
            preview.length,
            32
        );

        vm.deal(
            bot,
            FIXED_FEE
        );

        vm.prank(
            bot
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            refs
        );

        bytes memory sent = router.lastData();

        assertEq(
            keccak256(
                preview
            ),
            keccak256(
                sent
            )
        );
    }

    function test_previewFlushEnvelope_localMode_carriesEntries()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositWithReferralOn(
            diamond,
            user2,
            5_000 * 1e6,
            refD
        );

        _flushOwnLocal(
            refA
        );

        _flushOwnLocal(
            refD
        );

        address[] memory refs = new address[](2);

        refs[0] = refA;
        refs[1] = refD;

        vm.prank(
            bot
        );

        bytes memory preview = _flush(diamond).previewFlushEnvelope(
            refs
        );

        assertGt(
            preview.length,
            0
        );

        uint256 header = _envWord(
            preview,
            0
        );

        assertEq(
            CohortFlushCodec._flushHeaderEntryCount(
                header
            ),
            refs.length
        );

        assertEq(
            CohortFlushCodec._flushHeaderDeliverer(
                header
            ),
            bot
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            bot,
            2
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_previewFlushEnvelope_isLowerBound_beforeSettle()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        bytes memory preview = _flush(rdiamond).previewFlushEnvelope(
            refs
        );

        assertEq(
            preview.length,
            2 * 32
        );

        assertEq(
            CohortFlushCodec._flushHeaderStamp(
                _envWord(
                    preview,
                    0
                )
            ),
            block.timestamp
        );

        _depositWithReferralOn(
            rdiamond,
            user2,
            5_000 * 1e6,
            refA
        );

        _flushOwnRemote(
            refA
        );

        bytes memory sent = router.lastData();

        assertLe(
            preview.length,
            sent.length
        );

        assertEq(
            sent.length,
            6 * 32
        );
    }

    function test_previewFlushEnvelope_departedSelfMidSpan_thirdPartyPricesZero()
        public
    {
        _depositOn(
            rdiamond,
            refD,
            12_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(
            rdiamond
        ).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        vm.prank(
            refD
        );

        rdiamond.transfer(
            user2,
            12_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _admin(
            rdiamond
        ).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        vm.prank(
            bot
        );

        bytes memory preview = _flush(rdiamond).previewFlushEnvelope(
            _oneRef(
                refD
            )
        );

        assertEq(
            _selfAverageInEnvelope(
                preview,
                3_003
            ),
            0
        );
    }

    function test_previewFlushEnvelope_redepositedSelfInsideSpan_ownArmPricesSpanZero()
        public
    {
        _depositOn(
            rdiamond,
            refD,
            12_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _admin(
            rdiamond
        ).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        vm.prank(
            refD
        );

        rdiamond.transfer(
            user2,
            12_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 days
        );

        _depositOn(
            rdiamond,
            refD,
            12_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _admin(
            rdiamond
        ).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        vm.prank(
            refD
        );

        bytes memory preview = _flush(rdiamond).previewFlushEnvelope(
            _oneRef(
                refD
            )
        );

        assertEq(
            _selfAverageInEnvelope(
                preview,
                3_002
            ),
            0
        );
    }

    function test_flushReferrals_departedRefereeMidSpan_prePlanSettleVouchesNothing()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushOwnLocal(
            refA
        );

        _admin(
            diamond
        ).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 2 days
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            10_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _admin(
            diamond
        ).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 4 weeks + 5 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _rec(
                diamond
            ).getCohortWeekCrumb(
                refA,
                BASE_TIME / 1 weeks + 4
            ),
            0
        );
    }

    function test_RevertWhen_previewFlushEnvelope_hubNotSet()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        _wireOne(
            bare,
            address(new CohortFlushFacet()),
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        bare.finalizeSetup();

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).previewFlushEnvelope(
            refs
        );
    }

    function test_RevertWhen_previewFlushEnvelope_emptyBatch()
        public
    {
        address[] memory refs = new address[](0);

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NothingToFlush.selector
        );

        _flush(diamond).previewFlushEnvelope(
            refs
        );
    }

    function test_RevertWhen_previewFlushEnvelope_batchTooLarge()
        public
    {
        address[] memory refs = new address[](17);

        for (uint256 i; i < 17; ++i) {
            refs[i] = address(
                uint160(0x1000 + i)
            );
        }

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).previewFlushEnvelope(
            refs
        );
    }

    // ---- batch cursor view ----

    function _buildTwoDormantMatureBooks()
        internal
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        _depositWithReferralOn(
            diamond,
            user2,
            100_000 * 1e6,
            refD
        );

        _depositOn(
            diamond,
            refD,
            100_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        _flushOwnLocal(
            refD
        );

        _reportCompletedWeekByBotWindow(
            refA
        );

        _reportCompletedWeekByBotWindow(
            refD
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        _rec(diamond).advanceBook(
            refD,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );
    }

    function test_getFlushCursors_matchesSingleGettersForBatch()
        public
    {
        _buildTwoDormantMatureBooks();

        _flushOwnLocal(
            refA
        );

        _flushOwnLocal(
            refD
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refD
        );

        address[] memory refs = new address[](3);

        refs[0] = refA;
        refs[1] = refD;
        refs[2] = stranger;

        (
            uint256[] memory throughWeeks,
            uint256[] memory gapIndexes,
            uint256[] memory gapResumeWeeks
        ) = _flushPolicy(diamond).getFlushCursors(
            refs
        );

        assertEq(
            throughWeeks.length,
            3
        );

        assertEq(
            gapIndexes.length,
            3
        );

        assertEq(
            gapResumeWeeks.length,
            3
        );

        for (uint256 i; i < refs.length; ++i) {

            (
                uint256 gapIndex,
                uint256 gapResumeWeek
            ) = _flushPolicy(diamond).getFlushGapCursor(
                refs[i]
            );

            assertEq(
                throughWeeks[i],
                _flushPolicy(diamond).getFlushedThroughWeek(
                    refs[i]
                )
            );

            assertEq(
                gapIndexes[i],
                gapIndex
            );

            assertEq(
                gapResumeWeeks[i],
                gapResumeWeek
            );
        }

        assertEq(
            throughWeeks[0],
            3_027
        );

        assertEq(
            gapIndexes[0],
            0
        );

        assertEq(
            gapResumeWeeks[0],
            3_248
        );

        assertEq(
            throughWeeks[1],
            3_055
        );

        assertEq(
            gapIndexes[1],
            0
        );

        assertEq(
            gapResumeWeeks[1],
            3_288
        );

        assertEq(
            throughWeeks[2],
            0
        );

        assertEq(
            gapIndexes[2],
            0
        );

        assertEq(
            gapResumeWeeks[2],
            0
        );
    }

    function test_getFlushCursors_emptyBatch_returnsEmptyArrays()
        public
        view
    {
        address[] memory refs = new address[](0);

        (
            uint256[] memory throughWeeks,
            uint256[] memory gapIndexes,
            uint256[] memory gapResumeWeeks
        ) = _flushPolicy(diamond).getFlushCursors(
            refs
        );

        assertEq(
            throughWeeks.length,
            0
        );

        assertEq(
            gapIndexes.length,
            0
        );

        assertEq(
            gapResumeWeeks.length,
            0
        );
    }

    // ---- fuzz ----

    function testFuzz_localFlush_reflushIdempotent(
        uint256 _warpHours
    )
        public
    {
        _warpHours = bound(
            _warpHours,
            1,
            1_000
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            block.timestamp + _warpHours * 1 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableAfter = hub.claimable(
            block.chainid,
            refA
        );

        uint256 cursorAfter = _flushPolicy(diamond).getFlushedThroughWeek(
            refA
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            claimableAfter
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            cursorAfter
        );
    }

    // ---- reported referred score: presence-weighted ----

    function _disarmSpanInWeek3002()
        internal
    {
        vm.warp(
            BASE_TIME + 2 weeks + 1 days
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 days
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );
    }

    function _paidLanes(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Paid,
            uint256 y2Paid,
            uint256 mPaid
        ) = reader.paidCursorAt(
            address(diamond),
            _referrer,
            _week
        );

        return y1Paid
            + y2Paid
            + mPaid;
    }

    function test_flushOwn_parkedAfterRearm_capsCursorThenShipsDeferredWeek()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnLocal(
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        assertEq(
            _paidLanes(
                refA,
                3_002
            ),
            0
        );

        vm.warp(
            BASE_TIME + 3 weeks + 4 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            _paidLanes(
                refA,
                3_002
            ),
            uint256(10_000 * 1e6) * 5 days
        );
    }

    function test_flushOwn_parkedAfterRearm_settlesSelfCrumbToNow()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            30_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnLocal(
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        (
            uint256 settledAt,
            ,
        ) = _rec(diamond).getCohortSelfCrumb(
            refA
        );

        assertEq(
            settledAt,
            block.timestamp
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        _flushOwnLocal(
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_004
            ),
            30_000 * 1e6
        );
    }

    function test_flushOwn_lastSecondOfParkWeek_stillParksAndCaps()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnLocal(
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 3 days - 1
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _rec(diamond).getCohortBook(
            refA
        );

        assertEq(
            year1 + year2 + mature,
            10_000 * 1e6
        );

        assertEq(
            lastSettle,
            BASE_TIME + 2 weeks + 1 days
        );
    }

    function test_flushOwn_parkWeekEnd_crossesSpanAndShips()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnLocal(
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 3 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_002
        );

        assertEq(
            _paidLanes(
                refA,
                3_002
            ),
            uint256(10_000 * 1e6) * 5 days
        );
    }

    function test_flushOwnWindow_openWeekWhileParked_capsCursorBelowDisarmWeek()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushOwnLocal(
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_003,
            0
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    function test_flushOwn_virginCursorWhileParked_capsCursorBelowDisarmWeek()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _disarmSpanInWeek3002();

        vm.warp(
            BASE_TIME + 3 weeks + 1 days
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flushPolicy(diamond).getFlushedThroughWeek(
                refA
            ),
            3_001
        );
    }

    // ---- vault-built envelope application ----

    function _applyVaultBuilt(
        bytes32 _messageId,
        uint256 _chainId,
        bytes memory _payload
    )
        internal
    {
        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: _messageId,
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(
                    address(rdiamond)
                ),
                data: _payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        hub.applyFlush(
            _messageId,
            REMOTE_SELECTOR,
            _chainId,
            address(rdiamond),
            _payload
        );
    }

    // ---- realised week pricing: week W is priced from W's own completed
    // averages, whoever flushes and whatever happens after W ----

    function _tierOracle(
        uint256 _value
    )
        internal
        pure
        returns (uint256)
    {
        uint256[8] memory thresholds = [
            uint256(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];

        for (uint256 i = 8; i > 0; --i) {

            if (_value >= thresholds[i - 1]) {
                return 100 * i;
            }
        }

        return 0;
    }

    function _weekPriceOracle(
        uint256 _word,
        uint256 _selfAvg
    )
        internal
        pure
        returns (uint256)
    {
        uint256 referredAvg = (
            CohortWeeks._laneY1(
                _word
            )
                + CohortWeeks._laneY2(
                    _word
                )
                + CohortWeeks._laneM(
                    _word
                )
        ) / CohortWeeks.WEEK;

        uint256 y1Bps = _tierOracle(
            referredAvg
        ) + _tierOracle(
            _selfAvg
        );

        uint256 y2Bps;

        uint256 mBps;

        if (y1Bps >= 1_000) {
            y1Bps = 1_000;
            y2Bps = 500;
            mBps = 100;
        }

        return (
            CohortWeeks._laneY1(
                _word
            ) * y1Bps
                + CohortWeeks._laneY2(
                    _word
                ) * y2Bps
                + CohortWeeks._laneM(
                    _word
                ) * mBps
        ) / (10_000 * CohortWeeks.YEAR);
    }

    function _flushLocalAs(
        address _caller,
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.prank(
            _caller
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function _runReferredLeave(
        address _flusher
    )
        internal
        returns (uint256 claimed)
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositWithReferralOn(
            diamond,
            user2,
            1_000 * 1e6,
            refA
        );

        _flushLocalAs(
            refA,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            stranger,
            100_000 * 1e6
        );

        _rec(diamond).syncReferee(
            user1
        );

        _flushLocalAs(
            _flusher,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushLocalAs(
            _flusher,
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushLocalAs(
            _flusher,
            refA
        );

        claimed = hub.claimable(
            block.chainid,
            refA
        );
    }

    function test_flush_referreeLeavesAfterW_ownAndThirdPartyPriceEachWeekFromItsOwnAverage()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        uint256 snapshot = vm.snapshotState();

        uint256 ownClaim = _runReferredLeave(
            refA
        );

        vm.revertToState(
            snapshot
        );

        uint256 thirdPartyClaim = _runReferredLeave(
            bot
        );

        uint256 expected;

        for (uint256 week = 3_000; week < 3_003; ++week) {
            expected += _weekPriceOracle(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    week
                ),
                0
            );
        }

        assertEq(
            ownClaim,
            thirdPartyClaim
        );

        assertEq(
            thirdPartyClaim,
            expected
        );
    }

    function test_flush_withdrawnSelfStake_pricesOnlyTheWeeksItWasPresent()
        public
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        _depositWithReferralOn(
            diamond,
            user2,
            10_000 * 1e6,
            refA
        );

        _flushLocalAs(
            refA,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        vm.prank(
            refA
        );

        diamond.transfer(
            stranger,
            100_000 * 1e6
        );

        _rec(diamond).syncReferee(
            refA
        );

        _flushLocalAs(
            bot,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushLocalAs(
            bot,
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushLocalAs(
            bot,
            refA
        );

        uint256 expected = _weekPriceOracle(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_000
            ),
            100_000 * 1e6 * (CohortWeeks.WEEK - 1 hours) / CohortWeeks.WEEK
        )
            + _weekPriceOracle(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    3_001
                ),
                100_000 * 1e6 * 1 hours / CohortWeeks.WEEK
            )
            + _weekPriceOracle(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    3_002
                ),
                0
            );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expected
        );
    }

    function test_flush_booklessSelfStake_reportsClosedWeeksWithoutAnchoringABook()
        public
    {
        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        _flushLocalAs(
            refA,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        vm.expectEmit(
            true,
            false,
            false,
            false,
            address(diamond)
        );

        emit CohortSelfLogged(
            refA,
            0,
            0,
            0
        );

        _flushLocalAs(
            refA,
            refA
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _rec(diamond).getCohortBook(
            refA
        );

        assertEq(
            lastSettle,
            0
        );

        assertEq(
            _flushPolicy(
                diamond
            ).getFlushedThroughWeek(
                refA
            ),
            3_001
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_000
            ),
            100_000 * 1e6 * (CohortWeeks.WEEK - 1 hours) / CohortWeeks.WEEK
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_001
            ),
            100_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_002
            ),
            0
        );
    }

    function test_flush_booklessSelfStake_firstFlushAfterBoundary_reportsPriorClosedWeeks()
        public
    {
        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_000
            ),
            100_000 * 1e6 * (CohortWeeks.WEEK - 1 hours) / CohortWeeks.WEEK
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_001
            ),
            100_000 * 1e6
        );
    }

    function test_flush_booklessSelfStake_settleBeforeFirstFlush_keepsEarlierWeeks()
        public
    {
        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _depositOn(
            diamond,
            refA,
            1 * 1e6
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_000
            ),
            100_000 * 1e6 * (CohortWeeks.WEEK - 1 hours) / CohortWeeks.WEEK
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_001
            ),
            100_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_002
            ),
            (100_000 * 1e6 * 1 hours + 100_001 * 1e6 * (CohortWeeks.WEEK - 1 hours)) / CohortWeeks.WEEK
        );
    }

    function test_flush_refillByTransferAfterRearm_staysUntrackedAndCountsNoPresence()
        public
    {
        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 days
        );

        vm.prank(
            refA
        );

        diamond.transfer(
            stranger,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        vm.prank(
            stranger
        );

        diamond.transfer(
            refA,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_002
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_003
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_004
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_005
            ),
            0
        );

        assertEq(
            _rec(
                diamond
            ).getTrackedContribution(
                refA
            ),
            0
        );
    }

    function test_flush_publicNonBotCaller_earnsNoCourierFee()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        _flushPolicy(diamond).setPublicFlushEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        uint256 referrerBefore = hub.claimable(
            block.chainid,
            refA
        );

        _flushLocalAs(
            stranger,
            refA
        );

        assertGt(
            hub.claimable(
                block.chainid,
                refA
            ),
            referrerBefore
        );

        assertEq(
            hub.claimable(
                block.chainid,
                stranger
            ),
            0
        );

        assertEq(
            hub.totalAccrued(),
            hub.claimable(
                block.chainid,
                refA
            )
        );
    }

    function test_flush_stakeLeftDuringDisarmSpan_neverLoggedAgainAfterRearm()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 1 weeks + 2 days
        );

        vm.prank(
            refA
        );

        diamond.transfer(
            stranger,
            100_000 * 1e6
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _admin(diamond).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        _flushLocalAs(
            refA,
            refA
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(diamond)
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_003
            ),
            0
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                3_004
            ),
            0
        );

        assertEq(
            _rec(
                diamond
            ).getTrackedContribution(
                refA
            ),
            0
        );
    }

    function test_flush_dipAfterWeekCloses_leavesThatWeeksPrice()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        uint256 snapshot = vm.snapshotState();

        _flushLocalAs(
            refA,
            refA
        );

        uint256 steady = hub.claimable(
            block.chainid,
            refA
        );

        vm.revertToState(
            snapshot
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            stranger,
            99_000 * 1e6
        );

        _rec(diamond).syncReferee(
            user1
        );

        _flushLocalAs(
            refA,
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            steady
        );

        assertEq(
            steady,
            _weekPriceOracle(
                _rec(diamond).getCohortWeekCrumb(
                    refA,
                    3_000
                ),
                0
            )
        );
    }

    // ---- batch gas bound: sixteen books in one bot flush ----

    function _measureBotFlush(
        address[] memory _refs
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeCall(
            CohortFlushFacet.flushReferrals,
            (
                _refs
            )
        );

        vm.prank(
            bot
        );

        uint256 g = gasleft();

        (bool ok, ) = address(diamond).call(
            payload
        );

        used = g - gasleft();

        assertTrue(
            ok
        );
    }

    function _seedSixteenFlushedBooks()
        internal
        returns (address[] memory refs)
    {
        _flushPolicy(diamond).setAllowedFlushBot(
            bot,
            true
        );

        refs = new address[](
            CohortFlushCodec.MAX_FLUSH_ENTRIES
        );

        for (uint256 i; i < refs.length; ++i) {

            refs[i] = address(
                uint160(
                    0x7100 + i
                )
            );

            _depositWithReferralOn(
                diamond,
                address(
                    uint160(
                        0x7200 + i
                    )
                ),
                10_000 * 1e6,
                refs[i]
            );
        }

        vm.warp(
            BASE_TIME + 2 weeks
        );

        for (uint256 i; i < refs.length; ++i) {
            _flushOwnLocal(
                refs[i]
            );
        }

        vm.warp(
            BASE_TIME + 107 weeks
        );
    }

    function test_gas_flushReferrals_localBatchBounds()
        public
    {
        address[] memory refs = _seedSixteenFlushedBooks();

        address[] memory batch = new address[](
            LOCAL_ENTRIES
        );

        for (uint256 i; i < batch.length; ++i) {
            batch[i] = refs[i];
        }

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBookNotAdvanced.selector
        );

        _flush(diamond).flushReferrals(
            batch
        );

        uint256 snap = vm.snapshotState();

        uint256 dormantOne = _measureBotFlush(
            _oneRef(
                refs[0]
            )
        );

        vm.revertToState(
            snap
        );

        for (uint256 i; i < refs.length; ++i) {

            _rec(diamond).advanceBook(
                refs[i],
                104
            );

            _rec(diamond).advanceBook(
                refs[i],
                104
            );
        }

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        uint256 prewalkedBatch = _measureBotFlush(
            batch
        );

        console.log(
            "GAS|local flush dormant one book",
            dormantOne
        );

        console.log(
            "GAS|local flush prewalked full local batch",
            prewalkedBatch
        );

        assertLe(
            dormantOne,
            LOCAL_FLUSH_GAS_CEILING
        );

        assertLe(
            prewalkedBatch,
            LOCAL_FLUSH_GAS_CEILING
        );
    }
}
