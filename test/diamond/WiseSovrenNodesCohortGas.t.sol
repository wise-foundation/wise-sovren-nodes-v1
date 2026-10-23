// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {TwoVaultCohortHarness} from "./utils/TwoVaultCohortHarness.sol";

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
 * @dev Records the wire `data` of the last `ccipSend` instead of
 * relaying it synchronously, so a test can rebuild the exact
 * `Any2EVMMessage` the DON would deliver and measure the destination
 * `ccipReceive` as its own cold call; a synchronous relay would fold
 * the delivery gas into the source-side send. `getFee` returns a flat
 * fee like the bridge suite's relaying mock.
 */
contract RecordingCcipRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

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
        uint64,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        lastData = _message.data;

        return bytes32(
            uint256(1)
        );
    }
}

/**
 * @dev Gas-bound proof for the cohort recorder's dormancy handling.
 * Measurements are gasleft() deltas around a raw `.call()` with the
 * calldata encoded and the caller pranked strictly before the window,
 * so nothing but the measured call's own execution lands inside it.
 * Every cell pins one claim from {CohortRecorderBase}'s @dev block:
 * the settle walk is hard-capped at `MAX_SETTLE_BOUNDARIES = 104`
 * steps so a transfer hook can never be blocked by an arbitrarily
 * dormant book (cells 1-2, cell 2 showing the closed-form gap tail is
 * O(1) regardless of how far beyond the cap the dormancy runs);
 * `advanceBook` lets a keeper pre-walk that cost out of the hook path
 * in bounded chunks (cells 3-4); and the common case (tracked
 * balance already equal to held balance) exits `_syncRefereeCohort`
 * on two reads before touching any book state (cell 5). Ceilings are
 * committed constants set ~25% above measured gas on this commit;
 * `GAS_TABLE|` rows are logged at -vv so a regression shows the exact
 * delta against the last committed number.
 *
 * Cross-machinery cells extend the table with BUDGET-derived
 * ceilings (fixed by external gas limits rather than measured plus
 * margin; their GAS_TABLE rows log the measured numbers for
 * recalibration). Cell 6 measures the worst-case armed bridge-carry
 * apply as the destination's cold `ccipReceive`: a two-diamond pair
 * wired through a recording router, the destination referrer's book
 * cap-dormant at delivery (105 weeks) so the apply's settle walks the
 * full 104-boundary cap before landing the carry. Its ceiling is
 * derived from the 5,000,000 CCIP delivery gas that the `arm()` of
 * `UpgradeReferralRegistry.s.sol` commits via `setBridgeGasLimit`,
 * the only arming entry (the earlier recorder upgrade script set
 * 1,000,000 there, which would strand such a delivery, and was
 * deleted for that reason); a delivery that
 * outgrows the budget strands the whole message, the mint with it,
 * until a manual re-execution with more gas. The ceiling is
 * 4,400,000, 88 percent of the budget, the other 600,000 being the
 * allowance for what this local measurement cannot see: the
 * cold-account and cold-code variance of a live destination (the
 * diamond, every routed facet, the token, the registry and the book
 * and ring slots first touched inside the delivery), measured by an
 * isolated run of cells 6, 6b and 6c in which every top-level call
 * is its own transaction, plus margin for live bytecode; the routed
 * fork scenario of the same dormant destination on every rollout
 * lane checks the live bytecode and, on the off-ramp lanes, success
 * under the real 5,000,000 receiver limit. Cell 6b runs the same
 * delivery to a recipient parked on the destination: the pre-mint
 * sync resolves the park at its own instant before the mint, which
 * splits the referrer's settle into the walk to the park and the
 * apply's walk from it, so the cell parks the recipient inside the
 * same 105-week dormancy and pins the two walks plus the clamp under
 * the same ceiling; a recipient parked for months on a vault that
 * saw no engine entrypoint, under a book idle for well over two
 * years, would need more walking than the budget holds, a state the
 * weekly flush cadence never leaves standing because every flush
 * settle drains the park slot. Cell 6c runs the cell 6 delivery with
 * a disarm span inside the destination book's dormant tail, past the
 * 104-boundary walk, so the landing settle splits the dormant gap
 * record around the span (a record on each side and the live parts
 * of the disarm and re-arm weeks as crumbs, the largest settle the
 * disarm rule can add to a delivery) under the same ceiling. Cell
 * 6d runs the cell 6 delivery with a co-referee of the landing book
 * parked inside the same dormancy: the carry apply resolves that
 * park at its own instant before it settles the book to the
 * delivery, which splits the settle walk at the park like cell 6b
 * and adds the co-referee's clamp, under the same ceiling. Cell
 * 6e runs cell 6d with a recipient whose own stake left inside a
 * disarm span: the pre-mint sync resolves the co-referee's park
 * before it clamps the recipient, so the delivery carries both
 * clamps and the split walk under the same ceiling. Cell 6f runs the
 * largest carry a bridge can hold, 104 weekly cohorts on the source (52
 * on each ring), onto the same cap-dormant destination: the landing
 * replants every pair at its own slot, first touches of the
 * destination's ring words included, under the same ceiling; it is
 * the worst delivery and the reason the armed budget is 5,000,000
 * (the vault's own maximum, below the per-message limit of every live
 * lane).
 * Landing-path rule: every change that adds gas on the bridge-in
 * landing path (the router-called pre-mint sync, the mint and the
 * carry apply), whether a storage read or write, a log, an external
 * call or a loop iteration, re-measures cells 6 to 6f, stays
 * under this ceiling and names any landing-path arm none of them
 * exercises (a first settle of a virgin destination book is one); a
 * change that cannot fit raises `setBridgeGasLimit` first
 * and derives the ceiling again. Cell 7 measures the registry's
 * permissionless `pokeMigration` single-vault worst case with an
 * empty park slot: the old referrer's rings populated across forty
 * weekly cohorts, then cap-dormant, so the flip migration settles the
 * full walk, scans both empty rings, takes the matured book and
 * lands it on the new referrer's mature lane; ceiling 3,500,000,
 * sized to the same dormant-full-walk budget band as cell 1's
 * 3,600,000 transfer-hook ceiling. Cell 8 measures the populated-ring
 * flip: 103 weekly cohorts under the old referrer with none matured
 * at the poke, so the sale walk takes every cohort out of both rings
 * and the landing replants each at its own slot in the new referrer's
 * rings; its ceiling is measured plus margin like cells 1 to 5. Cell
 * 9 measures the same poke with a third party parked on the vault
 * under a cap-dormant referrer: the flip entrypoint drains the parked
 * party first, settling its referrer's book to the park instant
 * before the mover's dormant old book settles, two capped walks in
 * one poke; its ceiling, 7,000,000, is the sender gas limit the
 * operator sets on every `pokeMigration`, and a dormant new referrer
 * would add a third walk, which the operator closes by advancing
 * dormant books first.
 */
contract WiseSovrenNodesCohortGasTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DIP_AMOUNT = 1 * 1e6;

    uint256 internal constant TRANSFER_HOOK_FULL_WALK_GAS_CEILING = 3_600_000;

    uint256 internal constant TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE = 150_000;

    uint256 internal constant TRANSFER_HOOK_PREWALKED_GAS_CEILING = 232_000;

    uint256 internal constant ADVANCE_BOOK_26_CHUNK_GAS_CEILING = 875_000;

    uint256 internal constant COMMON_TRANSFER_GAS_CEILING = 165_000;

    uint256 internal constant ARMED_DELIVERY_GAS_BUDGET = 5_000_000;

    uint256 internal constant ARMED_DELIVERY_ALLOWANCE = 600_000;

    uint256 internal constant CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING =
        ARMED_DELIVERY_GAS_BUDGET - ARMED_DELIVERY_ALLOWANCE;

    uint256 internal constant PARKED_SELF_PARK_WEEKS = 52;

    uint256 internal constant POKE_MIGRATION_PARKED_DRAIN_GAS_CEILING = 7_000_000;

    uint256 internal constant DIVEST_SLOT = 91;

    uint256 internal constant POKE_MIGRATION_FLIP_GAS_CEILING = 3_500_000;

    uint256 internal constant WEEKLY_DEPOSIT = 100 * 1e6;

    uint256 internal constant POPULATED_WEEKS = 40;

    uint256 internal constant POKE_MIGRATION_POPULATED_FLIP_GAS_CEILING = 1_450_000;

    uint256 internal constant MAX_PAIR_WEEKS = 103;

    uint256 internal constant BRIDGE_FEE = 0.01 ether;

    uint64 internal constant SRC_SELECTOR = 1111;

    uint64 internal constant DST_SELECTOR = 2222;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal refC = address(0xB3);
    address internal outsider = address(0xC1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    WiseSovrenNodesDiamond internal bridgeSrc;
    WiseSovrenNodesDiamond internal bridgeDst;
    MockUSD internal usdSrc;
    MockUSD internal usdDst;
    RecordingCcipRouter internal bridgeRouter;

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
            100_000_000 * 1e6
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

    function _measureTransfer(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeWithSelector(
            diamond.transfer.selector,
            _to,
            _amount
        );

        vm.prank(
            _from
        );

        uint256 g = gasleft();

        (bool ok, ) = address(diamond).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured transfer reverted"
        );
    }

    function _measureAdvanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeCall(
            CohortRecorderFacet.advanceBook,
            (_referrer, _maxBoundaries)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(diamond).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured advanceBook reverted"
        );
    }

    function _prewalk(
        address _referrer
    )
        internal
    {
        for (uint256 i; i < 4; ++i) {

            (
                ,
                ,
                ,
                uint256 lastSettle
            ) = _recorder().getCohortBook(_referrer);

            if (lastSettle / 1 weeks == block.timestamp / 1 weeks) {
                return;
            }

            _recorder().advanceBook(
                _referrer,
                104
            );
        }
    }

    function _logGas(
        string memory _label,
        uint256 _used,
        uint256 _ceiling
    )
        internal
        pure
    {
        console2.log(
            string.concat(
                "GAS_TABLE|",
                _label,
                "|used="
            ),
            _used
        );

        console2.log(
            string.concat(
                "GAS_TABLE|",
                _label,
                "|ceiling="
            ),
            _ceiling
        );
    }

    function _deployArmedBridgePair()
        internal
    {
        bridgeRouter = new RecordingCcipRouter();

        usdSrc = new MockUSD();

        usdDst = new MockUSD();

        bridgeSrc = _deployArmedBridgeVault(
            address(usdSrc)
        );

        bridgeDst = _deployArmedBridgeVault(
            address(usdDst)
        );

        _peerInstant(
            bridgeSrc,
            DST_SELECTOR,
            address(bridgeDst)
        );

        _peerInstant(
            bridgeDst,
            SRC_SELECTOR,
            address(bridgeSrc)
        );

        bridgeSrc.finalizeSetup();

        bridgeDst.finalizeSetup();

        AdminFacet(address(bridgeSrc)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            true
        );
    }

    function _deployArmedBridgeVault(
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

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            d
        );

        BridgeFacet(address(d)).setCcipRouter(
            address(bridgeRouter)
        );
    }

    function _peerInstant(
        WiseSovrenNodesDiamond _vault,
        uint64 _selector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _selector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _selector
        );
    }

    function _depositWithReferralOn(
        WiseSovrenNodesDiamond _vault,
        MockUSD _usd,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usd.approve(
            address(_vault),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_vault)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _measureCcipReceive(
        bytes memory _payload
    )
        internal
        returns (uint256 used)
    {
        vm.prank(
            address(bridgeRouter)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(bridgeDst).call(_payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured ccipReceive reverted"
        );
    }

    function _measurePokeMigration(
        address _user
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeCall(
            ReferralRegistry.pokeMigration,
            (_user)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(registry).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured pokeMigration reverted"
        );
    }

    function _parkedOn(
        address _diamond
    )
        internal
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    vm.load(
                        _diamond,
                        bytes32(DIVEST_SLOT)
                    )
                )
            )
        );
    }

    // ---- cells ----

    function test_gas_transferHook_dormant104Weeks_fullWalk()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_dormant104Weeks_fullWalk",
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING
        );

        assertLe(
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING,
            "gas: dormant 104-boundary full settle walk exceeded ceiling"
        );
    }

    function test_gas_transferHook_dormant156Weeks_flatBeyondCap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 usedAtCap = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _depositWithReferralAs(
            user2,
            DEPOSIT,
            refB
        );

        vm.warp(
            block.timestamp + 156 weeks
        );

        _transferAs(
            user2,
            outsider,
            DIP_AMOUNT
        );

        uint256 usedBeyondCap = _measureTransfer(
            user2,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_dormant156Weeks_flatBeyondCap",
            usedBeyondCap,
            usedAtCap + TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE
        );

        assertLe(
            usedBeyondCap,
            usedAtCap + TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE,
            "gas: dormancy beyond MAX_SETTLE_BOUNDARIES not flat"
        );
    }

    function test_gas_transferHook_afterAdvanceBookPrewalk_cheap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _prewalk(
            refA
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_afterAdvanceBookPrewalk_cheap",
            used,
            TRANSFER_HOOK_PREWALKED_GAS_CEILING
        );

        assertLe(
            used,
            TRANSFER_HOOK_PREWALKED_GAS_CEILING,
            "gas: pre-walked dormant book transfer exceeded ceiling"
        );
    }

    function test_gas_advanceBook_26BoundaryChunk()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        uint256 used = _measureAdvanceBook(
            refA,
            26
        );

        _logGas(
            "advanceBook_26BoundaryChunk",
            used,
            ADVANCE_BOOK_26_CHUNK_GAS_CEILING
        );

        assertLe(
            used,
            ADVANCE_BOOK_26_CHUNK_GAS_CEILING,
            "gas: 26-boundary advanceBook chunk exceeded ceiling"
        );
    }

    function test_gas_advanceBook_fullCap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        uint256 used = _measureAdvanceBook(
            refA,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        _logGas(
            "advanceBook_fullCap",
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING
        );

        assertLe(
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING,
            "gas: full-cap advanceBook exceeded ceiling"
        );
    }

    function test_gas_commonTransfer_noDeficitCheap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "commonTransfer_noDeficitCheap",
            used,
            COMMON_TRANSFER_GAS_CEILING
        );

        assertLe(
            used,
            COMMON_TRANSFER_GAS_CEILING,
            "gas: common no-deficit transfer exceeded ceiling"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_dormantDestination()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA11)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_dormantDestination",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed dormant-destination carry apply exceeded ceiling"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user1
            ),
            DEPOSIT,
            "carry was not applied on the destination"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            mature,
            2 * DEPOSIT,
            "carried book credit did not land on the destination referrer"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_parkedSelfRecipient()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user1,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + PARKED_SELF_PARK_WEEKS * 1 weeks
        );

        vm.prank(
            user1
        );

        bridgeDst.transfer(
            outsider,
            DIP_AMOUNT
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            user1,
            "the recipient must sit parked on the destination before the delivery"
        );

        vm.warp(
            block.timestamp + (105 - PARKED_SELF_PARK_WEEKS) * 1 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA12)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_parkedSelfRecipient",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed parked-recipient carry apply exceeded ceiling"
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            address(0),
            "the delivery must resolve the parked recipient"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user1
            ),
            2 * DEPOSIT - DIP_AMOUNT,
            "the park was not clamped at its instant before the carry landed"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            mature,
            3 * DEPOSIT - DIP_AMOUNT,
            "the destination book must hold both deposits less the dip plus the carried credit"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_disarmSpanInDormantTail()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks + 2 days
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 106 weeks + 2 days
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            BASE_TIME + 108 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA13)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_disarmSpanInDormantTail",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed carry apply over a split dormant tail exceeded ceiling"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user1
            ),
            DEPOSIT,
            "carry was not applied on the destination"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            mature,
            2 * DEPOSIT,
            "carried book credit did not land on the destination referrer"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getCohortGapLogLength(
                refA
            ),
            2,
            "the dormant tail must be split around the disarm span"
        );

        assertEq(
            CohortWeeks._laneM(
                CohortRecorderFacet(address(bridgeDst)).getCohortWeekCrumb(
                    refA,
                    3_105
                )
            ),
            DEPOSIT * 49 hours,
            "the disarm week must count only up to the disarm instant"
        );

        assertEq(
            CohortWeeks._laneM(
                CohortRecorderFacet(address(bridgeDst)).getCohortWeekCrumb(
                    refA,
                    3_106
                )
            ),
            DEPOSIT * (1 weeks - 49 hours),
            "the re-arm week must count only from the re-arm instant"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_parkedCoReferee()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + PARKED_SELF_PARK_WEEKS * 1 weeks
        );

        vm.prank(
            user2
        );

        bridgeDst.transfer(
            outsider,
            DIP_AMOUNT
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            user2,
            "the co-referee must sit parked on the destination before the delivery"
        );

        vm.warp(
            block.timestamp + (105 - PARKED_SELF_PARK_WEEKS) * 1 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA14)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_parkedCoReferee",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed parked co-referee carry apply exceeded ceiling"
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            address(0),
            "the landing must resolve the park of its own book"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user2
            ),
            DEPOSIT - DIP_AMOUNT,
            "the co-referee was not clamped at its park instant"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            mature,
            2 * DEPOSIT - DIP_AMOUNT,
            "the destination book must hold the co-referee less the dip plus the carried credit"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_spanExitRecipientParkedCoReferee()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user1,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            false
        );

        vm.prank(
            user1
        );

        bridgeDst.transfer(
            outsider,
            DIP_AMOUNT
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            true
        );

        vm.warp(
            block.timestamp + PARKED_SELF_PARK_WEEKS * 1 weeks
        );

        vm.prank(
            user2
        );

        bridgeDst.transfer(
            outsider,
            DIP_AMOUNT
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            user2,
            "the co-referee must sit parked on the destination before the delivery"
        );

        vm.warp(
            block.timestamp + (105 - PARKED_SELF_PARK_WEEKS) * 1 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA15)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_spanExitRecipientParkedCoReferee",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed span-exit recipient carry apply exceeded ceiling"
        );

        assertEq(
            _parkedOn(
                address(bridgeDst)
            ),
            address(0),
            "the landing must resolve the park of its own book"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user2
            ),
            DEPOSIT - DIP_AMOUNT,
            "the co-referee was not clamped at its park instant"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user1
            ),
            2 * DEPOSIT - DIP_AMOUNT,
            "the span exit was not clamped before the carry landed"
        );

        assertEq(
            mature,
            3 * DEPOSIT - 2 * DIP_AMOUNT,
            "the destination book must hold both deposits less both dips plus the carried credit"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_fullPairBook()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        for (uint256 i; i < CohortWeeks.MAX_CARRY_PAIRS; ++i) {

            if (i > 0) {
                vm.warp(
                    block.timestamp + 1 weeks
                );
            }

            _depositWithReferralOn(
                bridgeSrc,
                usdSrc,
                user1,
                WEEKLY_DEPOSIT,
                refA
            );
        }

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            CohortWeeks.MAX_CARRY_PAIRS * WEEKLY_DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA16)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_fullPairBook",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed full pair book carry apply exceeded ceiling"
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            year1,
            52 * WEEKLY_DEPOSIT,
            "year-1 pairs did not land on the destination referrer"
        );

        assertEq(
            year2,
            52 * WEEKLY_DEPOSIT,
            "year-2 pairs did not land on the destination referrer"
        );

        assertEq(
            mature,
            DEPOSIT,
            "the dormant destination credit did not mature"
        );
    }

    function test_gas_ccipReceive_armedCarryApply_fullPairBookIntoPopulatedDormantDestination()
        public
    {
        _deployArmedBridgePair();

        for (uint256 i; i < 52; ++i) {

            _depositWithReferralOn(
                bridgeDst,
                usdDst,
                user2,
                WEEKLY_DEPOSIT,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        for (uint256 i; i < CohortWeeks.MAX_CARRY_PAIRS; ++i) {

            if (i > 0) {
                vm.warp(
                    block.timestamp + 1 weeks
                );
            }

            _depositWithReferralOn(
                bridgeSrc,
                usdSrc,
                user1,
                WEEKLY_DEPOSIT,
                refA
            );
        }

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            CohortWeeks.MAX_CARRY_PAIRS * WEEKLY_DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA17)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_fullPairBookIntoPopulatedDormantDestination",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed full pair book into a populated dormant destination exceeded ceiling"
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            year1,
            52 * WEEKLY_DEPOSIT,
            "year-1 pairs did not land on the destination referrer"
        );

        assertEq(
            year2,
            52 * WEEKLY_DEPOSIT,
            "year-2 pairs did not land on the destination referrer"
        );

        assertEq(
            mature,
            52 * WEEKLY_DEPOSIT,
            "the destination's own populated rings did not mature"
        );
    }

    function test_gas_pokeMigration_flipAfterDormantPopulatedRings()
        public
    {
        for (uint256 i; i < POPULATED_WEEKS; ++i) {

            _depositWithReferralAs(
                user1,
                WEEKLY_DEPOSIT,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        vm.warp(
            block.timestamp + 105 weeks
        );

        uint256 loweredAssignedAt = BASE_TIME - 1 days;

        vm.prank(
            address(diamond)
        );

        registry.mergeReferrer(
            user1,
            refB,
            loweredAssignedAt,
            0
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            refA,
            "flip marker missing before the poke"
        );

        uint256 used = _measurePokeMigration(
            user1
        );

        _logGas(
            "pokeMigration_flipAfterDormantPopulatedRings",
            used,
            POKE_MIGRATION_FLIP_GAS_CEILING
        );

        assertLe(
            used,
            POKE_MIGRATION_FLIP_GAS_CEILING,
            "gas: dormant flip migration exceeded ceiling"
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            address(0),
            "flip migration was deferred instead of applied"
        );

        (
            ,
            ,
            uint256 mature,
        ) = _recorder().getCohortBook(
            refB
        );

        assertEq(
            mature,
            POPULATED_WEEKS * WEEKLY_DEPOSIT,
            "migrated mature credit mismatch on the new referrer"
        );
    }

    function test_gas_pokeMigration_flipPopulatedRings_maxPairs()
        public
    {
        for (uint256 i; i < MAX_PAIR_WEEKS; ++i) {

            _depositWithReferralAs(
                user1,
                WEEKLY_DEPOSIT,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        uint256 loweredAssignedAt = BASE_TIME - 1 days;

        vm.prank(
            address(diamond)
        );

        registry.mergeReferrer(
            user1,
            refB,
            loweredAssignedAt,
            0
        );

        uint256 used = _measurePokeMigration(
            user1
        );

        _logGas(
            "pokeMigration_flipPopulatedRings_maxPairs",
            used,
            POKE_MIGRATION_POPULATED_FLIP_GAS_CEILING
        );

        assertLe(
            used,
            POKE_MIGRATION_POPULATED_FLIP_GAS_CEILING,
            "gas: populated-ring flip migration exceeded ceiling"
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
        ) = _recorder().getCohortBook(
            refB
        );

        assertEq(
            year1,
            51 * WEEKLY_DEPOSIT,
            "year-1 pairs did not land on the new referrer"
        );

        assertEq(
            year2,
            52 * WEEKLY_DEPOSIT,
            "year-2 pairs did not land on the new referrer"
        );

        assertEq(
            mature,
            0,
            "a cohort matured before the poke"
        );
    }

    function test_gas_pokeMigration_flipAfterParkedThirdPartyDrain()
        public
    {
        _depositWithReferralAs(
            user2,
            DEPOSIT,
            refB
        );

        for (uint256 i; i < POPULATED_WEEKS; ++i) {

            _depositWithReferralAs(
                user1,
                WEEKLY_DEPOSIT,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        vm.warp(
            block.timestamp + 105 weeks
        );

        _transferAs(
            user2,
            outsider,
            DIP_AMOUNT
        );

        assertEq(
            _parkedOn(
                address(diamond)
            ),
            user2,
            "the third party must sit parked before the poke"
        );

        uint256 loweredAssignedAt = BASE_TIME - 1 days;

        vm.prank(
            address(diamond)
        );

        registry.mergeReferrer(
            user1,
            refC,
            loweredAssignedAt,
            0
        );

        uint256 used = _measurePokeMigration(
            user1
        );

        _logGas(
            "pokeMigration_flipAfterParkedThirdPartyDrain",
            used,
            POKE_MIGRATION_PARKED_DRAIN_GAS_CEILING
        );

        assertLe(
            used,
            POKE_MIGRATION_PARKED_DRAIN_GAS_CEILING,
            "gas: flip with a parked third party under a dormant referrer exceeded ceiling"
        );

        assertEq(
            _parkedOn(
                address(diamond)
            ),
            address(0),
            "the flip entrypoint must drain the parked third party"
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            address(0),
            "flip migration was deferred instead of applied"
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT - DIP_AMOUNT,
            "the drained third party was not clamped"
        );

        (
            ,
            ,
            uint256 mature,
        ) = _recorder().getCohortBook(
            refC
        );

        assertEq(
            mature,
            POPULATED_WEEKS * WEEKLY_DEPOSIT,
            "migrated mature credit mismatch on the new referrer"
        );
    }
}

/**
 * @dev Worst-case same-chain move walk gas pin over two real
 * diamonds from {TwoVaultCohortHarness}: all 104 ring slots of the
 * referrer's book populated by one referee, then a full exit to the
 * peer vault. The pin lives here rather than beside the move
 * round-trip scenarios because plain coverage instrumentation
 * inflates the walk past its budget while the optimized build keeps
 * it under; the gas suites are excluded from the coverage run.
 */
contract WiseSovrenNodesCohortMoveGasTest is TwoVaultCohortHarness {

    uint256 internal constant WORST_CASE_MOVE_GAS_BUDGET = 3_000_000;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    function setUp()
        public
    {
        _deployCohortPair();

        _armBoth();
    }

    function test_moveGas_worstCase104Pairs_underBudget()
        public
    {
        for (uint256 i; i < 104; ++i) {

            _depositWithReferralOn(
                vaultA,
                user1,
                1_000 * 1e6,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        _recorderOf(vaultA).syncReferee(
            user1
        );

        uint256 balance = vaultA.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 gasBefore = gasleft();

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultB),
            balance
        );

        uint256 gasUsed = gasBefore - gasleft();

        assertLt(
            gasUsed,
            WORST_CASE_MOVE_GAS_BUDGET
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
            104_000 * 1e6
        );
    }
}
