// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";
import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {BridgeCarryTestCodec} from "./utils/BridgeCarryTestCodec.sol";

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
 * @dev Deferred divestment of the cohort recorder. The entry contract
 * runs the transfer hook before the balance moves and passes no
 * amount, so a plain transfer used to leave the sender's tracked
 * contribution and the referrer's book untouched forever: deposit
 * under a referrer, transfer the shares to a second address, sell
 * them at par through the queue, repeat, and the book stacked one
 * full deposit per cycle on capital that came straight back. The hook
 * now parks the sender in tail slot 91 and every engine touchpoint by
 * anyone drains that slot first, syncing the parked user at the exact
 * post-transfer balance. The scenarios pin the park, every kind of
 * drain (a stranger's deposit, the recipient's queue join, a further
 * transfer, a poke), chained and partial transfers, `transferFrom`,
 * the untracked-sender skip, the lookup-failure keep and skip rules,
 * the pre-receipt drain, the disabled recorder, the router-initiated
 * skip of a parked third party, the router-lane carry landing on the
 * parked seller's own book (a co-referee's carry-bearing bridge-in
 * resolves the park at its park instant before the book settles to the
 * delivery, a self transfer of one unit parks and lands with no loss
 * while a zero transfer reverts before any park, and a failed seller
 * lookup settles the book to the delivery and keeps the slot), the
 * router-initiated resolution of a
 * parked recipient at its own park instant (a poke from the router
 * and a full `ccipReceive` delivery, a failed lookup keeping the
 * slot), the zero caller that never resolves an empty slot (a
 * `syncReferee(address(0))` poke and the re-arm) while it still
 * drains a parked third party, and the release of a parked user
 * whose balance recovered.
 * The park stores the park instant beside the sender in the same
 * slot, and the drain settles the referrer's book to that instant at
 * the unreduced principal before the clamp, so the crumb of the park
 * week counts the departed principal only until the park and a later
 * week of a fully divested book stays unwritten; the stamp clears
 * with the address and a second park stamps its own instant. The
 * bounded advance drains a parked sender like every other engine
 * entrypoint. An unset registry pointer while armed reads as a failed
 * lookup: a standing deficit defers its clamp (tracked and attributed
 * unchanged, the sender stays parked) and a deposit tracks without
 * attributing. The unset pointer is written directly into slot 77,
 * because the AdminFacet refuses a registry change while armed.
 */
contract WiseSovrenNodesCohortDivestTest is DiamondTestHarness {

    event CohortDivestParked(
        address indexed user
    );

    event CohortDivestDrained(
        address indexed user
    );

    event CohortDivestParkSkipped(
        address indexed user,
        address indexed parked
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant ONE = 1e6;

    uint256 internal constant DIVEST_SLOT = 91;

    uint256 internal constant PARKED_AT_SHIFT = 160;

    uint256 internal constant REFERRAL_REGISTRY_SLOT = 77;

    uint64 internal constant SRC_SELECTOR = 1111;

    uint256 internal constant CROSS_CHAIN_PEER_DELAY = 3 days;

    address internal referee = address(0xA1);
    address internal second = address(0xA2);
    address internal sink = address(0xA3);
    address internal third = address(0xC1);
    address internal spender = address(0xC2);
    address internal router = address(0xC3);
    address internal referrer = address(0xB1);
    address internal otherReferrer = address(0xB2);
    address internal srcPeer = address(0xFEED);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

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

        _wireOne(
            diamond,
            address(new QueueJoinLeaveFacet()),
            WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _wireOne(
            diamond,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * ONE
        );

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

    function _parked()
        internal
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    vm.load(
                        address(diamond),
                        bytes32(DIVEST_SLOT)
                    )
                )
            )
        );
    }

    function _divestWord()
        internal
        view
        returns (uint256)
    {
        return uint256(
            vm.load(
                address(diamond),
                bytes32(DIVEST_SLOT)
            )
        );
    }

    function _parkedAt()
        internal
        view
        returns (uint256)
    {
        return (_divestWord() >> PARKED_AT_SHIFT) & type(uint64).max;
    }

    function _clearRegistryPointer()
        internal
    {
        vm.store(
            address(diamond),
            bytes32(REFERRAL_REGISTRY_SLOT),
            bytes32(0)
        );

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistry(),
            address(0)
        );
    }

    function _plainDepositAs(
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

    function _pokeAs(
        address _caller,
        address _user
    )
        internal
    {
        vm.prank(
            _caller
        );

        _recorder().syncReferee(
            _user
        );
    }

    function _stageReferee()
        internal
    {
        _depositWithReferralAs(
            referee,
            10_000 * ONE,
            referrer
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );
    }

    function _stageSecond()
        internal
    {
        _depositWithReferralAs(
            second,
            7_000 * ONE,
            otherReferrer
        );

        assertEq(
            _recorder().getCohortScore(
                otherReferrer
            ),
            7_000 * ONE
        );
    }

    function _coRefereeCarry(
        address _user,
        uint256 _amount
    )
        internal
        view
        returns (bytes memory)
    {
        (
            ,
            uint256 assignedAt,
            uint256 rank
        ) = registry.getReferrerPair(
            _user
        );

        return BridgeCarryTestCodec._pack(
            referrer,
            CohortWeeks.BRIDGE_CARRY_VERSION,
            block.timestamp / CohortWeeks.WEEK,
            _amount,
            assignedAt,
            rank,
            _amount,
            0,
            0
        );
    }

    function _wireSourcePeer()
        internal
        returns (uint256 stagedAt)
    {
        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            SRC_SELECTOR,
            srcPeer,
            6
        );

        stagedAt = BASE_TIME + CROSS_CHAIN_PEER_DELAY;

        vm.warp(
            stagedAt
        );

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            SRC_SELECTOR
        );
    }

    function _receiveCoRefereeCarry(
        bytes32 _messageId,
        uint256 _amount
    )
        internal
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                srcPeer
            ),
            data: abi.encode(
                second,
                _amount,
                _coRefereeCarry(
                    second,
                    _amount
                )
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            router
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );
    }

    function _breakRegistry()
        internal
        returns (bytes memory realCode)
    {
        realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );
    }

    function _restoreRegistry(
        bytes memory _realCode
    )
        internal
    {
        vm.etch(
            address(registry),
            _realCode
        );
    }

    function _countTopicIn(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        view
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(diamond) && _logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _firstLogOf(
        Vm.Log[] memory _logs,
        bytes32 _topic,
        address _user
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (
                _logs[i].topics.length > 1
                    && _logs[i].topics[0] == _topic
                    && _logs[i].topics[1] == bytes32(uint256(uint160(_user)))
            ) {
                return i;
            }
        }

        return type(uint256).max;
    }

    // ---- park ----

    function test_transfer_parksTrackedSender()
        public
    {
        _stageReferee();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParked(
            referee
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            diamond.balanceOf(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );
    }

    function test_transferFrom_parksSender()
        public
    {
        _stageReferee();

        vm.prank(
            referee
        );

        diamond.approve(
            spender,
            10_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParked(
            referee
        );

        vm.prank(
            spender
        );

        diamond.transferFrom(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    function test_untrackedSender_isNotParked()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        _transferAs(
            sink,
            third,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );
    }

    function test_syncDisabled_parksNothing()
        public
    {
        _stageReferee();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );
    }

    // ---- drain ----

    function test_strangerDeposit_drainsParkedSender()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        usd.mint(
            third,
            ONE
        );

        vm.prank(
            third
        );

        usd.approve(
            address(diamond),
            ONE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSynced(
            referee,
            referrer,
            10_000 * ONE,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            third
        );

        UserFacet(address(diamond)).deposit(
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getAttributedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    function test_recipientQueueJoin_drainsParkedSenderBeforeEscrow()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            sink
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            10_000 * ONE,
            0
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                sink
            ),
            0
        );
    }

    function test_chainedTransfers_drainThePreviousSender()
        public
    {
        _stageReferee();

        _stageSecond();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        _transferAs(
            second,
            sink,
            7_000 * ONE
        );

        assertEq(
            _parked(),
            second
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                otherReferrer
            ),
            7_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                otherReferrer
            ),
            0
        );
    }

    function test_partialTransfers_drainAtExactBalanceEachTime()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        _transferAs(
            referee,
            sink,
            6_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            6_000 * ONE
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    function test_transferBackBeforeDrain_clampsAtPreReceiptBalance()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        _transferAs(
            sink,
            referee,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            diamond.balanceOf(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    function test_balanceRestoredBySupplyMint_drainReleasesWithoutClamp()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        AdminFacet(address(diamond)).mintSupply(
            referee,
            4_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );
    }

    // ---- park instant ----

    function test_drain_settlesReferrerBookToParkInstant()
        public
    {
        _stageReferee();

        vm.warp(
            BASE_TIME + 2 days
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parkedAt(),
            BASE_TIME + 2 days
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        usd.mint(
            third,
            ONE
        );

        vm.prank(
            third
        );

        usd.approve(
            address(diamond),
            ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortBookSettled(
            referrer,
            BASE_TIME,
            BASE_TIME + 2 days,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            third
        );

        UserFacet(address(diamond)).deposit(
            ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        _recorder().advanceBook(
            referrer,
            104
        );

        uint256 parkWeek = BASE_TIME / 1 weeks;

        assertEq(
            CohortWeeks._laneY1(
                _recorder().getCohortWeekCrumb(
                    referrer,
                    parkWeek
                )
            ),
            10_000 * ONE * 2 days
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                referrer,
                parkWeek + 1
            ),
            0
        );
    }

    function test_advanceBook_drainsParkedSender()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _recorder().advanceBook(
            referrer,
            1
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _parkedAt(),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            6_000 * ONE
        );
    }

    function test_parkedAt_clearsWithTheAddress()
        public
    {
        _stageReferee();

        vm.warp(
            BASE_TIME + 1 days
        );

        _transferAs(
            referee,
            sink,
            2_000 * ONE
        );

        assertEq(
            _parkedAt(),
            BASE_TIME + 1 days
        );

        vm.warp(
            BASE_TIME + 2 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortBookSettled(
            referrer,
            BASE_TIME,
            BASE_TIME + 1 days,
            0
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _divestWord(),
            0
        );

        vm.warp(
            BASE_TIME + 3 days
        );

        _transferAs(
            referee,
            sink,
            3_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _parkedAt(),
            BASE_TIME + 3 days
        );

        vm.warp(
            BASE_TIME + 4 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortBookSettled(
            referrer,
            BASE_TIME + 1 days,
            BASE_TIME + 3 days,
            0
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _divestWord(),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            5_000 * ONE
        );
    }

    // ---- lookup failure ----

    function test_lookupFailure_keepsParkedAndSkipsNewPark()
        public
    {
        _stageReferee();

        _stageSecond();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        bytes memory realCode = _breakRegistry();

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParkSkipped(
            second,
            referee
        );

        _transferAs(
            second,
            sink,
            7_000 * ONE
        );

        _restoreRegistry(
            realCode
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                otherReferrer
            ),
            7_000 * ONE
        );

        _pokeAs(
            third,
            second
        );

        assertEq(
            _recorder().getCohortScore(
                otherReferrer
            ),
            0
        );
    }

    function test_lookupFailure_sameSenderAgain_staysParkedSilently()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        bytes memory realCode = _breakRegistry();

        vm.recordLogs();

        _transferAs(
            referee,
            sink,
            6_000 * ONE
        );

        _restoreRegistry(
            realCode
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 skipped = keccak256(
            "CohortDivestParkSkipped(address,address)"
        );

        bytes32 parkedSig = keccak256(
            "CohortDivestParked(address)"
        );

        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != skipped
            );

            assertTrue(
                logs[i].topics[0] != parkedSig
            );
        }

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    function test_zeroRegistryPointerWhileArmed_deferredClamp()
        public
    {
        _stageReferee();

        _clearRegistryPointer();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        uint256 parkedAt = block.timestamp;

        assertEq(
            _parked(),
            referee
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerLookupFailed(
            referee
        );

        _transferAs(
            referee,
            sink,
            1_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _parkedAt(),
            parkedAt
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );
    }

    function test_zeroRegistryPointerWhileArmed_depositTracksAttributesNothing()
        public
    {
        _stageReferee();

        _clearRegistryPointer();

        usd.mint(
            referee,
            1_000 * ONE
        );

        vm.prank(
            referee
        );

        usd.approve(
            address(diamond),
            1_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerLookupFailed(
            referee
        );

        vm.prank(
            referee
        );

        UserFacet(address(diamond)).deposit(
            1_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            11_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );
    }

    // ---- router-initiated calls skip a parked third party ----

    function test_routerCaller_skipsDrain()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        _pokeAs(
            router,
            sink
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    // ---- the router-lane carry landing resolves the park of its own book ----

    function test_routerCaller_coRefereeBridgeIn_drainsSellerAtPark()
        public
    {
        uint256 stagedAt = _wireSourcePeer();

        _stageReferee();

        _depositWithReferralAs(
            second,
            5_000 * ONE,
            referrer
        );

        uint256 parkInstant = stagedAt + 1 days;

        vm.warp(
            parkInstant
        );

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        uint256 bridgeInstant = parkInstant + 1 days;

        vm.warp(
            bridgeInstant
        );

        _receiveCoRefereeCarry(
            bytes32(uint256(0xA3)),
            1_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _parkedAt(),
            0
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(
            referrer
        );

        assertEq(
            lastSettle,
            bridgeInstant
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                second
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            12_000 * ONE
        );

        (
            uint256 settledAt,
            ,
        ) = _recorder().getCohortSelfCrumb(
            referee
        );

        assertEq(
            settledAt,
            parkInstant
        );

        uint256 weekEnd = (stagedAt / 1 weeks + 1) * 1 weeks;

        vm.warp(
            weekEnd
        );

        _recorder().advanceBook(
            referrer,
            104
        );

        uint256 honest = 15_000 * ONE * (parkInstant - stagedAt)
            + 11_000 * ONE * (bridgeInstant - parkInstant)
            + 12_000 * ONE * (weekEnd - bridgeInstant);

        assertEq(
            CohortWeeks._laneY1(
                _recorder().getCohortWeekCrumb(
                    referrer,
                    stagedAt / 1 weeks
                )
            ),
            honest
        );
    }

    function test_routerCaller_selfTransferOfZero_revertsBeforeAnyPark()
        public
    {
        _stageReferee();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _transferAs(
            referee,
            referee,
            0
        );

        assertEq(
            _parked(),
            address(0)
        );
    }

    function test_routerCaller_selfTransferParkOfOneUnit_coRefereeBridgeInLosesNothing()
        public
    {
        uint256 stagedAt = _wireSourcePeer();

        _stageReferee();

        _depositWithReferralAs(
            second,
            5_000 * ONE,
            referrer
        );

        vm.warp(
            stagedAt + 1 days
        );

        _transferAs(
            referee,
            referee,
            1
        );

        assertEq(
            _parked(),
            referee
        );

        uint256 bridgeInstant = stagedAt + 2 days;

        vm.warp(
            bridgeInstant
        );

        _receiveCoRefereeCarry(
            bytes32(uint256(0xA4)),
            1_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            16_000 * ONE
        );

        uint256 weekEnd = (stagedAt / 1 weeks + 1) * 1 weeks;

        vm.warp(
            weekEnd
        );

        _recorder().advanceBook(
            referrer,
            104
        );

        uint256 full = 15_000 * ONE * (bridgeInstant - stagedAt)
            + 16_000 * ONE * (weekEnd - bridgeInstant);

        assertEq(
            CohortWeeks._laneY1(
                _recorder().getCohortWeekCrumb(
                    referrer,
                    stagedAt / 1 weeks
                )
            ),
            full
        );
    }

    function test_routerCaller_coRefereeBridgeInSellerLookupFails_settlesToDeliveryKeepsSlot()
        public
    {
        uint256 stagedAt = _wireSourcePeer();

        _stageReferee();

        _depositWithReferralAs(
            second,
            5_000 * ONE,
            referrer
        );

        uint256 parkInstant = stagedAt + 1 days;

        vm.warp(
            parkInstant
        );

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        uint256 bridgeInstant = parkInstant + 1 days;

        vm.warp(
            bridgeInstant
        );

        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSelector(
                ReferralRegistry.effectiveReferrerOf.selector,
                referee,
                address(diamond)
            ),
            ""
        );

        _receiveCoRefereeCarry(
            bytes32(uint256(0xA5)),
            1_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _parkedAt(),
            parkInstant
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(
            referrer
        );

        assertEq(
            lastSettle,
            bridgeInstant
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            16_000 * ONE
        );

        uint256 weekEnd = (stagedAt / 1 weeks + 1) * 1 weeks;

        vm.warp(
            weekEnd
        );

        _recorder().advanceBook(
            referrer,
            104
        );

        vm.clearMockedCalls();

        uint256 settled = 15_000 * ONE * (bridgeInstant - stagedAt)
            + 16_000 * ONE * (weekEnd - bridgeInstant);

        assertEq(
            CohortWeeks._laneY1(
                _recorder().getCohortWeekCrumb(
                    referrer,
                    stagedAt / 1 weeks
                )
            ),
            settled
        );
    }

    function test_routerCaller_spanExitRecipientBridgeIn_drainsCoRefereeParkBeforeItsSync()
        public
    {
        uint256 stagedAt = _wireSourcePeer();

        _stageReferee();

        _depositWithReferralAs(
            second,
            5_000 * ONE,
            referrer
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            stagedAt + 1 hours
        );

        _transferAs(
            second,
            sink,
            1_000 * ONE
        );

        vm.warp(
            stagedAt + 2 hours
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        uint256 parkInstant = stagedAt + 3 hours;

        vm.warp(
            parkInstant
        );

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        vm.warp(
            stagedAt + 1 days
        );

        vm.recordLogs();

        _receiveCoRefereeCarry(
            bytes32(uint256(0xA6)),
            1_000 * ONE
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 drainedAt = _firstLogOf(
            logs,
            CohortDivestDrained.selector,
            referee
        );

        uint256 syncedAt = _firstLogOf(
            logs,
            CohortContributionSynced.selector,
            second
        );

        assertLt(
            drainedAt,
            syncedAt
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                second
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            11_000 * ONE
        );
    }

    function test_routerCaller_spanExitRecipientLookupFails_keepsSlotAndReportsOnce()
        public
    {
        uint256 stagedAt = _wireSourcePeer();

        _stageReferee();

        _depositWithReferralAs(
            second,
            5_000 * ONE,
            referrer
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            stagedAt + 1 hours
        );

        _transferAs(
            second,
            sink,
            1_000 * ONE
        );

        vm.warp(
            stagedAt + 2 hours
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        uint256 parkInstant = stagedAt + 3 hours;

        vm.warp(
            parkInstant
        );

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        vm.warp(
            stagedAt + 1 days
        );

        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSelector(
                ReferralRegistry.effectiveReferrerOf.selector,
                second,
                address(diamond)
            ),
            ""
        );

        vm.recordLogs();

        _receiveCoRefereeCarry(
            bytes32(uint256(0xA7)),
            1_000 * ONE
        );

        vm.clearMockedCalls();

        assertEq(
            _countTopicIn(
                vm.getRecordedLogs(),
                keccak256(
                    "CohortReferrerLookupFailed(address)"
                )
            ),
            1
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _parkedAt(),
            parkInstant
        );

        assertEq(
            _recorder().getTrackedContribution(
                second
            ),
            5_000 * ONE
        );
    }

    function test_routerCaller_parkedUserResolvesAtParkInstant()
        public
    {
        _stageReferee();

        vm.warp(
            BASE_TIME + 2 days
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortBookSettled(
            referrer,
            BASE_TIME,
            BASE_TIME + 2 days,
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
            referee,
            referrer,
            10_000 * ONE,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _pokeAs(
            router,
            referee
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _parkedAt(),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );

        (
            uint256 settledAt,
            uint256 currentWeekSeconds,
            uint256 previousWeekSeconds
        ) = _recorder().getCohortSelfCrumb(
            referee
        );

        assertEq(
            settledAt,
            BASE_TIME + 2 days
        );

        assertEq(
            currentWeekSeconds,
            10_000 * ONE * 2 days
        );

        assertEq(
            previousWeekSeconds,
            0
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(
            referrer
        );

        assertEq(
            lastSettle,
            BASE_TIME + 2 days
        );

        _recorder().advanceBook(
            referrer,
            104
        );

        uint256 parkWeek = BASE_TIME / 1 weeks;

        assertEq(
            CohortWeeks._laneY1(
                _recorder().getCohortWeekCrumb(
                    referrer,
                    parkWeek
                )
            ),
            10_000 * ONE * 2 days
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                referrer,
                parkWeek + 1
            ),
            0
        );
    }

    function test_ccipReceive_parkedRecipient_resolvesAtParkInstantBeforeMint()
        public
    {
        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            SRC_SELECTOR,
            srcPeer,
            6
        );

        vm.warp(
            BASE_TIME + CROSS_CHAIN_PEER_DELAY
        );

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            SRC_SELECTOR
        );

        _stageReferee();

        uint256 parkInstant = BASE_TIME
            + CROSS_CHAIN_PEER_DELAY
            + 1 days;

        vm.warp(
            parkInstant
        );

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        vm.warp(
            BASE_TIME + 1 weeks + 1 days
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xD1)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                srcPeer
            ),
            data: abi.encode(
                referee,
                1_000 * ONE
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortBookSettled(
            referrer,
            BASE_TIME + CROSS_CHAIN_PEER_DELAY,
            parkInstant,
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
            referee,
            referrer,
            10_000 * ONE,
            6_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            router
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            diamond.balanceOf(
                referee
            ),
            7_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            6_000 * ONE
        );

        (
            uint256 settledAt,
            ,
        ) = _recorder().getCohortSelfCrumb(
            referee
        );

        assertEq(
            settledAt,
            parkInstant
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(
            referrer
        );

        assertEq(
            lastSettle,
            parkInstant
        );
    }

    function test_routerCaller_parkedUserLookupFailure_keepsSlot()
        public
    {
        _stageReferee();

        vm.warp(
            BASE_TIME + 2 days
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        bytes memory realCode = _breakRegistry();

        vm.recordLogs();

        _pokeAs(
            router,
            referee
        );

        _restoreRegistry(
            realCode
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopicIn(
                logs,
                keccak256(
                    "CohortReferrerLookupFailed(address)"
                )
            ),
            1
        );

        assertEq(
            _countTopicIn(
                logs,
                keccak256(
                    "CohortDivestDrained(address)"
                )
            ),
            0
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _parkedAt(),
            BASE_TIME + 2 days
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            10_000 * ONE
        );

        _pokeAs(
            router,
            referee
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(
                referrer
            ),
            0
        );
    }

    // ---- the zero caller never resolves an empty slot ----

    function test_syncRefereeZero_emptySlot_emitsNoDrain()
        public
    {
        _stageReferee();

        vm.recordLogs();

        _pokeAs(
            third,
            address(0)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopicIn(
                logs,
                keccak256(
                    "CohortDivestDrained(address)"
                )
            ),
            0
        );

        assertEq(
            _parked(),
            address(0)
        );
    }

    function test_rearm_emptySlot_emitsNoDrain()
        public
    {
        _stageReferee();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        vm.recordLogs();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopicIn(
                logs,
                keccak256(
                    "CohortDivestDrained(address)"
                )
            ),
            0
        );

        assertEq(
            _parked(),
            address(0)
        );
    }

    function test_syncRefereeZero_parkedThirdParty_drainsIt()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _pokeAs(
            third,
            address(0)
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(
                referee
            ),
            6_000 * ONE
        );
    }
}
