// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
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
 * @dev Crumb suite for the cohort recorder: the FROZEN word format
 * the mainnet hub consumes. Every assertion is an exact
 * full-word equality (written bit | three 80-bit token-second lanes),
 * so a stray bit anywhere in the word (including the reserved
 * regions bits 240..251 and 253..255) fails loudly. Covered: exact
 * amount x seconds lane weights across full weeks; the lane shift as
 * a cohort graduates Y1 -> Y2 at its 52-week boundary (segment
 * recorded BEFORE the boundary rotation, so the graduation week
 * itself still accrues on the old lane); mid-week partial segments
 * accumulating incrementally at the balances that actually existed
 * across a reduction; the dormant fast-forward gap record (packed
 * fromWeek | toWeekExclusive << 32 | mature << 64) after the capped
 * 104-boundary walk; the mixed case where `advanceBook` pre-walked
 * part of a dormant span and the gap covers the rest; the weekly
 * `advanceBook` poke that keeps a book in the crumb channel for 110
 * weeks (every crumb word of the span exact across both graduations)
 * while an unpoked twin book over the same span compresses into one
 * gap record; and
 * finalized-crumb immutability: once the walk crosses a week's
 * closing boundary its word never changes again. The batched window
 * read `getCohortWeekCrumbs` returns element for element exactly what
 * the single getter serves across a window mixing written and
 * untouched weeks; and a zero-count window returns an empty array
 * without reverting.
 */
contract WiseSovrenNodesCohortCrumbsTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant AMOUNT = 1_000 * 1e6;

    address internal user1 = address(0xA1);
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

    function _crumbWord(
        uint256 _year1Seconds,
        uint256 _year2Seconds,
        uint256 _matureSeconds
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.CRUMB_WRITTEN_BIT
            | _year1Seconds
            | (_year2Seconds << CohortWeeks.LANE_Y2_SHIFT)
            | (_matureSeconds << CohortWeeks.LANE_M_SHIFT);
    }

    // ---- full-week lane weights ----

    function test_crumbs_fullWeeks_recordExactTimeWeights()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
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
                3_000
            ),
            _crumbWord(
                AMOUNT * (1 weeks - 1 hours),
                0,
                0
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_001
            ),
            _crumbWord(
                AMOUNT * 1 weeks,
                0,
                0
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_002
            ),
            _crumbWord(
                AMOUNT * 1 weeks,
                0,
                0
            )
        );
    }

    // ---- graduation lane shift ----

    function test_crumbs_graduation_shiftsLaneAcrossBoundary()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 53 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_051
            ),
            _crumbWord(
                AMOUNT * 1 weeks,
                0,
                0
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_052
            ),
            _crumbWord(
                0,
                AMOUNT * 1 weeks,
                0
            )
        );
    }

    function test_crumbs_secondGraduation_shiftsToMatureLane()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        vm.warp(
            BASE_TIME + 105 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_103
            ),
            _crumbWord(
                0,
                AMOUNT * 1 weeks,
                0
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_104
            ),
            _crumbWord(
                0,
                0,
                AMOUNT * 1 weeks
            )
        );
    }

    // ---- mid-week partial segments across a reduction ----

    function test_crumbs_midWeekReduction_segmentsSumExactly()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 hours
        );

        _transferAs(
            user1,
            outsider,
            400 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        vm.warp(
            BASE_TIME + 5 hours
        );

        _depositWithReferralAs(
            user1,
            100 * 1e6,
            refA
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_000
            ),
            _crumbWord(
                AMOUNT * 2 hours + 600 * 1e6 * 3 hours,
                0,
                0
            )
        );
    }

    function test_crumbs_partialCurrentWeek_accumulatesIncrementally()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 1 hours
        );

        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 3 hours
        );

        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_000
            ),
            _crumbWord(
                AMOUNT * 1 hours + 2 * AMOUNT * 2 hours,
                0,
                0
            )
        );
    }

    // ---- dormant fast-forward gap ----

    function test_crumbs_dormantSpan_recordsPackedGapEntry()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        vm.warp(
            3_300 weeks + 2 hours
        );

        _depositWithReferralAs(
            user1,
            50 * 1e6,
            refA
        );

        assertEq(
            _recorder().getCohortGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            _recorder().getCohortGapLogEntry(
                refA,
                0
            ),
            3_208
                | (3_300 << CohortWeeks.GAP_TO_SHIFT)
                | (AMOUNT << CohortWeeks.GAP_MATURE_SHIFT)
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_207
            ),
            _crumbWord(
                0,
                0,
                AMOUNT * 1 weeks
            )
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_250
            ),
            0
        );
    }

    function test_crumbs_mixedAdvanceAndGap_coverTheSpanExactly()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 104 weeks + 1 hours
        );

        _recorder().advanceBook(
            refA,
            104
        );

        vm.warp(
            3_300 weeks + 2 hours
        );

        _recorder().advanceBook(
            refA,
            26
        );

        _depositWithReferralAs(
            user1,
            50 * 1e6,
            refA
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refA,
                3_129
            ),
            _crumbWord(
                0,
                0,
                AMOUNT * 1 weeks
            )
        );

        assertEq(
            _recorder().getCohortGapLogLength(
                refA
            ),
            1
        );

        assertEq(
            _recorder().getCohortGapLogEntry(
                refA,
                0
            ),
            3_234
                | (3_300 << CohortWeeks.GAP_TO_SHIFT)
                | (AMOUNT << CohortWeeks.GAP_MATURE_SHIFT)
        );
    }

    function test_crumbs_weeklyAdvance_recordsCrumbsInsteadOfGap()
        public
    {
        address user2 = address(0xA2);

        address refB = address(0xB2);

        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        _depositWithReferralAs(
            user2,
            AMOUNT,
            refB
        );

        for (uint256 week = 3_001; week <= 3_110; ++week) {

            vm.warp(
                week * 1 weeks + 1 hours
            );

            vm.prank(
                poker
            );

            _recorder().advanceBook(
                refA,
                1
            );
        }

        _depositWithReferralAs(
            user2,
            50 * 1e6,
            refB
        );

        assertEq(
            _recorder().getCohortGapLogLength(
                refA
            ),
            0
        );

        uint256[] memory crumbs = _recorder().getCohortWeekCrumbs(
            refA,
            3_001,
            109
        );

        for (uint256 i; i < crumbs.length; ++i) {

            uint256 week = 3_001 + i;

            uint256 expected = _crumbWord(
                0,
                0,
                AMOUNT * 1 weeks
            );

            if (week < 3_052) {
                expected = _crumbWord(
                    AMOUNT * 1 weeks,
                    0,
                    0
                );
            } else if (week < 3_104) {
                expected = _crumbWord(
                    0,
                    AMOUNT * 1 weeks,
                    0
                );
            }

            assertEq(
                crumbs[i],
                expected
            );
        }

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            AMOUNT
        );

        assertEq(
            _recorder().getCohortGapLogLength(
                refB
            ),
            1
        );

        assertEq(
            _recorder().getCohortGapLogEntry(
                refB,
                0
            ),
            3_104
                | (3_110 << CohortWeeks.GAP_TO_SHIFT)
                | (AMOUNT << CohortWeeks.GAP_MATURE_SHIFT)
        );

        assertEq(
            _recorder().getCohortWeekCrumb(
                refB,
                3_105
            ),
            0
        );
    }

    // ---- finalized-crumb immutability ----

    function testFuzz_crumbs_finalizedWeekWordNeverChanges(
        uint256 _seed
    )
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        uint256 finalized = _recorder().getCohortWeekCrumb(
            refA,
            3_000
        );

        assertGt(
            finalized,
            0
        );

        uint256 state = _seed;

        for (uint256 i; i < 12; ++i) {

            state = uint256(
                keccak256(
                    abi.encode(
                        state,
                        i
                    )
                )
            );

            uint256 op = state % 4;

            if (op == 0) {

                _depositWithReferralAs(
                    user1,
                    bound(
                        state >> 8,
                        50 * 1e6,
                        2_000 * 1e6
                    ),
                    refA
                );

            } else if (op == 1) {

                uint256 held = diamond.balanceOf(
                    user1
                );

                if (held > 1) {

                    _transferAs(
                        user1,
                        outsider,
                        bound(
                            state >> 8,
                            1,
                            held / 2
                        )
                    );

                    vm.prank(
                        poker
                    );

                    _recorder().syncReferee(
                        user1
                    );
                }

            } else if (op == 2) {

                vm.warp(
                    block.timestamp + bound(
                        state >> 8,
                        1 hours,
                        20 weeks
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

            assertEq(
                _recorder().getCohortWeekCrumb(
                    refA,
                    3_000
                ),
                finalized
            );
        }
    }

    // ---- batched window read ----

    function test_getCohortWeekCrumbs_matchesSingleGetterAcrossWindow()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        uint256[] memory crumbs = _recorder().getCohortWeekCrumbs(
            refA,
            2_999,
            6
        );

        assertEq(
            crumbs.length,
            6
        );

        for (uint256 i; i < crumbs.length; ++i) {

            assertEq(
                crumbs[i],
                _recorder().getCohortWeekCrumb(
                    refA,
                    2_999 + i
                )
            );
        }

        assertEq(
            crumbs[0],
            0
        );

        assertEq(
            crumbs[1],
            _crumbWord(
                AMOUNT * (1 weeks - 1 hours),
                0,
                0
            )
        );

        assertEq(
            crumbs[2],
            _crumbWord(
                AMOUNT * 1 weeks,
                0,
                0
            )
        );

        assertEq(
            crumbs[5],
            0
        );
    }

    function test_getCohortWeekCrumbs_zeroCount_returnsEmpty()
        public
    {
        _depositWithReferralAs(
            user1,
            AMOUNT,
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _recorder().advanceBook(
            refA,
            104
        );

        uint256[] memory crumbs = _recorder().getCohortWeekCrumbs(
            refA,
            3_000,
            0
        );

        assertEq(
            crumbs.length,
            0
        );
    }
}
