// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";

import {
    WiseSovrenNodesDiamondSelectors,
    IAutoCompoundGetters
} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

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
 * @dev Exercises {AutoCompoundFacet}. The load-bearing properties:
 * a bot-driven compound is the audited compound path plus a clean
 * fee split (net + fee == interest, INT-7 lockstep, USD out equals
 * the cleared liability), both gates are required, opt-out can
 * never be blocked, the grace stamp is measured on the minted NET
 * (the legacy-faithful boundary divergence is pinned explicitly),
 * and the getter mirror interface matches the shard's real
 * getters. Buckets are granted via {InterestAdminFacet} so every
 * fee-math expectation is exact.
 */
contract WiseSovrenNodesAutoCompoundFacetTest is DiamondTestHarness {

    event CompoundInterestOnBehalf(
        address indexed user,
        address indexed bot,
        uint256 netAmount,
        uint256 feeAmount
    );

    event AutoCompoundBotSet(
        address indexed bot,
        bool allowed
    );

    event AutoCompoundAllowedSet(
        address indexed user,
        bool allowed
    );

    event AutoCompoundFeeBpsSet(
        uint256 autoCompoundFeeBps
    );

    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;

    address internal bot = address(0xB07);
    address internal user = address(0xA1);
    address internal userB = address(0xA2);
    address internal stranger = address(0xBEEF);

    WiseSovrenNodesDiamond internal diamond;
    AutoCompoundFacet internal ac;
    MockUSD internal usd;

    address internal facetInstance;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
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
            address(new InterestAdminFacet()),
            WiseSovrenNodesDiamondSelectors.interestAdminSelectors()
        );

        facetInstance = address(
            new AutoCompoundFacet()
        );

        _wireOne(
            diamond,
            facetInstance,
            WiseSovrenNodesDiamondSelectors.autoCompoundSelectors()
        );

        diamond.finalizeSetup();

        ac = AutoCompoundFacet(
            address(diamond)
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        ac.setAutoCompoundFeeBps(
            FEE_BPS
        );

        ac.setAutoCompoundBot(
            bot,
            true
        );
    }

    function _grant(
        address _user,
        uint256 _amount
    )
        internal
    {
        InterestAdminFacet(address(diamond)).setCashedInterest(
            _user,
            _amount
        );
    }

    function _optIn(
        address _user
    )
        internal
    {
        vm.prank(
            _user
        );

        ac.setAutoCompoundAllowed(
            true
        );
    }

    function _compound(
        address _user
    )
        internal
        returns (uint256)
    {
        vm.prank(
            bot
        );

        return ac.compoundInterestOnBehalf(
            _user
        );
    }

    function _total()
        internal
        view
        returns (uint256)
    {
        return CashedInterestFacet(address(diamond)).getTotalCashedInterest();
    }

    // ---- compoundInterestOnBehalf ----

    function test_compound_happyPath_feeSplitAndConservation()
        public
    {
        uint256 interest = 1_000 * 1e6;
        uint256 fee = interest * FEE_BPS / PRECISION_RATE;
        uint256 net = interest - fee;

        _grant(
            user,
            interest
        );

        _optIn(
            user
        );

        uint256 totalBefore = _total();
        uint256 vaultUsdBefore = usd.balanceOf(address(diamond));
        uint256 supplyBefore = diamond.totalSupply();

        uint256 returned = _compound(
            user
        );

        assertEq(
            returned,
            net
        );

        assertEq(
            diamond.balanceOf(user),
            net
        );

        assertEq(
            diamond.cashedInterest(user),
            0
        );

        assertEq(
            usd.balanceOf(bot),
            fee
        );

        assertEq(
            usd.balanceOf(thirdPty),
            net
        );

        assertEq(
            _total(),
            totalBefore - interest,
            "accumulator must drop by the full cleared interest"
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            vaultUsdBefore - interest,
            "USD out must equal the cleared liability"
        );

        assertEq(
            diamond.totalSupply(),
            supplyBefore + net
        );
    }

    function test_compound_emitsEvent()
        public
    {
        uint256 interest = 500 * 1e6;
        uint256 fee = interest * FEE_BPS / PRECISION_RATE;

        _grant(
            user,
            interest
        );

        _optIn(
            user
        );

        vm.expectEmit(
            true,
            true,
            false,
            true
        );

        emit CompoundInterestOnBehalf(
            user,
            bot,
            interest - fee,
            fee
        );

        _compound(
            user
        );
    }

    function test_compound_zeroFeeBps_skipsBotPayout()
        public
    {
        ac.setAutoCompoundFeeBps(
            0
        );

        uint256 interest = 1_000 * 1e6;

        _grant(
            user,
            interest
        );

        _optIn(
            user
        );

        uint256 net = _compound(
            user
        );

        assertEq(
            net,
            interest
        );

        assertEq(
            usd.balanceOf(bot),
            0
        );

        assertEq(
            diamond.balanceOf(user),
            interest
        );
    }

    function test_compound_dustInterest_feeRoundsDownToZero()
        public
    {
        uint256 interest = 99;

        _grant(
            user,
            interest
        );

        _optIn(
            user
        );

        uint256 net = _compound(
            user
        );

        assertEq(
            net,
            interest,
            "a sub-unit fee must round down to the user"
        );

        assertEq(
            usd.balanceOf(bot),
            0
        );
    }

    function test_compound_banksPendingAccrualFirst()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 interest = diamond.getTotalInterestUser(
            user
        );

        assertEq(
            interest,
            200 * 1e6,
            "20% APR over one rate-year on 1000 units"
        );

        _optIn(
            user
        );

        uint256 fee = interest * FEE_BPS / PRECISION_RATE;

        uint256 net = _compound(
            user
        );

        assertEq(
            net,
            interest - fee
        );

        assertEq(
            diamond.balanceOf(user),
            1_000 * 1e6 + net
        );

        assertEq(
            diamond.cashedInterest(user),
            0
        );
    }

    // ---- grace stamping on the minted net ----

    function test_compound_stampsGrace_netAtThreshold_thenLocks()
        public
    {
        AdminFacet(address(diamond)).setGraceThresholdAmount(
            100 * 1e6
        );

        _grant(
            user,
            102 * 1e6
        );

        _optIn(
            user
        );

        _compound(
            user
        );

        assertEq(
            diamond.lastLargeDepositAt(user),
            block.timestamp,
            "net >= threshold must stamp the grace lock"
        );

        _grant(
            user,
            102 * 1e6
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_noStamp_netBelowThreshold()
        public
    {
        AdminFacet(address(diamond)).setGraceThresholdAmount(
            100 * 1e6
        );

        _grant(
            user,
            99 * 1e6
        );

        _optIn(
            user
        );

        _compound(
            user
        );

        assertEq(
            diamond.lastLargeDepositAt(user),
            0
        );
    }

    function test_compound_boundaryBand_stampMeasuresNetNotInterest()
        public
    {
        AdminFacet(address(diamond)).setGraceThresholdAmount(
            100 * 1e6
        );

        uint256 interest = 100_500_000;

        _grant(
            user,
            interest
        );

        _optIn(
            user
        );

        _compound(
            user
        );

        assertEq(
            diamond.lastLargeDepositAt(user),
            0,
            "interest >= threshold > net must NOT stamp on the fee path"
        );

        _grant(
            userB,
            interest
        );

        vm.prank(
            userB
        );

        UserFacet(address(diamond)).compoundInterest();

        assertEq(
            diamond.lastLargeDepositAt(userB),
            block.timestamp,
            "the self-compound control mints the full interest and stamps"
        );
    }

    // ---- differential vs the audited self-compound ----

    function test_differential_selfCompoundMinusFee()
        public
    {
        uint256 interest = 1_000 * 1e6;
        uint256 fee = interest * FEE_BPS / PRECISION_RATE;

        _grant(
            user,
            interest
        );

        _grant(
            userB,
            interest
        );

        _optIn(
            userB
        );

        uint256 totalBefore = _total();

        vm.prank(
            user
        );

        uint256 selfMinted = UserFacet(address(diamond)).compoundInterest();

        uint256 thirdPtyAfterSelf = usd.balanceOf(
            thirdPty
        );

        uint256 net = _compound(
            userB
        );

        assertEq(
            net,
            selfMinted - fee,
            "on-behalf must equal the audited self-compound minus the fee"
        );

        assertEq(
            diamond.balanceOf(userB),
            diamond.balanceOf(user) - fee
        );

        assertEq(
            usd.balanceOf(thirdPty) - thirdPtyAfterSelf,
            thirdPtyAfterSelf - fee,
            "third-party USD legs differ by exactly the fee"
        );

        assertEq(
            _total(),
            totalBefore - 2 * interest,
            "both paths clear the identical liability"
        );
    }

    // ---- gates and reverts ----

    function test_compound_notBot_reverts()
        public
    {
        _grant(
            user,
            1e6
        );

        _optIn(
            user
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotAutoCompoundBot.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_notOptedIn_reverts()
        public
    {
        _grant(
            user,
            1e6
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AutoCompoundNotAllowed.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_afterOptOut_reverts()
        public
    {
        _grant(
            user,
            1e6
        );

        _optIn(
            user
        );

        vm.prank(
            user
        );

        ac.setAutoCompoundAllowed(
            false
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AutoCompoundNotAllowed.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_noInterest_reverts()
        public
    {
        _optIn(
            user
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoInterest.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_overDepositCap_reverts()
        public
    {
        _grant(
            user,
            1_000 * 1e6
        );

        _optIn(
            user
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            0
        );

        vm.prank(
            bot
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    function test_compound_paused_reverts()
        public
    {
        _grant(
            user,
            1e6
        );

        _optIn(
            user
        );

        AdminFacet(address(diamond)).pauseDeposits();

        vm.prank(
            bot
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        ac.compoundInterestOnBehalf(
            user
        );
    }

    // ---- setAutoCompoundAllowed ----

    function test_setAllowed_togglesAndEmits()
        public
    {
        assertEq(
            diamond.autoCompoundAllowed(user),
            false
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit AutoCompoundAllowedSet(
            user,
            true
        );

        _optIn(
            user
        );

        assertEq(
            diamond.autoCompoundAllowed(user),
            true
        );

        vm.prank(
            user
        );

        ac.setAutoCompoundAllowed(
            false
        );

        assertEq(
            diamond.autoCompoundAllowed(user),
            false
        );
    }

    function test_setAllowed_optOutWorksWhilePaused()
        public
    {
        _optIn(
            user
        );

        AdminFacet(address(diamond)).pauseDeposits();

        vm.prank(
            user
        );

        ac.setAutoCompoundAllowed(
            false
        );

        assertEq(
            diamond.autoCompoundAllowed(user),
            false,
            "opting out must never be blocked by a pause"
        );
    }

    // ---- setAutoCompoundBot ----

    function test_setBot_setsRevokesAndEmits()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit AutoCompoundBotSet(
            stranger,
            true
        );

        ac.setAutoCompoundBot(
            stranger,
            true
        );

        assertEq(
            diamond.isAutoCompoundBot(stranger),
            true
        );

        ac.setAutoCompoundBot(
            stranger,
            false
        );

        assertEq(
            diamond.isAutoCompoundBot(stranger),
            false
        );
    }

    function test_setBot_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        ac.setAutoCompoundBot(
            address(0),
            true
        );
    }

    function test_setBot_nonMaster_reverts()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        ac.setAutoCompoundBot(
            stranger,
            true
        );
    }

    // ---- setAutoCompoundFeeBps ----

    function test_setFeeBps_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit AutoCompoundFeeBpsSet(
            250
        );

        ac.setAutoCompoundFeeBps(
            250
        );

        assertEq(
            diamond.autoCompoundFeeBps(),
            250
        );
    }

    function test_setFeeBps_capBoundary()
        public
    {
        ac.setAutoCompoundFeeBps(
            500
        );

        assertEq(
            diamond.autoCompoundFeeBps(),
            500
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.AutoCompoundFeeTooHigh.selector
        );

        ac.setAutoCompoundFeeBps(
            501
        );
    }

    function test_setFeeBps_nonMaster_reverts()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        ac.setAutoCompoundFeeBps(
            1
        );
    }

    // ---- facet plumbing ----

    function test_directCall_reverts()
        public
    {
        AutoCompoundFacet direct = AutoCompoundFacet(
            facetInstance
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        direct.compoundInterestOnBehalf(
            user
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        direct.setAutoCompoundAllowed(
            true
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        direct.setAutoCompoundBot(
            bot,
            true
        );

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        direct.setAutoCompoundFeeBps(
            1
        );
    }

    /**
     * @dev Direct calls through the mirror interface prove each
     * mirrored signature resolves to a real getter in the facet
     * bytecode; the routing loop proves the diamond carries all
     * seven selectors.
     */
    function test_getterMirrorInterface_matchesFacetBytecode()
        public
    {
        IAutoCompoundGetters direct = IAutoCompoundGetters(
            facetInstance
        );

        assertEq(
            direct.isAutoCompoundBot(bot),
            false
        );

        assertEq(
            direct.autoCompoundAllowed(user),
            false
        );

        assertEq(
            direct.autoCompoundFeeBps(),
            0
        );

        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors.autoCompoundSelectors();

        for (uint256 i = 0; i < sels.length; i++) {
            assertEq(
                diamond.selectorToFacet(sels[i]),
                facetInstance,
                "every auto-compound selector must be routed"
            );
        }
    }

    // ---- fee-math fuzz ----

    function testFuzz_feeMath_conservation(
        uint256 _interest,
        uint256 _bps
    )
        public
    {
        _interest = bound(
            _interest,
            1,
            1_000_000 * 1e6
        );

        _bps = bound(
            _bps,
            0,
            500
        );

        ac.setAutoCompoundFeeBps(
            _bps
        );

        _grant(
            user,
            _interest
        );

        _optIn(
            user
        );

        uint256 totalBefore = _total();

        uint256 net = _compound(
            user
        );

        uint256 fee = _interest * _bps / PRECISION_RATE;

        assertEq(
            net,
            _interest - fee
        );

        assertEq(
            usd.balanceOf(bot),
            fee
        );

        assertEq(
            diamond.balanceOf(user),
            net
        );

        assertGt(
            net,
            0,
            "the capped fee can never consume the whole interest"
        );

        assertEq(
            _total(),
            totalBefore - _interest
        );
    }
}
