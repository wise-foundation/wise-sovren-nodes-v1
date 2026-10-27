// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract SwitchArmedMockUSD is ERC20 {

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

contract SwitchArmedMockPermit2 is IPermit2 {

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata
    )
        external
    {
        require(
            block.timestamp <= _permit.deadline,
            "deadline"
        );

        IERC20(_permit.permitted.token).transferFrom(
            _owner,
            _transferDetails.to,
            _transferDetails.requestedAmount
        );
    }
}

/**
 * @dev With the
 * cohort recorder ARMED (`cohortSyncEnabled == true`, {CohortHookFacet}
 * installed as `transferHookFacet`), `switchQueIncentive` /
 * `switchQueIncentivePartial` stay recorder-silent, exactly like the
 * frozen `transferHookFacet == address(0)` envelope proven by
 * `WiseSovrenNodesSwitchQueIncentiveEquivalence.t.sol`. Both switch
 * functions move no vault-share tokens (the escrowed amount never
 * leaves the vault, as documented on the functions themselves in
 * {QueueJoinLeaveFacet}), so they never call `_moveVaultTokens` /
 * `_runTransferHook` and never consult the referral registry: the
 * recorder's `trackedContribution` / `cohortBook` / rings are
 * byte-identical before and after a switch call, armed or not.
 *
 * `leaveQue` + `joinQue` (and `reduceQueAmount` + `joinQue`), by
 * contrast, DO move tokens and DO run the hook at four observation
 * points (leave's pre-restitution sync, join's pre-escrow sync, and
 * join's explicit post-escrow sync, each touching both queue
 * counterparties). When the user's `trackedContribution` sits exactly
 * at their held balance (the steady state an initial `joinQue`
 * escrow-clamp already pins), every one of those four checks reads
 * `held >= tracked` and early-returns silently, so the two-call route
 * is ALSO silent, and fused-switch stays byte-identical to it even
 * armed (`test_switchQueIncentive_armedNoDeficit_byteIdenticalToLeaveJoin`).
 *
 * When a PRIOR plain `transfer` has left a stale lazy-clamp deficit
 * pending (the hook fires before the balance change, so `tracked >
 * held` survives the transfer uncorrected), the two-call route's
 * pre-restitution sync inside `leaveQue` clamps the deficit immediately
 * (referrer book reduced, `trackedContribution` lowered), while a bare
 * `switchQueIncentive` defers it indefinitely (no hook call at all).
 * The divergence is closed by a single permissionless
 * `syncReferee` poke in the same block: `switch` then `poke` lands in
 * the exact state `leave+join` reaches directly, because both paths
 * settle the SAME referrer book by the SAME delta at the SAME
 * `block.timestamp`
 * (`test_switchQueIncentive_armedPendingDeficit_divergesByClampTimingOnly`,
 * `testFuzz_switchQueIncentive_armed_switchPlusPokeEqualsLeaveJoin`, and
 * their `switchQueIncentivePartial` mirrors).
 *
 * `test_switchQueIncentive_armedHostileRegistry_stillSilentAndSucceeds`
 * closes the last angle: switch never even reaches
 * `_cohortReferrerOf`, so a registry etched with unconditionally
 * reverting bytecode cannot affect it at all; unlike `syncReferee` /
 * `joinQue`, which route through the guarded staticcall and would
 * merely skip their clamp, switch has no registry-shaped failure mode
 * to skip in the first place.
 *
 * The pending-deficit drivers below are deliberately decomposed into
 * small phase helpers (`_armPinAndDeficit`, `_runLeaveJoinBaseline` /
 * `_runReduceJoinBaseline`, `_runSwitchThenPoke` /
 * `_runSwitchPartialThenPoke`, `_assertClampedByDeficit`,
 * `_assertPokeClosure`) and a `DeficitCase` input struct instead of
 * loose `uint256` parameters. Each phase gets its own stack frame, and
 * `forge coverage` instrumentation adds enough
 * extra live variables per statement that the original single-function
 * driver (four `uint256` params plus ~seven locals) tipped over the
 * 16-slot EVM stack limit even though plain `forge test` compiled it
 * fine under legacy codegen.
 */
contract WiseSovrenNodesSwitchQueIncentiveCohortArmedTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant JOIN_AMOUNT = 2_000 * 1e6;

    uint256 internal constant PARTIAL_AMOUNT = 800 * 1e6;

    uint256 internal constant DEFICIT_AMOUNT = 800 * 1e6;

    int256 internal constant INCENTIVE_A = 0;

    int256 internal constant INCENTIVE_B = 100;

    bytes32 internal constant CREDITED_TOPIC = keccak256(
        "CohortContributionCredited(address,address,uint256)"
    );

    bytes32 internal constant SYNCED_TOPIC = keccak256(
        "CohortContributionSynced(address,address,uint256,uint256)"
    );

    bytes32 internal constant REDUCED_TOPIC = keccak256(
        "CohortBookReduced(address,uint256,uint256,uint256,uint256)"
    );

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);
    address internal poker = address(0xD1);

    WiseSovrenNodesDiamond internal diamond;
    SwitchArmedMockUSD internal usd;

    struct QueueSnap {
        uint256 total;
        uint256 countA;
        uint256 curA;
        uint256 earlA;
        uint256 countB;
        uint256 curB;
        uint256 earlB;
        address[8] mA;
        uint256[8] amtA;
        uint256[8] tailA;
        uint256[8] headA;
        address[8] mB;
        uint256[8] amtB;
        uint256[8] tailB;
        uint256[8] headB;
        uint256 proxyUser;
        uint256 cashedUser;
        uint256 syncUser;
        uint256 sharesUser;
        uint256 sharesVault;
        uint256 supply;
        address benefactor;
    }

    struct RecorderSnap {
        uint256 trackedUser;
        uint256 scoreRef;
        uint256 book1;
        uint256 book2;
        uint256 book3;
        uint256 lastSettle;
        uint64[52] ring1;
        uint64[52] ring2;
    }

    struct FullSnap {
        QueueSnap queue;
        RecorderSnap recorder;
    }

    struct DeficitCase {
        uint256 depositAmt;
        uint256 joinAmt;
        uint256 moveAmt;
        uint256 deficitAmt;
    }

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new SwitchArmedMockUSD();

        SwitchArmedMockPermit2 mockPermit2 = new SwitchArmedMockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mockPermit2).code
        );

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireQueueFacets(
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

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();
    }

    // ---- helpers ----

    function _arm()
        internal
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _assertArmedEnvelope()
        internal
        view
    {
        assertTrue(
            diamond.transferHookFacet() != address(0)
        );

        assertTrue(
            _recorder().getCohortSyncEnabled()
        );
    }

    function _fundAndApprove(
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

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApprove(
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

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    function _join(
        address _user,
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (uint256 id)
    {
        vm.prank(
            _user
        );

        (
            ,
            id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _amount,
            _incentive
        );
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
            if (_logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _assertNoCohortTopics(
        Vm.Log[] memory _logs
    )
        internal
        pure
    {
        assertEq(
            _countTopic(
                _logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                _logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                _logs,
                REDUCED_TOPIC
            ),
            0
        );
    }

    // ---- capture / assert ----

    function _captureQueue(
        int256 _a,
        int256 _b,
        address _user
    )
        internal
        view
        returns (QueueSnap memory s)
    {
        s.total = diamond.totalActiveOrders();

        s.countA = diamond.activeOrderCountByIncentive(
            _a
        );

        s.curA = diamond.currentOrderIdByIncentive(
            _a
        );

        s.earlA = diamond.earliestValidQueMemberByIncentive(
            _a
        );

        s.countB = diamond.activeOrderCountByIncentive(
            _b
        );

        s.curB = diamond.currentOrderIdByIncentive(
            _b
        );

        s.earlB = diamond.earliestValidQueMemberByIncentive(
            _b
        );

        for (uint256 i; i < 8; i++) {
            (
                s.mA[i],
                s.amtA[i],
                s.tailA[i],
                s.headA[i]
            ) = diamond.QueMemberByIdAndIncentive(
                i,
                _a
            );

            (
                s.mB[i],
                s.amtB[i],
                s.tailB[i],
                s.headB[i]
            ) = diamond.QueMemberByIdAndIncentive(
                i,
                _b
            );
        }

        s.proxyUser = diamond.proxyBalance(
            _user
        );

        s.cashedUser = diamond.cashedInterest(
            _user
        );

        s.syncUser = diamond.lastSyncTimeStamp(
            _user
        );

        s.sharesUser = diamond.balanceOf(
            _user
        );

        s.sharesVault = diamond.balanceOf(
            address(diamond)
        );

        s.supply = diamond.totalSupply();
        s.benefactor = diamond.currentProxyBenefactor();
    }

    function _captureRecorder(
        address _user,
        address _referrer
    )
        internal
        view
        returns (RecorderSnap memory s)
    {
        s.trackedUser = _recorder().getTrackedContribution(
            _user
        );

        s.scoreRef = _recorder().getCohortScore(
            _referrer
        );

        (
            s.book1,
            s.book2,
            s.book3,
            s.lastSettle
        ) = _recorder().getCohortBook(_referrer);

        (
            s.ring1,
            s.ring2
        ) = _recorder().getCohortRings(_referrer);
    }

    function _captureFull(
        int256 _a,
        int256 _b,
        address _user,
        address _referrer
    )
        internal
        view
        returns (FullSnap memory s)
    {
        s.queue = _captureQueue(
            _a,
            _b,
            _user
        );

        s.recorder = _captureRecorder(
            _user,
            _referrer
        );
    }

    function _assertQueueEq(
        QueueSnap memory _x,
        QueueSnap memory _y
    )
        internal
        pure
    {
        assertEq(
            _x.total,
            _y.total,
            "totalActiveOrders"
        );

        assertEq(
            _x.countA,
            _y.countA,
            "countA"
        );

        assertEq(
            _x.curA,
            _y.curA,
            "curA"
        );

        assertEq(
            _x.earlA,
            _y.earlA,
            "earlA"
        );

        assertEq(
            _x.countB,
            _y.countB,
            "countB"
        );

        assertEq(
            _x.curB,
            _y.curB,
            "curB"
        );

        assertEq(
            _x.earlB,
            _y.earlB,
            "earlB"
        );

        for (uint256 i; i < 8; i++) {

            assertEq(
                _x.mA[i],
                _y.mA[i],
                "memberA"
            );

            assertEq(
                _x.amtA[i],
                _y.amtA[i],
                "amountA"
            );

            assertEq(
                _x.tailA[i],
                _y.tailA[i],
                "tailA"
            );

            assertEq(
                _x.headA[i],
                _y.headA[i],
                "headA"
            );

            assertEq(
                _x.mB[i],
                _y.mB[i],
                "memberB"
            );

            assertEq(
                _x.amtB[i],
                _y.amtB[i],
                "amountB"
            );

            assertEq(
                _x.tailB[i],
                _y.tailB[i],
                "tailB"
            );

            assertEq(
                _x.headB[i],
                _y.headB[i],
                "headB"
            );
        }

        assertEq(
            _x.proxyUser,
            _y.proxyUser,
            "proxyBalance"
        );

        assertEq(
            _x.cashedUser,
            _y.cashedUser,
            "cashedInterest"
        );

        assertEq(
            _x.syncUser,
            _y.syncUser,
            "lastSyncTimeStamp"
        );

        assertEq(
            _x.sharesUser,
            _y.sharesUser,
            "user shares"
        );

        assertEq(
            _x.sharesVault,
            _y.sharesVault,
            "vault shares"
        );

        assertEq(
            _x.supply,
            _y.supply,
            "totalSupply"
        );

        assertEq(
            _x.benefactor,
            _y.benefactor,
            "currentProxyBenefactor"
        );

        assertEq(
            _x.benefactor,
            address(0),
            "benefactor reset to zero"
        );
    }

    function _assertRecorderEq(
        RecorderSnap memory _x,
        RecorderSnap memory _y
    )
        internal
        pure
    {
        assertEq(
            _x.trackedUser,
            _y.trackedUser,
            "trackedContribution"
        );

        assertEq(
            _x.scoreRef,
            _y.scoreRef,
            "cohortScore"
        );

        assertEq(
            _x.book1,
            _y.book1,
            "book year1"
        );

        assertEq(
            _x.book2,
            _y.book2,
            "book year2"
        );

        assertEq(
            _x.book3,
            _y.book3,
            "book mature"
        );

        assertEq(
            _x.lastSettle,
            _y.lastSettle,
            "book lastSettle"
        );

        for (uint256 i; i < 52; i++) {

            assertEq(
                _x.ring1[i],
                _y.ring1[i],
                "ring1 slot"
            );

            assertEq(
                _x.ring2[i],
                _y.ring2[i],
                "ring2 slot"
            );
        }
    }

    function _assertFullEq(
        FullSnap memory _x,
        FullSnap memory _y
    )
        internal
        pure
    {
        _assertQueueEq(
            _x.queue,
            _y.queue
        );

        _assertRecorderEq(
            _x.recorder,
            _y.recorder
        );
    }

    // ---- shared differential drivers ----

    /**
     * @dev Setup phase shared by both pending-deficit drivers: arm the
     * hook, deposit with referral, join an order (pins
     * `trackedContribution == held`), then a plain transfer opens a
     * pending deficit. Returns the queue id, the stale tracked value
     * captured right after the deficit-opening transfer, and the state
     * snapshot both branches replay from.
     */
    function _armPinAndDeficit(
        DeficitCase memory _c
    )
        internal
        returns (
            uint256 queId,
            uint256 staleTracked,
            uint256 snap
        )
    {
        _arm();

        _depositWithReferralAs(
            user1,
            _c.depositAmt,
            refA
        );

        queId = _join(
            user1,
            _c.joinAmt,
            INCENTIVE_A
        );

        _transferAs(
            user1,
            outsider,
            _c.deficitAmt
        );

        staleTracked = _recorder().getTrackedContribution(
            user1
        );

        _assertArmedEnvelope();

        snap = vm.snapshotState();
    }

    function _runLeaveJoinBaseline(
        uint256 _queId,
        uint256 _joinAmt
    )
        internal
        returns (
            FullSnap memory baseline,
            uint256 baseNewId
        )
    {
        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            _queId,
            INCENTIVE_A
        );

        (
            ,
            baseNewId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _joinAmt,
            INCENTIVE_B
        );

        vm.stopPrank();

        baseline = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );
    }

    function _runReduceJoinBaseline(
        uint256 _queId,
        uint256 _partialAmt
    )
        internal
        returns (
            FullSnap memory baseline,
            uint256 baseNewId
        )
    {
        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            _queId,
            INCENTIVE_A,
            _partialAmt
        );

        (
            ,
            baseNewId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            _partialAmt,
            INCENTIVE_B
        );

        vm.stopPrank();

        baseline = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );
    }

    function _runSwitchThenPoke(
        uint256 _queId,
        uint256 _staleTracked
    )
        internal
        returns (
            FullSnap memory afterPoke,
            uint256 switchNewId
        )
    {
        vm.prank(
            user1
        );

        (
            ,
            switchNewId
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            _queId,
            INCENTIVE_A,
            INCENTIVE_B
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            _staleTracked,
            "switch alone must defer the clamp"
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        afterPoke = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );
    }

    function _runSwitchPartialThenPoke(
        uint256 _queId,
        uint256 _partialAmt,
        uint256 _staleTracked
    )
        internal
        returns (
            FullSnap memory afterPoke,
            uint256 switchNewId
        )
    {
        vm.prank(
            user1
        );

        (
            ,
            switchNewId
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentivePartial(
            _queId,
            INCENTIVE_A,
            INCENTIVE_B,
            _partialAmt
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            _staleTracked,
            "switchPartial alone must defer the clamp"
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        afterPoke = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );
    }

    function _assertClampedByDeficit(
        FullSnap memory _baseline,
        uint256 _staleTracked,
        uint256 _deficitAmt
    )
        internal
        pure
    {
        assertEq(
            _baseline.recorder.trackedUser,
            _staleTracked - _deficitAmt,
            "baseline must clamp exactly by the deficit"
        );
    }

    function _assertPokeClosure(
        FullSnap memory _baseline,
        FullSnap memory _afterPoke,
        uint256 _switchNewId,
        uint256 _baseNewId
    )
        internal
        pure
    {
        assertEq(
            _switchNewId,
            _baseNewId
        );

        _assertFullEq(
            _baseline,
            _afterPoke
        );
    }

    /**
     * @dev Pending-deficit driver, reused by the fixed test
     * and its fuzz counterpart. Baseline clamps immediately inside
     * `leaveQue`'s pre-restitution hook check; the fused branch defers
     * (bare `switchQueIncentive` never touches the recorder) until a
     * same-block `syncReferee` poke closes the gap. Both branches
     * settle the SAME referrer book by the SAME delta at the SAME
     * `block.timestamp`, so post-poke state must be byte-identical.
     */
    function _assertSwitchPlusPokeEqualsLeaveJoin(
        DeficitCase memory _c
    )
        internal
    {
        (
            uint256 queId,
            uint256 staleTracked,
            uint256 snap
        ) = _armPinAndDeficit(_c);

        (
            FullSnap memory baseline,
            uint256 baseNewId
        ) = _runLeaveJoinBaseline(
            queId,
            _c.joinAmt
        );

        _assertClampedByDeficit(
            baseline,
            staleTracked,
            _c.deficitAmt
        );

        vm.revertToState(
            snap
        );

        (
            FullSnap memory afterPoke,
            uint256 switchNewId
        ) = _runSwitchThenPoke(
            queId,
            staleTracked
        );

        _assertPokeClosure(
            baseline,
            afterPoke,
            switchNewId,
            baseNewId
        );
    }

    /**
     * @dev Partial mirror of `_assertSwitchPlusPokeEqualsLeaveJoin`,
     * comparing `reduceQueAmount` + `joinQue` against
     * `switchQueIncentivePartial` + `syncReferee`.
     */
    function _assertSwitchPartialPlusPokeEqualsReduceJoin(
        DeficitCase memory _c
    )
        internal
    {
        (
            uint256 queId,
            uint256 staleTracked,
            uint256 snap
        ) = _armPinAndDeficit(_c);

        (
            FullSnap memory baseline,
            uint256 baseNewId
        ) = _runReduceJoinBaseline(
            queId,
            _c.moveAmt
        );

        _assertClampedByDeficit(
            baseline,
            staleTracked,
            _c.deficitAmt
        );

        vm.revertToState(
            snap
        );

        (
            FullSnap memory afterPoke,
            uint256 switchNewId
        ) = _runSwitchPartialThenPoke(
            queId,
            _c.moveAmt,
            staleTracked
        );

        _assertPokeClosure(
            baseline,
            afterPoke,
            switchNewId,
            baseNewId
        );
    }

    // ---- full-switch armed cases ----

    function test_switchQueIncentive_armedNoDeficit_byteIdenticalToLeaveJoin()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        uint256 queId = _join(
            user1,
            JOIN_AMOUNT,
            INCENTIVE_A
        );

        _assertArmedEnvelope();

        FullSnap memory preDiff = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        uint256 snap = vm.snapshotState();

        vm.recordLogs();

        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            queId,
            INCENTIVE_A
        );

        (
            ,
            uint256 baseNewId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            JOIN_AMOUNT,
            INCENTIVE_B
        );

        vm.stopPrank();

        _assertNoCohortTopics(
            vm.getRecordedLogs()
        );

        FullSnap memory baseline = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        _assertRecorderEq(
            preDiff.recorder,
            baseline.recorder
        );

        vm.revertToState(
            snap
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        (
            ,
            uint256 switchNewId
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            queId,
            INCENTIVE_A,
            INCENTIVE_B
        );

        _assertNoCohortTopics(
            vm.getRecordedLogs()
        );

        FullSnap memory fused = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        _assertRecorderEq(
            preDiff.recorder,
            fused.recorder
        );

        assertEq(
            switchNewId,
            baseNewId
        );

        _assertFullEq(
            baseline,
            fused
        );
    }

    function test_switchQueIncentive_armedPendingDeficit_divergesByClampTimingOnly()
        public
    {
        _assertSwitchPlusPokeEqualsLeaveJoin(
            DeficitCase({
                depositAmt: DEPOSIT,
                joinAmt: JOIN_AMOUNT,
                moveAmt: JOIN_AMOUNT,
                deficitAmt: DEFICIT_AMOUNT
            })
        );
    }

    function testFuzz_switchQueIncentive_armed_switchPlusPokeEqualsLeaveJoin(
        uint256 _depositSeed,
        uint256 _joinSeed,
        uint256 _deficitSeed
    )
        public
    {
        uint256 depositAmt = bound(
            _depositSeed,
            2_000 * 1e6,
            200_000 * 1e6
        );

        uint256 joinAmt = bound(
            _joinSeed,
            50 * 1e6,
            depositAmt / 2
        );

        uint256 deficitAmt = bound(
            _deficitSeed,
            1 * 1e6,
            depositAmt - joinAmt
        );

        _assertSwitchPlusPokeEqualsLeaveJoin(
            DeficitCase({
                depositAmt: depositAmt,
                joinAmt: joinAmt,
                moveAmt: joinAmt,
                deficitAmt: deficitAmt
            })
        );
    }

    // ---- partial-switch armed cases ----

    function test_switchQueIncentivePartial_armedNoDeficit_byteIdenticalToReduceJoin()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        uint256 queId = _join(
            user1,
            JOIN_AMOUNT,
            INCENTIVE_A
        );

        _assertArmedEnvelope();

        FullSnap memory preDiff = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        uint256 snap = vm.snapshotState();

        vm.recordLogs();

        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            queId,
            INCENTIVE_A,
            PARTIAL_AMOUNT
        );

        (
            ,
            uint256 baseNewId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            PARTIAL_AMOUNT,
            INCENTIVE_B
        );

        vm.stopPrank();

        _assertNoCohortTopics(
            vm.getRecordedLogs()
        );

        FullSnap memory baseline = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        _assertRecorderEq(
            preDiff.recorder,
            baseline.recorder
        );

        vm.revertToState(
            snap
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        (
            ,
            uint256 switchNewId
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentivePartial(
            queId,
            INCENTIVE_A,
            INCENTIVE_B,
            PARTIAL_AMOUNT
        );

        _assertNoCohortTopics(
            vm.getRecordedLogs()
        );

        FullSnap memory fused = _captureFull(
            INCENTIVE_A,
            INCENTIVE_B,
            user1,
            refA
        );

        _assertRecorderEq(
            preDiff.recorder,
            fused.recorder
        );

        assertEq(
            switchNewId,
            baseNewId
        );

        _assertFullEq(
            baseline,
            fused
        );
    }

    function test_switchQueIncentivePartial_armedPendingDeficit_divergesByClampTimingOnly()
        public
    {
        _assertSwitchPartialPlusPokeEqualsReduceJoin(
            DeficitCase({
                depositAmt: DEPOSIT,
                joinAmt: JOIN_AMOUNT,
                moveAmt: PARTIAL_AMOUNT,
                deficitAmt: DEFICIT_AMOUNT
            })
        );
    }

    // ---- hostile registry ----

    function test_switchQueIncentive_armedHostileRegistry_stillSilentAndSucceeds()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        uint256 queId = _join(
            user1,
            JOIN_AMOUNT,
            INCENTIVE_A
        );

        uint256 trackedBefore = _recorder().getTrackedContribution(
            user1
        );

        uint256 scoreBefore = _recorder().getCohortScore(
            refA
        );

        address registryAddr = AdminFacet(address(diamond)).getReferralRegistry();

        vm.etch(
            registryAddr,
            hex"60006000fd"
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            queId,
            INCENTIVE_A,
            INCENTIVE_B
        );

        _assertNoCohortTopics(
            vm.getRecordedLogs()
        );

        assertEq(
            diamond.activeOrderCountByIncentive(
                INCENTIVE_A
            ),
            0
        );

        assertEq(
            diamond.activeOrderCountByIncentive(
                INCENTIVE_B
            ),
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            trackedBefore
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            scoreBefore
        );
    }
}
