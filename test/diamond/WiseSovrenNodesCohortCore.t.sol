// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

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
 * @dev Core suite for the cohort book: week-quantized cohort
 * graduation across the year-1 and year-2 boundaries asserted on book
 * and ring state with exact expected integers, newest-first book
 * reduction and its ring1 -> ring2 -> mature spill, `advanceBook`
 * pagination semantics, the settle-before-credit ordering pinned by an
 * exact crumb word, and a randomized seed-walk fuzz asserting the I1
 * three-way equality (sum of referee contributions == bookY1 + bookY2
 * + bookM == score) after every operation. Slot arithmetic under
 * test: the cohort deposited in week w lives in ring slot w mod 52
 * and is rotated at boundary week w + 52 (same slot index; the
 * aliasing is the mechanism, not an accident).
 */
contract WiseSovrenNodesCohortCoreTest is DiamondTestHarness {

    event CohortBookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
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

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);
    address internal poker = address(0xD1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

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

    function _poke(
        address _user
    )
        internal
    {
        vm.prank(
            poker
        );

        _recorder().syncReferee(
            _user
        );
    }

    function _book(
        address _referrer
    )
        internal
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature
        )
    {
        (
            year1,
            year2,
            mature,

        ) = _recorder().getCohortBook(_referrer);
    }

    function _assertBookConsistent(
        address _referrer,
        address[] memory _referees
    )
        internal
        view
    {
        uint256 trackedSum;

        for (uint256 i; i < _referees.length; ++i) {
            trackedSum += _recorder().getTrackedContribution(
                _referees[i]
            );
        }

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(_referrer);

        assertEq(
            trackedSum,
            year1 + year2 + mature,
            "I1: tracked sum != book total"
        );

        assertEq(
            _recorder().getCohortScore(
                _referrer
            ),
            year1 + year2 + mature,
            "I1: score != book total"
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(_referrer);

        uint256 ring1Sum;

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {
            ring1Sum += uint256(ring1[i]);
            ring2Sum += uint256(ring2[i]);
        }

        assertEq(
            ring1Sum,
            year1,
            "I2: ring1 sum != bookY1"
        );

        assertEq(
            ring2Sum,
            year2,
            "I2: ring2 sum != bookY2"
        );
    }

    // ---- graduation ----

    function test_graduation_movesCohortToYear2AtBoundary()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 52 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            year1,
            0
        );

        assertEq(
            year2,
            5_000 * 1e6
        );

        assertEq(
            mature,
            0
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[BASE_SLOT]),
            0
        );

        assertEq(
            uint256(ring2[BASE_SLOT]),
            5_000 * 1e6
        );
    }

    function test_graduation_movesCohortToMatureAtSecondBoundary()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            year1,
            0
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            5_000 * 1e6
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[BASE_SLOT]),
            0
        );

        assertEq(
            uint256(ring2[BASE_SLOT]),
            0
        );
    }

    function test_graduation_totalPreservedAcrossBothBoundaries()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        address[] memory referees = new address[](1);

        referees[0] = user1;

        vm.warp(
            BASE_TIME + 52 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        _assertBookConsistent(
            refA,
            referees
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        _assertBookConsistent(
            refA,
            referees
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            5_000 * 1e6
        );
    }

    // ---- advanceBook pagination ----

    function test_advanceBook_walksExactlyRequestedBoundaries()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 10 weeks
        );

        _recorder().advanceBook(
            refA,
            4
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            lastSettle,
            3_004 weeks
        );
    }

    function test_advanceBook_secondCallCompletesTheWalk()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 10 weeks
        );

        _recorder().advanceBook(
            refA,
            4
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            lastSettle,
            3_010 weeks
        );
    }

    function test_advanceBook_virginBookIsNoop()
        public
    {
        _recorder().advanceBook(
            refA,
            104
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            lastSettle,
            0
        );
    }

    function test_advanceBook_currentBookIsNoop()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            lastSettle,
            BASE_TIME
        );
    }

    function test_advanceBook_permissionless()
        public
    {
        _depositWithReferralAs(
            user1,
            5_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        vm.prank(
            poker
        );

        _recorder().advanceBook(
            refA,
            104
        );

        (
            ,
            ,
            ,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            lastSettle,
            3_002 weeks
        );
    }

    // ---- newest-first reduction ----

    function test_reduction_consumesNewestSlotFirst()
        public
    {
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

        _transferAs(
            user1,
            outsider,
            1_000 * 1e6
        );

        _poke(
            user1
        );

        (
            uint64[52] memory ring1,

        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[(3_002) % 52]),
            1_000 * 1e6
        );

        assertEq(
            uint256(ring1[BASE_SLOT]),
            3_000 * 1e6
        );

        (
            uint256 year1,
            ,

        ) = _book(refA);

        assertEq(
            year1,
            4_000 * 1e6
        );
    }

    function test_reduction_spillsRing1ThenRing2()
        public
    {
        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 52 weeks + 1 hours
        );

        _depositWithReferralAs(
            user1,
            2_000 * 1e6,
            refA
        );

        (
            uint256 year1Before,
            uint256 year2Before,

        ) = _book(refA);

        assertEq(
            year1Before,
            2_000 * 1e6
        );

        assertEq(
            year2Before,
            1_000 * 1e6
        );

        _transferAs(
            user1,
            outsider,
            2_500 * 1e6
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
            2_500 * 1e6,
            2_000 * 1e6,
            500 * 1e6,
            0
        );

        _poke(
            user1
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            year1,
            0
        );

        assertEq(
            year2,
            500 * 1e6
        );

        assertEq(
            mature,
            0
        );
    }

    function test_reduction_spillsIntoMature()
        public
    {
        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _depositWithReferralAs(
            user1,
            500 * 1e6,
            refA
        );

        (
            uint256 year1Before,
            uint256 year2Before,
            uint256 matureBefore
        ) = _book(refA);

        assertEq(
            year1Before,
            500 * 1e6
        );

        assertEq(
            year2Before,
            0
        );

        assertEq(
            matureBefore,
            1_000 * 1e6
        );

        _transferAs(
            user1,
            outsider,
            1_200 * 1e6
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
            1_200 * 1e6,
            500 * 1e6,
            0,
            700 * 1e6
        );

        _poke(
            user1
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature
        ) = _book(refA);

        assertEq(
            year1,
            0
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            300 * 1e6
        );
    }

    // ---- settle ordering ----

    function test_settle_beforeCredit_elapsedWindowAccruesAtOldBalance()
        public
    {
        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        uint256 fullWeekCrumb = _recorder().getCohortWeekCrumb(
            refA,
            3_001
        );

        assertEq(
            fullWeekCrumb,
            CohortWeeks.CRUMB_WRITTEN_BIT | (1_000 * 1e6 * 1 weeks)
        );
    }

    function test_settle_emptyBookAcrossWeeksWritesNoCrumbs()
        public
    {
        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        _transferAs(
            user1,
            outsider,
            1_000 * 1e6
        );

        _poke(
            user1
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_001
            ),
            0
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_002
            ),
            0
        );
    }

    // ---- randomized seed walk (I1 + I2 after every op) ----

    function testFuzz_seedWalk_invariantHoldsAfterEveryOp(
        uint256 _seed
    )
        public
    {
        address[] memory referees = new address[](2);

        referees[0] = user1;

        referees[1] = user2;

        _depositWithReferralAs(
            user1,
            1_000 * 1e6,
            refA
        );

        _depositWithReferralAs(
            user2,
            1_000 * 1e6,
            refA
        );

        uint256 state = _seed;

        for (uint256 i; i < 24; ++i) {

            state = uint256(
                keccak256(
                    abi.encode(
                        state,
                        i
                    )
                )
            );

            uint256 op = state % 5;

            address actor = state % 2 == 0
                ? user1
                : user2;

            if (op == 0) {

                _depositWithReferralAs(
                    actor,
                    bound(
                        state >> 8,
                        50 * 1e6,
                        5_000 * 1e6
                    ),
                    refA
                );

            } else if (op == 1) {

                uint256 held = diamond.balanceOf(
                    actor
                );

                if (held > 1) {
                    _transferAs(
                        actor,
                        outsider,
                        bound(
                            state >> 8,
                            1,
                            held / 2
                        )
                    );
                }

            } else if (op == 2) {

                _poke(
                    actor
                );

            } else if (op == 3) {

                vm.warp(
                    block.timestamp + bound(
                        state >> 8,
                        1 hours,
                        30 weeks
                    )
                );

            } else {

                _recorder().advanceBook(
                    refA,
                    bound(
                        state >> 8,
                        1,
                        104
                    )
                );
            }

            _poke(
                user1
            );

            _poke(
                user2
            );

            _assertBookConsistent(
                refA,
                referees
            );
        }
    }
}
