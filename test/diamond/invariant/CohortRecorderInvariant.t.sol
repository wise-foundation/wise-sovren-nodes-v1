// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";

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
 * @dev Drives the cohort recorder through bounded random deposit /
 * transfer / poke / advanceBook actions across a closed actor set: two
 * referees (A1, A2) permanently pinned to REF before this handler is
 * ever registered, one unreferred depositor (U) whose tracked
 * contribution is tracked but never flows into REF's book, and one pure
 * sink (OUTSIDER) that only ever receives. Three warp granularities
 * (hours, weeks, dormant 26-110 weeks) push the sequence across both
 * the 52-week and 104-week graduation boundaries and into the
 * closed-form gap tail beyond `MAX_SETTLE_BOUNDARIES`. `transferOut`
 * and `transferBetween` run WITHOUT try/catch by design: a transfer
 * hook revert must fail the run, because the recorder's never-block
 * guarantee means a transfer should never revert on
 * recorder grounds; a revert here is a real bug, not noise to swallow.
 */
contract CohortRecorderHandler is Test {

    WiseSovrenNodesDiamond internal immutable diamond;
    MockUSD internal immutable usd;
    CohortRecorderFacet internal immutable recorder;

    address internal immutable a1;
    address internal immutable a2;
    address internal immutable ref;
    address internal immutable u;
    address internal immutable outsider;

    uint256 public ghostStartWeek;
    uint256 public ghostNextWeek;

    mapping(uint256 => uint256) public ghostCrumb;

    constructor(
        WiseSovrenNodesDiamond _diamond,
        MockUSD _usd,
        address[5] memory _actors
    ) {
        diamond = _diamond;
        usd = _usd;
        recorder = CohortRecorderFacet(address(_diamond));

        a1 = _actors[0];
        a2 = _actors[1];
        ref = _actors[2];
        u = _actors[3];
        outsider = _actors[4];

        ghostStartWeek = block.timestamp / 1 weeks;
        ghostNextWeek = ghostStartWeek;
    }

    modifier captureGhost() {
        _captureFinalizedCrumbs();
        _;
        _captureFinalizedCrumbs();
    }

    function _captureFinalizedCrumbs()
        internal
    {
        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = recorder.getCohortBook(
            ref
        );

        if (lastSettle == 0) {
            return;
        }

        uint256 finalizedUpTo = lastSettle / 1 weeks;

        while (ghostNextWeek < finalizedUpTo) {

            ghostCrumb[ghostNextWeek] = recorder.getCohortWeekCrumb(
                ref,
                ghostNextWeek
            );

            ++ghostNextWeek;
        }
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

    function depositReferred(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            actor
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            amount,
            ref
        );
    }

    function depositUnreferred(
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usd.mint(
            u,
            amount
        );

        vm.prank(
            u
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            u
        );

        UserFacet(address(diamond)).deposit(
            amount
        );
    }

    function depositPlainReferee(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _refereeActor(
            _actorSeed
        );

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            5_000 * 1e6
        );

        usd.mint(
            actor,
            amount
        );

        vm.prank(
            actor
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            actor
        );

        UserFacet(address(diamond)).deposit(
            amount
        );
    }

    function transferOut(
        uint256 _actorSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        uint256 bal = diamond.balanceOf(
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

        vm.prank(
            actor
        );

        diamond.transfer(
            outsider,
            amount
        );
    }

    function transferBetween(
        uint256 _aSeed,
        uint256 _bSeed,
        uint256 _amountSeed
    )
        external
        captureGhost
    {
        address from = _closedActor(
            _aSeed
        );

        address to = _closedActor(
            _bSeed
        );

        if (from == to) {
            return;
        }

        uint256 bal = diamond.balanceOf(
            from
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            from
        );

        diamond.transfer(
            to,
            amount
        );
    }

    function poke(
        uint256 _actorSeed
    )
        external
        captureGhost
    {
        address actor = _closedActor(
            _actorSeed
        );

        vm.prank(
            actor
        );

        recorder.syncReferee(
            actor
        );
    }

    function advance(
        uint256 _chunkSeed
    )
        external
        captureGhost
    {
        uint256 chunk = bound(
            _chunkSeed,
            1,
            104
        );

        recorder.advanceBook(
            ref,
            chunk
        );
    }

    function warpHours(
        uint256 _seed
    )
        external
        captureGhost
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
        captureGhost
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
        captureGhost
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                26 weeks,
                110 weeks
            )
        );
    }
}

/**
 * @dev Stateful-fuzz invariants for the cohort recorder engine
 * ({CohortRecorderBase} / {CohortHookFacet}): REC1 pins the three-way
 * equality (sum of REF's referees' tracked contribution == REF's book
 * total == REF's score) that {WiseSovrenNodesCohortCoreTest} checks
 * unit-by-unit as I1; REC2 pins the ring-to-book lane identity (I2);
 * REC3 is new to this suite: once a cohort week closes (its index
 * falls below `lastSettle / 1 weeks`), its crumb word can never be
 * written to again by construction (the settle cursor only moves
 * forward), and this invariant re-verifies every previously finalized
 * crumb against a ghost snapshot taken in {CohortRecorderHandler} the
 * moment it closed. Deposits are always routed through REF for A1/A2
 * so the recorder never sees a stray referrer, keeping REC1/REC2 scoped
 * to a single book.
 */
contract CohortRecorderInvariantTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant PIN_DEPOSIT = 1_000 * 1e6;

    address internal constant A1 = address(0xA1);
    address internal constant A2 = address(0xA2);
    address internal constant REF = address(0xB1);
    address internal constant U = address(0xA3);
    address internal constant OUTSIDER = address(0xC1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    CohortRecorderHandler internal handler;

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

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        _depositWithReferralAs(
            A1,
            PIN_DEPOSIT,
            REF
        );

        _depositWithReferralAs(
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

        handler = new CohortRecorderHandler(
            diamond,
            usd,
            actors
        );

        targetContract(
            address(handler)
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

    // ---- invariants ----

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REC1_attributedSumEqualsBookTotalEqualsScore()
        public
        view
    {
        uint256 attributedSum = _recorder().getAttributedContribution(A1)
            + _recorder().getAttributedContribution(A2);

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = _recorder().getCohortBook(REF);

        assertEq(
            attributedSum,
            year1 + year2 + mature,
            "REC1: attributed sum != book total"
        );

        assertEq(
            _recorder().getCohortScore(
                REF
            ),
            year1 + year2 + mature,
            "REC1: score != book total"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REC5_onlyParkedSenderHoldsBelowTracked()
        public
        view
    {
        address parked = address(
            uint160(
                uint256(
                    vm.load(
                        address(diamond),
                        bytes32(uint256(91))
                    )
                )
            )
        );

        _assertCoveredUnlessParked(
            A1,
            parked
        );

        _assertCoveredUnlessParked(
            A2,
            parked
        );

        _assertCoveredUnlessParked(
            U,
            parked
        );
    }

    function _assertCoveredUnlessParked(
        address _actor,
        address _parked
    )
        internal
        view
    {
        if (_actor == _parked) {
            return;
        }

        assertGe(
            diamond.balanceOf(
                _actor
            ),
            _recorder().getTrackedContribution(
                _actor
            ),
            "REC5: an unparked actor holds below tracked"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REC4_attributedNeverExceedsTracked()
        public
        view
    {
        assertLe(
            _recorder().getAttributedContribution(
                A1
            ),
            _recorder().getTrackedContribution(
                A1
            ),
            "REC4-A1: attributed above tracked"
        );

        assertLe(
            _recorder().getAttributedContribution(
                A2
            ),
            _recorder().getTrackedContribution(
                A2
            ),
            "REC4-A2: attributed above tracked"
        );

        assertEq(
            _recorder().getAttributedContribution(
                U
            ),
            0,
            "REC4-U: unreferred actor attributed"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REC2_ringSumsEqualBookLanes()
        public
        view
    {
        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(REF);

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

        ) = _recorder().getCohortBook(REF);

        assertEq(
            ring1Sum,
            year1,
            "REC2: ring1 sum != bookY1"
        );

        assertEq(
            ring2Sum,
            year2,
            "REC2: ring2 sum != bookY2"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REC3_finalizedCrumbsImmutable()
        public
        view
    {
        uint256 start = handler.ghostStartWeek();

        uint256 next = handler.ghostNextWeek();

        for (uint256 w = start; w < next; ++w) {
            assertEq(
                _recorder().getCohortWeekCrumb(
                    REF,
                    w
                ),
                handler.ghostCrumb(
                    w
                ),
                "REC3: finalized week crumb mutated"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_REG1_registryReferrerImmutable()
        public
        view
    {
        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                A1
            ),
            REF,
            "REG1: A1 referrer changed"
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                A2
            ),
            REF,
            "REG1: A2 referrer changed"
        );
    }
}
