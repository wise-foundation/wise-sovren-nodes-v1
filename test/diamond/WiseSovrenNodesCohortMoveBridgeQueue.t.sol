// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

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

contract MockPermit2 is IPermit2 {

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
 * @dev Minimal same-chain peer used to drive `moveBetweenVaults` /
 * `mintFromPeer` from the source diamond's perspective. `decimals()`
 * matches the source diamond's 6 decimals so `_peerScaleFactors`
 * scales 1:1 and the cohort-recorder math in the tests below
 * stays in round numbers. `mintFromPeer` is never actually invoked on
 * this contract by the suite (it is only ever the peer being pranked),
 * but is implemented as a no-op to satisfy `IPeerVault`.
 */
contract MockPeerVault {

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
 * @dev Minimal CCIP router stand-in: a flat `getFee` and a `ccipSend`
 * that only needs to accept the fee and return a messageId, because
 * every `ccipReceive` in this suite is driven directly by pranking the
 * router with a hand-built `Client.Any2EVMMessage`, mirroring
 * `WiseSovrenNodesBridge.t.sol`'s `MockCCIPRouter` without the
 * synchronous cross-diamond relay (this suite only has one diamond).
 */
contract MockCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

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
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        payable
        returns (bytes32)
    {
        return bytes32(uint256(1));
    }
}

/**
 * @dev Touchpoint suite for the cohort recorder: the
 * move/bridge/queue surfaces wired on top of the {CohortHookFacet}
 * engine installed as the transfer hook (see
 * `WiseSovrenNodesCohortTouchpoints.t.sol` for the deposit/compound
 * and lazy-clamp phase), with the dispatcher-routed
 * {CohortMoveHookFacet} slice installed beside it so the pointer
 * facet's move pair forwards into the real capture and apply.
 * `_executeMoveOut` / `_executeBridgeOut`
 * double-sync around their `_burn` (immediate discredit, no waiting
 * for the next poke); `_executeMintFromPeer` / `_executeBridgeReceive`
 * sync once BEFORE their `_mint` (clamp-before-heal, never re-credit);
 * `_transferTokensIn` syncs once AFTER the queue escrow leg
 * (immediate discredit on `joinQue`); queue leave/fulfill run the
 * ordinary two-party transfer hook via `_moveVaultTokens`, which never
 * re-credits; and `switchQueIncentive` moves no shares and runs no
 * hook at all, so recorder state must be byte-identical across it.
 *
 * `test_bridgeToVault_discreditsImmediately` additionally pins the
 * payable-delegatecall regression this suite originally uncovered:
 * `bridgeToVault` is the diamond's only payable surface and
 * `_executeBridgeOut` runs `_cohortSync` while `msg.value` still
 * carries the CCIP fee, so {CohortHookFacet}'s entrypoints must stay
 * `payable`; a non-payable engine would revert on the compiler's
 * callvalue guard and DoS bridging out on every fee-charging lane.
 *
 * The queue-attribution tests pin the ordering guarantees around the
 * fill. `test_joinQue_emitsSyncedAndReducedInSameTx` shows the
 * post-escrow sync inside `joinQue` emits exactly one
 * `CohortBookReduced` followed by one `CohortContributionSynced` and
 * no credit, the pre-escrow hook leg staying silent because held
 * still equals tracked there.
 * `test_joinQue_reducesReferrerBookNewestFirst` shows the join-time
 * reduction consumes the newest ring slot before spilling into an
 * older one across two consecutive joins.
 * `test_fulfillOrder_referredBuyerWithTracked_keepsTrackedAndReferrerBook`
 * shows a referred buyer with a live tracked contribution keeps it
 * through a fill while the buyer's referrer book, rings and settle
 * stamp stay byte-identical and no recorder event fires.
 * `test_fulfillOrder_sendThenBuy_clampsBuyerBeforeFillLands` pins the
 * send-then-buy ordering: the stale deficit is clamped (newest slot
 * first, Reduced before Synced) before the fill lands, so the fill
 * never re-covers destroyed credit, while
 * `test_fulfillOrder_buyThenSend_neverDipsNoClamp` pins the opposite
 * ordering, where the balance never dips below tracked and the later
 * send leaves attribution untouched even after a poke.
 * `testFuzz_fulfillOrder_eitherOrder_attributionNeverExceedsDeposit`
 * sweeps both orderings from one snapshot and pins that tracked and
 * referrer score never exceed the original deposit in either, the
 * buy-then-send branch clamping only when the send outruns the buy.
 * The two `test_queueWash_*` tests pin that a join followed by buying
 * the shares back (own order, or a second wallet plus a transfer
 * back) restores the balance but leaves tracked and the referrer
 * book strictly below their pre-join values, the buy-back leg being
 * recorder-silent because held never drops below tracked on either
 * hook side.
 *
 * `test_reduceQueAmount_returnsWithoutRecredit` pins that a partial
 * reduce restores nothing either, exactly like `leaveQue`: the
 * returned shares stay untracked and the referrer book keeps the
 * post-join level.
 */
contract WiseSovrenNodesCohortMoveBridgeQueueTest is DiamondTestHarness {

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

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant BASE_SLOT = 3_000 % 52;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;

    uint256 internal constant CROSS_CHAIN_PEER_CHANGE_DELAY = 3 days;

    uint64 internal constant DEST_SELECTOR = 2222;

    address internal constant CROSS_CHAIN_PEER = address(0xB33F);

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
    address internal refB = address(0xB2);
    address internal outsider = address(0xC1);
    address internal buyer = address(0xC2);
    address internal poker = address(0xD1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    MockPeerVault internal peer;
    MockCCIPRouter internal router;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
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
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            diamond,
            address(new Permit2ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
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

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        peer = new MockPeerVault();

        MoveFacet(address(diamond)).proposePeerVault(
            address(peer)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamond)).executePeerVaultChange(
            address(peer)
        );

        router = new MockCCIPRouter();

        BridgeFacet(address(diamond)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            DEST_SELECTOR,
            CROSS_CHAIN_PEER,
            6
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            DEST_SELECTOR
        );
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

    function _depositAs(
        address _user,
        uint256 _amount
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

    function _assertBookEq(
        address _referrer,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature,
        uint256 _lastSettle
    )
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorder().getCohortBook(_referrer);

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

        assertEq(
            lastSettle,
            _lastSettle
        );
    }

    function _assertRingsEq(
        address _referrer,
        uint64[52] memory _ring1,
        uint64[52] memory _ring2
    )
        internal
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(_referrer);

        for (uint256 i; i < 52; ++i) {
            assertEq(
                uint256(ring1[i]),
                uint256(_ring1[i])
            );

            assertEq(
                uint256(ring2[i]),
                uint256(_ring2[i])
            );
        }
    }

    // ---- 1. moveBetweenVaults ----

    function test_moveBetweenVaults_discreditsImmediately()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(peer),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    function test_moveBetweenVaults_fullExit_zeroesTracked()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(peer),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );
    }

    // ---- 2. mintFromPeer ----

    function test_mintFromPeer_afterDeficit_clampsBeforeMint()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            address(peer)
        );

        MoveFacet(address(diamond)).mintFromPeer(
            user1,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );
    }

    function test_mintFromPeer_neverCredits()
        public
    {
        _arm();

        vm.prank(
            address(peer)
        );

        MoveFacet(address(diamond)).mintFromPeer(
            outsider,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            0
        );
    }

    // ---- 3. bridgeToVault ----

    function test_bridgeToVault_discreditsImmediately()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.deal(
            user1,
            1 ether
        );

        uint256 fee = router.FIXED_FEE();

        vm.prank(
            user1
        );

        BridgeFacet(address(diamond)).bridgeToVault{value: fee}(
            DEST_SELECTOR,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    // ---- 4. ccipReceive ----

    function test_ccipReceive_afterDeficit_clampsBeforeMint()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: DEST_SELECTOR,
            sender: abi.encode(CROSS_CHAIN_PEER),
            data: abi.encode(user1, uint256(2_000 * 1e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );
    }

    function test_ccipReceive_neverCredits()
        public
    {
        _arm();

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: DEST_SELECTOR,
            sender: abi.encode(CROSS_CHAIN_PEER),
            data: abi.encode(outsider, uint256(2_000 * 1e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            0
        );
    }

    // ---- 5. queue join / leave ----

    function test_joinQue_discreditsImmediatelyPostEscrow()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    function test_joinQue_emitsSyncedAndReducedInSameTx()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortBookReduced(
            refA,
            2_000 * 1e6,
            2_000 * 1e6,
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

        emit CohortContributionSynced(
            user1,
            refA,
            DEPOSIT,
            3_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            3_000 * 1e6
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            0
        );
    }

    function test_joinQue_reducesReferrerBookNewestFirst()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            3_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _depositWithReferralAs(
            user1,
            2_000 * 1e6,
            refA
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[3_002 % 52]),
            1_000 * 1e6
        );

        assertEq(
            uint256(ring1[BASE_SLOT]),
            3_000 * 1e6
        );

        assertEq(
            uint256(ring2[3_002 % 52]),
            0
        );

        (
            uint256 year1,
            ,
            ,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            4_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            4_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortBookReduced(
            refA,
            1_500 * 1e6,
            1_500 * 1e6,
            0,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_500 * 1e6,
            0
        );

        (
            ring1,
            ring2
        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[3_002 % 52]),
            0
        );

        assertEq(
            uint256(ring1[BASE_SLOT]),
            2_500 * 1e6
        );

        (
            year1,
            ,
            ,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            2_500 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            2_500 * 1e6
        );
    }

    function test_leaveQue_returnsEscrowWithoutRecredit()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            queId,
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );
    }

    function test_reduceQueAmount_returnsWithoutRecredit()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            queId,
            0,
            500 * 1e6
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            3_500 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    // ---- 6. fulfillOrder ----

    function test_fulfillOrder_buyerGetsNoCreditSellerUnchanged()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        _fundAndApprove(
            buyer,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            buyer
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            diamond.balanceOf(
                buyer
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );
    }

    function test_fulfillOrder_referredBuyerWithTracked_keepsTrackedAndReferrerBook()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        _depositWithReferralAs(
            buyer,
            1_000 * 1e6,
            refB
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            1_000 * 1e6
        );

        (
            uint256 year1Before,
            uint256 year2Before,
            uint256 matureBefore,
            uint256 lastSettleBefore
        ) = _recorder().getCohortBook(refB);

        (
            uint64[52] memory ring1Before,
            uint64[52] memory ring2Before
        ) = _recorder().getCohortRings(refB);

        uint256 refAScoreBefore = _recorder().getCohortScore(
            refA
        );

        _fundAndApprove(
            buyer,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            buyer
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                buyer
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            1_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            1_000 * 1e6
        );

        _assertBookEq(
            refB,
            year1Before,
            year2Before,
            matureBefore,
            lastSettleBefore
        );

        _assertRingsEq(
            refB,
            ring1Before,
            ring2Before
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            refAScoreBefore
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            buyer
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            1_000 * 1e6
        );
    }

    function test_fulfillOrder_sendThenBuy_clampsBuyerBeforeFillLands()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            60 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _depositWithReferralAs(
            user1,
            40 * 1e6,
            refA
        );

        _depositAs(
            outsider,
            1_000 * 1e6
        );

        vm.prank(
            outsider
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            50 * 1e6,
            0
        );

        _transferAs(
            user1,
            buyer,
            30 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            70 * 1e6
        );

        _fundAndApprove(
            user1,
            50 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
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
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            100 * 1e6,
            70 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                user1
            ),
            120 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            70 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            70 * 1e6
        );

        (
            uint64[52] memory ring1,

        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[3_002 % 52]),
            10 * 1e6
        );

        assertEq(
            uint256(ring1[BASE_SLOT]),
            60 * 1e6
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            70 * 1e6
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            0
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
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
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            1
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            70 * 1e6
        );

        assertLe(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertLe(
            _recorder().getCohortScore(
                refA
            ),
            100 * 1e6
        );
    }

    function test_fulfillOrder_buyThenSend_neverDipsNoClamp()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            60 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _depositWithReferralAs(
            user1,
            40 * 1e6,
            refA
        );

        _depositAs(
            outsider,
            1_000 * 1e6
        );

        vm.prank(
            outsider
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            50 * 1e6,
            0
        );

        _fundAndApprove(
            user1,
            50 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                user1
            ),
            150 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            100 * 1e6
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        vm.recordLogs();

        _transferAs(
            user1,
            buyer,
            30 * 1e6
        );

        logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                user1
            ),
            120 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        (
            uint64[52] memory ring1,

        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[3_002 % 52]),
            40 * 1e6
        );

        assertEq(
            uint256(ring1[BASE_SLOT]),
            60 * 1e6
        );

        (
            uint256 year1,
            ,
            ,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            100 * 1e6
        );

        assertLe(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );
    }

    function testFuzz_fulfillOrder_eitherOrder_attributionNeverExceedsDeposit(
        uint256 _sendSeed,
        uint256 _buySeed
    )
        public
    {
        uint256 sendAmt = bound(
            _sendSeed,
            1 * 1e6,
            100 * 1e6
        );

        uint256 buyAmt = bound(
            _buySeed,
            50 * 1e6,
            500 * 1e6
        );

        _arm();

        _depositWithReferralAs(
            user1,
            100 * 1e6,
            refA
        );

        _depositAs(
            outsider,
            1_000 * 1e6
        );

        vm.prank(
            outsider
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            buyAmt,
            0
        );

        _fundAndApprove(
            user1,
            buyAmt
        );

        uint256 snap = vm.snapshotState();

        _transferAs(
            user1,
            buyer,
            sendAmt
        );

        vm.prank(
            user1
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6 - sendAmt
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            100 * 1e6 - sendAmt
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            100 * 1e6 - sendAmt + buyAmt
        );

        assertLe(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );

        vm.revertToState(
            snap
        );

        vm.prank(
            user1
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        _transferAs(
            user1,
            buyer,
            sendAmt
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        uint256 heldAfter = diamond.balanceOf(
            user1
        );

        uint256 expectedTracked = heldAfter < 100 * 1e6
            ? heldAfter
            : 100 * 1e6;

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            expectedTracked
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            expectedTracked
        );

        assertLe(
            _recorder().getTrackedContribution(
                user1
            ),
            100 * 1e6
        );
    }

    // ---- 7. switchQueIncentive ----

    function test_switchQueIncentive_recorderStateByteIdentical()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        uint256 trackedBefore = _recorder().getTrackedContribution(
            user1
        );

        uint256 scoreBefore = _recorder().getCohortScore(
            refA
        );

        (
            uint256 year1Before,
            uint256 year2Before,
            uint256 matureBefore,
            uint256 lastSettleBefore
        ) = _recorder().getCohortBook(refA);

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            queId,
            0,
            100
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
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

        (
            uint256 year1After,
            uint256 year2After,
            uint256 matureAfter,
            uint256 lastSettleAfter
        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1After,
            year1Before
        );

        assertEq(
            year2After,
            year2Before
        );

        assertEq(
            matureAfter,
            matureBefore
        );

        assertEq(
            lastSettleAfter,
            lastSettleBefore
        );
    }

    // ---- 8. queue wash cycles ----

    function test_queueWash_joinThenSelfFill_strictlyLosesAttribution()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        uint256 trackedBefore = _recorder().getTrackedContribution(
            user1
        );

        uint256 scoreBefore = _recorder().getCohortScore(
            refA
        );

        (
            uint256 year1Before,
            ,
            ,

        ) = _recorder().getCohortBook(refA);

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        _fundAndApprove(
            user1,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            diamond.totalActiveOrders(),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertLt(
            _recorder().getTrackedContribution(
                user1
            ),
            trackedBefore
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        assertLt(
            _recorder().getCohortScore(
                refA
            ),
            scoreBefore
        );

        (
            uint256 year1After,
            uint256 year2After,
            uint256 matureAfter,

        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1After,
            3_000 * 1e6
        );

        assertLt(
            year1After,
            year1Before
        );

        assertEq(
            year2After,
            0
        );

        assertEq(
            matureAfter,
            0
        );

        (
            uint64[52] memory ring1,

        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[BASE_SLOT]),
            3_000 * 1e6
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );
    }

    function test_queueWash_joinBuyerFillTransferBack_strictlyLosesAttribution()
        public
    {
        _arm();

        _depositWithReferralAs(
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
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        _fundAndApprove(
            buyer,
            2_000 * 1e6
        );

        vm.prank(
            buyer
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        assertEq(
            diamond.balanceOf(
                buyer
            ),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            0
        );

        vm.recordLogs();

        _transferAs(
            buyer,
            user1,
            2_000 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertLt(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        assertLt(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            buyer
        );

        assertEq(
            _recorder().getTrackedContribution(
                buyer
            ),
            0
        );
    }

    // ---- moved-amount pins: queue self crumb, unreferred queue, compound via fulfill ----

    event CohortSelfLogged(
        address indexed user,
        uint256 fromWeek,
        uint256 completedSeconds,
        uint256 stake
    );

    function _assertQueueSelfCrumb(
        address _user,
        uint256 _settledAt,
        uint256 _current
    )
        internal
        view
    {
        (
            uint256 settledAt,
            uint256 current,
        ) = _recorder().getCohortSelfCrumb(
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
    }

    function _warpToFreshWeek()
        internal
    {
        vm.warp(
            (block.timestamp / 1 weeks + 1) * 1 weeks + 1 hours
        );
    }

    function test_joinQue_settlesSelfCrumbAndLeaveLeavesItUntouched()
        public
    {
        _arm();

        _warpToFreshWeek();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 joinAt = block.timestamp;

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        _assertQueueSelfCrumb(
            user1,
            joinAt,
            DEPOSIT * 1 days
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            queId,
            0
        );

        _assertQueueSelfCrumb(
            user1,
            joinAt,
            DEPOSIT * 1 days
        );

        vm.recordLogs();

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                SYNCED_TOPIC
            ),
            0
        );
    }

    function test_joinQue_unreferred_clampsTrackedOnlyNoBook()
        public
    {
        _arm();

        _warpToFreshWeek();

        _depositAs(
            outsider,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 1 days
        );

        vm.recordLogs();

        vm.prank(
            outsider
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getAttributedContribution(
                outsider
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                address(0)
            ),
            0
        );

        _assertQueueSelfCrumb(
            outsider,
            block.timestamp,
            DEPOSIT * 1 days
        );

        vm.prank(
            outsider
        );

        QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(
            queId,
            0,
            500 * 1e6
        );

        vm.prank(
            outsider
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            queId,
            0
        );

        assertEq(
            diamond.balanceOf(
                outsider
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            3_000 * 1e6
        );

        _assertQueueSelfCrumb(
            outsider,
            block.timestamp,
            DEPOSIT * 1 days
        );

        vm.recordLogs();

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            outsider
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                SYNCED_TOPIC
            ),
            0
        );
    }

    function test_joinQue_afterBoundary_logsTheCompletedSelfWeek()
        public
    {
        _arm();

        _warpToFreshWeek();

        uint256 depositAt = block.timestamp;

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            depositAt + 1 weeks + 1 days
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
            depositAt / 1 weeks,
            DEPOSIT * (1 weeks - 1 hours),
            DEPOSIT
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );
    }

    function test_compoundViaFulfillBulk_purchasedSharesUntrackedRemainderCredited()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _depositAs(
            outsider,
            DEPOSIT
        );

        vm.prank(
            outsider
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            50 * 1e6,
            0
        );

        vm.warp(
            block.timestamp + 365 days
        );

        int256[] memory incentives = new int256[](1);

        uint256[] memory memberIds = new uint256[](1);

        memberIds[0] = queId;

        uint256 balanceBefore = diamond.balanceOf(
            user1
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        (
            uint256 received,
        ) = QueueFulfillFacet(address(diamond)).compoundInterestViaFulfillBulk(
            incentives,
            memberIds,
            new uint256[](0),
            0,
            0,
            type(uint256).max
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 remainder;

        bytes32 topic = keccak256(
            "CompoundViaQueue(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] != topic) {
                continue;
            }

            (
                ,
                ,
                remainder
            ) = abi.decode(
                logs[i].data,
                (
                    uint256,
                    uint256,
                    uint256
                )
            );
        }

        assertGt(
            remainder,
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            balanceBefore + received + remainder
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT + remainder
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            DEPOSIT + remainder
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT + remainder
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            DEPOSIT - 50 * 1e6
        );
    }
}
