// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";
import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {CohortLaneHarness} from "./utils/CohortLaneHarness.sol";

contract SelfCrumbMockUSD is ERC20 {

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
 * @dev External pure wrapper over the self crumb math of {CohortWeeks},
 * so the fuzz laws below run the library through a real call frame.
 */
contract SelfCrumbMath {

    function settle(
        uint256 _word,
        uint256 _tracked,
        uint256 _to
    )
        external
        pure
        returns (uint256)
    {
        return CohortWeeks._settleSelfCrumb(
            _word,
            _tracked,
            _to
        );
    }
}

/**
 * @dev Per-account self crumb of the cohort recorder: one packed word
 * per account holding the token-seconds of the account's own tracked
 * contribution accrued in the week of the last settle, the complete
 * token-seconds of the week before it, and the settle stamp. The
 * engine settles the word before every change of the tracked
 * contribution at the instant the change takes effect, which is what
 * keeps the self log record of each completed week exact.
 *
 * The diamond scenarios run on one real diamond with the referral
 * facet, the recorder facet, the routed bridge and move engine
 * slices, {CohortHookFacet} as the transfer hook, a wired
 * {ReferralRegistry} and the recorder armed. The clock starts one
 * hour into week 3,000, so every expected number below is derived
 * from that week start. They pin a virgin word, the first deposit
 * that starts the clock without history, the same-week accrual, the
 * completion of the previous week by a touch in the next week, the
 * full-week previous value after a gap of two or more boundaries, the
 * idempotent same-second touch (one settle event for two deposits in
 * one block), the deferred divestment that settles the parked
 * sender's word to the park instant at the pre-clamp stake, and the
 * retroactive seed writing the word exactly like a first deposit.
 *
 * The fuzz laws drive the library through {SelfCrumbMath}: a settle
 * to an instant at or before the stamp returns the word unchanged,
 * the completed week never exceeds the stake times one week under a
 * constant stake, two settles inside one week or across one boundary
 * equal one settle to the later instant, the virtual read of the
 * completed week equals the value a boundary-crossing settle writes,
 * and a word untouched for two or more boundaries reads the full
 * week at the current stake. The equality laws and the ceiling law
 * bound the stake at 1e18, whose full week of token-seconds stays
 * below the 80-bit lane mask, so they compare unclamped values. The
 * idempotence law keeps the wider bound because a no-op holds at any
 * stake, and one saturation law pins the clamp itself: a stake of at
 * least 2e18 settled across two boundaries completes the previous
 * week at exactly the lane mask.
 */
contract WiseSovrenNodesCohortSelfCrumbTest is DiamondTestHarness {

    event CohortSelfCrumbSettled(
        address indexed user,
        uint256 settledAt,
        uint256 currentWeekSeconds,
        uint256 previousWeekSeconds
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant ONE = 1e6;

    uint256 internal constant DEPOSIT = 5_000 * ONE;

    uint256 internal constant MAX_STAKE = 1_000_000_000_000_000 * 1e6;

    uint256 internal constant MAX_EXACT_STAKE = 1e18;

    uint256 internal constant MIN_SATURATING_STAKE = 2e18;

    uint256 internal constant MAX_SATURATING_STAKE = 1e30;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);

    WiseSovrenNodesDiamond internal diamond;
    SelfCrumbMockUSD internal usd;
    ReferralRegistry internal registry;
    SelfCrumbMath internal math;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new SelfCrumbMockUSD();

        math = new SelfCrumbMath();

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

        _wireOne(
            diamond,
            address(new CohortBridgeHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _selfCrumb(
        address _user
    )
        internal
        view
        returns (
            uint256 settledAt,
            uint256 current,
            uint256 previous
        )
    {
        return _recorder().getCohortSelfCrumb(
            _user
        );
    }

    function _fundAndApproveAs(
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
            address(diamond),
            _amount
        );
    }

    function _plainDepositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApproveAs(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApproveAs(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _assertSelfCrumb(
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
        ) = _selfCrumb(
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

    function _boundWeekInstant(
        uint256 _week,
        uint256 _offset
    )
        internal
        pure
        returns (uint256)
    {
        return _week * CohortWeeks.WEEK + bound(
            _offset,
            0,
            CohortWeeks.WEEK - 1
        );
    }

    // ---- diamond scenarios ----

    function test_selfCrumb_virginReadsZero()
        public
        view
    {
        _assertSelfCrumb(
            user1,
            0,
            0,
            0
        );
    }

    function test_selfCrumb_firstDeposit_startsClockWithoutHistory()
        public
    {
        _fundAndApproveAs(
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfCrumbSettled(
            user1,
            BASE_TIME,
            0,
            0
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME,
            0,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            DEPOSIT
        );
    }

    function test_selfCrumb_secondDepositSameWeek_accruesCurrent()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        _fundAndApproveAs(
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfCrumbSettled(
            user1,
            BASE_TIME + 1 days,
            DEPOSIT * 1 days,
            0
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME + 1 days,
            DEPOSIT * 1 days,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            2 * DEPOSIT
        );
    }

    function test_selfCrumb_touchNextWeek_completesPrevious()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 3 hours
        );

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME + 1 weeks + 3 hours,
            DEPOSIT * 4 hours,
            DEPOSIT * (1 weeks - 1 hours)
        );
    }

    function test_selfCrumb_touchAfterTwoWeeks_previousIsFullWeek()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 5 hours
        );

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME + 2 weeks + 5 hours,
            DEPOSIT * 6 hours,
            DEPOSIT * 1 weeks
        );
    }

    function test_selfCrumb_sameSecondTouch_isIdempotent()
        public
    {
        _fundAndApproveAs(
            user1,
            2 * DEPOSIT
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 settledSig = keccak256(
            "CohortSelfCrumbSettled(address,uint256,uint256,uint256)"
        );

        uint256 settles;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(diamond) && logs[i].topics[0] == settledSig) {
                ++settles;
            }
        }

        assertEq(
            settles,
            1
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME,
            0,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            2 * DEPOSIT
        );
    }

    function test_selfCrumb_transferParksThenDrainSettlesToParkInstant()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            DEPOSIT / 2
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME,
            0,
            0
        );

        vm.warp(
            BASE_TIME + 5 days
        );

        _fundAndApproveAs(
            outsider,
            ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfCrumbSettled(
            user1,
            BASE_TIME + 2 days,
            DEPOSIT * 2 days,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfCrumbSettled(
            outsider,
            BASE_TIME + 5 days,
            0,
            0
        );

        vm.prank(
            outsider
        );

        UserFacet(address(diamond)).deposit(
            ONE
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME + 2 days,
            DEPOSIT * 2 days,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            DEPOSIT / 2
        );

        _assertSelfCrumb(
            outsider,
            BASE_TIME + 5 days,
            0,
            0
        );
    }

    function test_selfCrumb_seedWritesLikeADeposit()
        public
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        _plainDepositAs(
            user1,
            DEPOSIT
        );

        _assertSelfCrumb(
            user1,
            0,
            0,
            0
        );

        vm.warp(
            BASE_TIME + 1 days
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfCrumbSettled(
            user1,
            BASE_TIME + 1 days,
            0,
            0
        );

        _recorder().seedCohortContribution(
            user1,
            type(uint256).max
        );

        _assertSelfCrumb(
            user1,
            BASE_TIME + 1 days,
            0,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            DEPOSIT
        );
    }

    // ---- pure math laws ----

    function testFuzz_settleSelfCrumb_idempotentForEarlierTarget(
        uint256 _stake,
        uint256 _laterStake,
        uint256 _first,
        uint256 _second
    )
        public
        view
    {
        uint256 stake = bound(
            _stake,
            0,
            MAX_STAKE
        );

        uint256 laterStake = bound(
            _laterStake,
            0,
            MAX_STAKE
        );

        uint256 first = bound(
            _first,
            3_000 weeks,
            3_200 weeks
        );

        uint256 second = bound(
            _second,
            3_000 weeks,
            first
        );

        uint256 word = math.settle(
            0,
            stake,
            first
        );

        assertEq(
            math.settle(
                word,
                laterStake,
                second
            ),
            word
        );
    }

    function testFuzz_settleSelfCrumb_previousNeverExceedsStakeWeek(
        uint256 _stake,
        uint256 _start,
        uint256 _middle,
        uint256 _end
    )
        public
        view
    {
        uint256 stake = bound(
            _stake,
            0,
            MAX_EXACT_STAKE
        );

        uint256 start = bound(
            _start,
            3_000 weeks,
            3_200 weeks
        );

        uint256 middle = bound(
            _middle,
            start,
            3_200 weeks
        );

        uint256 end = bound(
            _end,
            middle,
            3_200 weeks
        );

        uint256 ceiling = CohortWeeks._clampLane80(stake) * CohortWeeks.WEEK;

        uint256 started = math.settle(
            0,
            0,
            start
        );

        uint256 once = math.settle(
            started,
            stake,
            middle
        );

        uint256 twice = math.settle(
            once,
            stake,
            end
        );

        assertLe(
            CohortWeeks._selfCrumbPrevious(once),
            ceiling
        );

        assertLe(
            CohortWeeks._selfCrumbPrevious(twice),
            ceiling
        );

        assertLe(
            CohortWeeks._selfCrumbCurrent(twice),
            ceiling
        );
    }

    function testFuzz_settleSelfCrumb_twoStepsEqualOneStepInsideOneWeek(
        uint256 _history,
        uint256 _stake,
        uint256 _week,
        uint256 _start,
        uint256 _middle,
        uint256 _end
    )
        public
        view
    {
        uint256 history = bound(
            _history,
            0,
            MAX_EXACT_STAKE
        );

        uint256 stake = bound(
            _stake,
            0,
            MAX_EXACT_STAKE
        );

        uint256 week = bound(
            _week,
            3_000,
            3_199
        );

        uint256 weekEnd = (week + 1) * CohortWeeks.WEEK - 1;

        uint256 start = _boundWeekInstant(
            week,
            _start
        );

        uint256 middle = bound(
            _middle,
            start,
            weekEnd
        );

        uint256 end = bound(
            _end,
            middle,
            weekEnd
        );

        uint256 word = math.settle(
            0,
            history,
            start
        );

        assertEq(
            math.settle(
                math.settle(
                    word,
                    stake,
                    middle
                ),
                stake,
                end
            ),
            math.settle(
                word,
                stake,
                end
            )
        );
    }

    function testFuzz_settleSelfCrumb_twoStepsAcrossOneBoundaryEqualOneStep(
        uint256 _history,
        uint256 _stake,
        uint256 _week,
        uint256 _start,
        uint256 _middle,
        uint256 _end
    )
        public
        view
    {
        uint256 history = bound(
            _history,
            0,
            MAX_EXACT_STAKE
        );

        uint256 stake = bound(
            _stake,
            0,
            MAX_EXACT_STAKE
        );

        uint256 week = bound(
            _week,
            3_000,
            3_198
        );

        uint256 start = _boundWeekInstant(
            week,
            _start
        );

        uint256 middle = bound(
            _middle,
            start,
            (week + 1) * CohortWeeks.WEEK - 1
        );

        uint256 end = _boundWeekInstant(
            week + 1,
            _end
        );

        uint256 word = math.settle(
            0,
            history,
            start
        );

        assertEq(
            math.settle(
                math.settle(
                    word,
                    stake,
                    middle
                ),
                stake,
                end
            ),
            math.settle(
                word,
                stake,
                end
            )
        );
    }

    function testFuzz_settleSelfCrumb_saturatesAtLaneMask(
        uint256 _stake,
        uint256 _week,
        uint256 _start,
        uint256 _end
    )
        public
        view
    {
        uint256 stake = bound(
            _stake,
            MIN_SATURATING_STAKE,
            MAX_SATURATING_STAKE
        );

        uint256 week = bound(
            _week,
            3_000,
            3_198
        );

        uint256 start = _boundWeekInstant(
            week,
            _start
        );

        uint256 end = _boundWeekInstant(
            week + 2,
            _end
        );

        uint256 started = math.settle(
            0,
            0,
            start
        );

        uint256 settled = math.settle(
            started,
            stake,
            end
        );

        assertEq(
            CohortWeeks._selfCrumbPrevious(settled),
            CohortWeeks.LANE_MASK_80
        );

        assertLe(
            CohortWeeks._selfCrumbCurrent(settled),
            CohortWeeks.LANE_MASK_80
        );
    }

    // ---- moved-amount pin: a boundary-crossing deposit logs the completed self week ----

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    function test_selfCrumb_touchNextWeek_logsTheCompletedWeek()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 weeks + 3 hours
        );

        _fundAndApproveAs(
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSelfLogged(
            user1,
            BASE_TIME / 1 weeks,
            DEPOSIT * (1 weeks - 1 hours),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );
    }
}

/**
 * @dev Engine-level pins for the self crumb and the settle-to paths
 * of the cohort recorder, driven through {CohortLaneHarness} so a
 * deferred divestment can be replayed at an explicit park instant
 * that the diamond scenarios above only reach through the drain. The
 * harness resolves referrers through a standalone {ReferralRegistry}
 * that allowlists it, so the engine reads the referee's assignment
 * through the production lookup; `harnessSetTracked` stages the
 * tracked contribution fully attributed.
 *
 * The walk anchor pin replays a drain whose park instant lies in
 * week P = 3,100 while the block clock already stands in week P + 1.
 * The book was settled to the park instant, so the settle-to returns
 * at once and no rotation runs. The referrer's year-one ring holds
 * 500e6 credited in the park week at slot P % 52 and 500e6 credited
 * 51 weeks earlier at slot (P - 51) % 52, the oldest live cohort,
 * which is the same slot as (P + 1) % 52. The reduce walk visits
 * slot (anchor - back) % 52 for back = 0, 1, 2 and onwards, newest
 * first. Anchored at the settle cursor (week P) it takes 500e6 from
 * slot P at back = 0 and the remaining 100e6 of the 600e6 deficit
 * from slot (P - 51) % 52 at back = 51, leaving 400e6 on the oldest
 * cohort. Anchored at the block clock (week P + 1) it would start on
 * slot (P + 1) % 52, drain the oldest cohort first and leave 400e6
 * on slot P instead, which is the outcome the pin refuses.
 *
 * The settle-to pins: a book target before the settle cursor leaves
 * the book untouched and emits nothing, a virgin book stamps its
 * cursor to the target and reports the stamp with
 * {CohortBookSettled} from zero without writing a crumb, a self
 * settle to a target before the self stamp is a no-op, and a
 * deferred sync settles the self crumb to the park instant at the
 * pre-clamp stake before it lowers the tracked contribution.
 */
contract WiseSovrenNodesCohortSelfCrumbEngineTest is Test {

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortSelfCrumbSettled(
        address indexed user,
        uint256 settledAt,
        uint256 currentWeekSeconds,
        uint256 previousWeekSeconds
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant PARK_WEEK = 3_100;

    uint256 internal constant TRACKED = 1_000 * 1e6;

    uint256 internal constant HELD = 400 * 1e6;

    uint256 internal constant COHORT = 500 * 1e6;

    address internal user = address(0xA1);

    address internal referrer = address(0xB1);

    CohortLaneHarness internal harness;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        harness = new CohortLaneHarness();

        ReferralRegistry registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            address(harness),
            true
        );

        harness.harnessSetRegistry(
            address(registry)
        );

        harness.harnessSetReferrer(
            user,
            referrer
        );
    }

    // ---- helpers ----

    function _countHarnessTopic(
        bytes32 _topic
    )
        internal
        view
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(harness) && logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    // ---- reduce walk anchor ----

    function test_walkReduce_anchoredAtSettleCursorNotBlockClock()
        public
    {
        uint256 parkedAt = PARK_WEEK * CohortWeeks.WEEK + 2 days;

        uint256 parkSlot = PARK_WEEK % CohortWeeks.RING_SLOTS;

        uint256 oldestSlot = (PARK_WEEK - (CohortWeeks.RING_SLOTS - 1)) % CohortWeeks.RING_SLOTS;

        vm.warp(
            (PARK_WEEK + 1) * CohortWeeks.WEEK + 1 days
        );

        uint256 blockClockSlot = (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;

        assertEq(
            blockClockSlot,
            oldestSlot
        );

        harness.harnessSetTracked(
            user,
            TRACKED
        );

        harness.harnessMintBalance(
            user,
            HELD
        );

        harness.harnessSetRingYear1(
            referrer,
            parkSlot,
            uint64(COHORT)
        );

        harness.harnessSetRingYear1(
            referrer,
            oldestSlot,
            uint64(COHORT)
        );

        harness.harnessSetBookLanes(
            referrer,
            2 * COHORT,
            0,
            0
        );

        harness.harnessSetLastSettle(
            referrer,
            parkedAt
        );

        harness.exposedSyncRefereeAt(
            user,
            parkedAt
        );

        uint256 parkSlotLeft = harness.viewRingYear1(
            referrer,
            parkSlot
        );

        uint256 oldestSlotLeft = harness.viewRingYear1(
            referrer,
            oldestSlot
        );

        uint256 book = harness.viewBookWord(
            referrer
        );

        assertEq(
            parkSlotLeft,
            0
        );

        assertEq(
            oldestSlotLeft,
            400 * 1e6
        );

        assertEq(
            harness.viewTracked(user),
            HELD
        );

        assertEq(
            CohortWeeks._laneY1(book),
            400 * 1e6
        );
    }

    // ---- settle-to targets ----

    function test_settleBookTo_earlierTargetLeavesBookUntouched()
        public
    {
        uint256 settledAt = PARK_WEEK * CohortWeeks.WEEK + 3 days;

        vm.warp(
            settledAt + 1 hours
        );

        harness.harnessSetRingYear1(
            referrer,
            PARK_WEEK % CohortWeeks.RING_SLOTS,
            uint64(COHORT)
        );

        harness.harnessSetBookLanes(
            referrer,
            COHORT,
            0,
            0
        );

        harness.harnessSetLastSettle(
            referrer,
            settledAt
        );

        uint256 bookBefore = harness.viewBookWord(
            referrer
        );

        vm.recordLogs();

        harness.exposedSettleBookTo(
            referrer,
            settledAt - 1 days
        );

        assertEq(
            _countHarnessTopic(
                CohortBookSettled.selector
            ),
            0
        );

        assertEq(
            harness.viewLastSettle(referrer),
            settledAt
        );

        assertEq(
            harness.viewBookWord(referrer),
            bookBefore
        );
    }

    function test_settleBookTo_virginBookStampsTarget()
        public
    {
        uint256 target = PARK_WEEK * CohortWeeks.WEEK + 2 days;

        vm.warp(
            target + 1 days
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortBookSettled(
            referrer,
            0,
            target,
            0
        );

        harness.exposedSettleBookTo(
            referrer,
            target
        );

        uint256 crumb = harness.viewCrumb(
            referrer,
            PARK_WEEK
        );

        assertEq(
            _countHarnessTopic(
                CohortBookSettled.selector
            ),
            1
        );

        assertEq(
            harness.viewLastSettle(referrer),
            target
        );

        assertEq(
            crumb,
            0
        );

        assertEq(
            harness.viewBookWord(referrer),
            0
        );
    }

    // ---- self settle ----

    function test_settleSelf_targetBeforeStamp_isNoop()
        public
    {
        uint256 stampedAt = PARK_WEEK * CohortWeeks.WEEK + 3 days;

        uint256 word = CohortWeeks._packSelfCrumb(
            TRACKED * 3 days,
            TRACKED * 1 weeks,
            stampedAt
        );

        vm.warp(
            stampedAt
        );

        harness.harnessSetTracked(
            user,
            TRACKED
        );

        harness.harnessSetSelfCrumb(
            user,
            word
        );

        vm.recordLogs();

        harness.exposedSettleSelf(
            user,
            stampedAt - 1
        );

        assertEq(
            _countHarnessTopic(
                CohortSelfCrumbSettled.selector
            ),
            0
        );

        assertEq(
            harness.viewSelfCrumb(user),
            word
        );
    }

    function test_syncRefereeAt_settlesSelfToTargetBeforeClamp()
        public
    {
        uint256 stampedAt = PARK_WEEK * CohortWeeks.WEEK + 1 days;

        uint256 parkedAt = PARK_WEEK * CohortWeeks.WEEK + 4 days;

        vm.warp(
            PARK_WEEK * CohortWeeks.WEEK + 5 days
        );

        harness.harnessSetTracked(
            user,
            TRACKED
        );

        harness.harnessMintBalance(
            user,
            HELD
        );

        harness.harnessSetSelfCrumb(
            user,
            CohortWeeks._packSelfCrumb(
                0,
                0,
                stampedAt
            )
        );

        harness.harnessSetRingYear1(
            referrer,
            PARK_WEEK % CohortWeeks.RING_SLOTS,
            uint64(TRACKED)
        );

        harness.harnessSetBookLanes(
            referrer,
            TRACKED,
            0,
            0
        );

        harness.harnessSetLastSettle(
            referrer,
            stampedAt
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortSelfCrumbSettled(
            user,
            parkedAt,
            TRACKED * 3 days,
            0
        );

        harness.exposedSyncRefereeAt(
            user,
            parkedAt
        );

        uint256 word = harness.viewSelfCrumb(
            user
        );

        assertEq(
            CohortWeeks._selfCrumbSettledAt(word),
            parkedAt
        );

        assertEq(
            CohortWeeks._selfCrumbCurrent(word),
            TRACKED * 3 days
        );

        assertEq(
            CohortWeeks._selfCrumbPrevious(word),
            0
        );

        assertEq(
            harness.viewTracked(user),
            HELD
        );
    }
}
