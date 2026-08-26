// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {FacetBase} from "../../src/diamond/vault/facets/FacetBase.sol";

import {IWiseToken} from "../../src/diamond/vault/interfaces/IWiseToken.sol";
import {SelectorTimelockNotElapsed} from "../../src/diamond/shared/DiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {TestUSD} from "./utils/mocks/TestUSD.sol";
import {MockWise} from "./utils/mocks/MockWise.sol";

/**
 * @dev A stand-in "next version" of {BurnWiseFacet} carrying a
 * LONGER (8-slot) burn schedule with different percentages
 * (3/7/12/25/9/4/18%/6%). Its `burnWise` / `getBurnableWise` /
 * `getNextBurnPercentage` signatures - hence selectors - match the
 * shipped facet, so it can be DELEGATECALL-swapped in through the
 * diamond's selector routing. Every slice stays below 100%.
 */
contract AltBurnWiseFacet is FacetBase {

    uint256 internal constant ALT_SEQUENCE_LENGTH = 8;

    uint256 internal constant BURN_WISE_SWEEP_THRESHOLD = 100 * 1e18;

    constructor()
        FacetBase()
    {}

    function burnWise()
        external
        onlyDelegateCall
        nonReentrant
        returns (uint256 amount)
    {
        address wiseToken = WISE_TOKEN;

        require(
            wiseToken != ZERO_ADDRESS,
            WiseTokenNotSet()
        );

        require(
            lastBurnWiseAt[msg.sender] == 0
                || block.timestamp >= lastBurnWiseAt[msg.sender] + BURN_WISE_COOLDOWN,
            WiseBurnCooldownNotElapsed()
        );

        uint256 balance = IWiseToken(wiseToken).balanceOf(
            address(this)
        );

        uint256 percentageBps = _altPercentageForIndex(
            burnWiseIndex
        );

        if (balance <= BURN_WISE_SWEEP_THRESHOLD) {
            percentageBps = PRECISION_RATE;
        }

        amount = balance
            * percentageBps
            / PRECISION_RATE;

        require(
            amount > 0,
            NoWiseToBurn()
        );

        lastBurnWiseAt[msg.sender] = block.timestamp;

        burnWiseIndex = (burnWiseIndex + 1)
            % ALT_SEQUENCE_LENGTH;

        IWiseToken(wiseToken).burn(
            amount
        );

        emit WiseBurned(
            msg.sender,
            amount,
            percentageBps
        );
    }

    function getBurnableWise()
        external
        view
        returns (uint256)
    {
        address wiseToken = WISE_TOKEN;

        if (wiseToken == ZERO_ADDRESS) {
            return 0;
        }

        return IWiseToken(wiseToken).balanceOf(
            address(this)
        );
    }

    function getNextBurnPercentage()
        external
        view
        returns (uint256)
    {
        return _altPercentageForIndex(
            burnWiseIndex
        );
    }

    function _altPercentageForIndex(
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        uint256[ALT_SEQUENCE_LENGTH] memory sequence = [
            uint256(300),
            700,
            1200,
            2500,
            900,
            400,
            1800,
            600
        ];

        return sequence[
            _index % ALT_SEQUENCE_LENGTH
        ];
    }
}

/**
 * @dev Proves the WISE burn schedule is upgradeable by facet swap -
 * no master-editable storage required. Deploys the diamond with the
 * shipped {BurnWiseFacet} (6-slot 5/10/20/15/5/1% schedule),
 * then re-points the burn selectors to an {AltBurnWiseFacet} (8-slot,
 * different numbers) through propose -> 3-day timelock -> execute, and
 * asserts burns follow the new schedule while the on-diamond rotation
 * cursor survives the swap.
 */
contract WiseSovrenNodesBurnWiseFacetSwapTest is Test {

    TestUSD usd;
    MockWise wise;
    WiseSovrenNodesDiamond diamond;
    AltBurnWiseFacet altFacet;

    address randomEOA = address(0xBADCAFE);
    address other = address(0xF00D);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new TestUSD(
            "Test USD",
            "tUSD",
            6
        );

        wise = new MockWise();

        diamond = _deploy();

        altFacet = new AltBurnWiseFacet();
    }

    function _buildInitParams()
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: address(0xCAFE),
            workerAddress: address(0xD00D),
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: TOTAL_DEPOSIT_CAP,
            interestRate: INTEREST_RATE,
            decimalsValue: 6,
            tokenName: "Wise Sovren Nodes",
            tokenSymbol: "wsnUSDC"
        });
    }

    function _deploy()
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        AdminFacet admin = new AdminFacet();
        BurnWiseFacet burnF = new BurnWiseFacet();

        d = new WiseSovrenNodesDiamond(
            _buildInitParams()
        );

        bytes4[] memory adminSels = WiseSovrenNodesDiamondSelectors.adminSelectors();
        bytes4[] memory burnSels = WiseSovrenNodesDiamondSelectors.burnWiseSelectors();

        d.proposeSelectors(
            adminSels,
            address(admin)
        );

        d.proposeSelectors(
            burnSels,
            address(burnF)
        );

        d.executeSelectorChanges(
            adminSels
        );

        d.executeSelectorChanges(
            burnSels
        );

        AdminFacet(address(d)).setWiseToken(
            address(wise)
        );

        d.finalizeSetup();
    }

    function _swapToAltFacet()
        internal
    {
        bytes4[] memory burnSels = WiseSovrenNodesDiamondSelectors.burnWiseSelectors();

        diamond.proposeSelectors(
            burnSels,
            address(altFacet)
        );

        vm.warp(
            block.timestamp + 3 days
        );

        diamond.executeSelectorChanges(
            burnSels
        );
    }

    function _orig(
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        uint16[6] memory sequence = [
            uint16(500),
            1000,
            2000,
            1500,
            500,
            100
        ];

        return sequence[
            _index % 6
        ];
    }

    function _alt(
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        uint16[8] memory sequence = [
            uint16(300),
            700,
            1200,
            2500,
            900,
            400,
            1800,
            600
        ];

        return sequence[
            _index % 8
        ];
    }

    // ---- 1. the swap is gated by the 3-day selector timelock ----

    function test_facetSwap_requiresTimelock()
        public
    {
        bytes4[] memory burnSels = WiseSovrenNodesDiamondSelectors.burnWiseSelectors();

        diamond.proposeSelectors(
            burnSels,
            address(altFacet)
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        diamond.executeSelectorChanges(
            burnSels
        );
    }

    // ---- 2. after the swap, burns follow the new, longer schedule ----

    function test_facetSwap_appliesNewLongerSchedule()
        public
    {
        assertEq(
            BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
            _orig(0)
        );

        _swapToAltFacet();

        assertEq(
            BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
            _alt(0)
        );

        uint256 seed = 10_000_000 * 1e18;

        wise.mint(
            address(diamond),
            seed
        );

        uint256 bal = seed;

        for (uint256 i; i < 9; ++i) {
            assertEq(
                BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
                _alt(i)
            );

            vm.prank(
                address(uint160(0xA00 + i))
            );

            uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

            assertEq(
                burned,
                bal * _alt(i) / 10_000
            );

            bal -= burned;

            assertEq(
                BurnWiseFacet(address(diamond)).burnWiseIndex(),
                (i + 1) % 8
            );
        }
    }

    // ---- 3. the on-diamond rotation cursor survives the facet swap ----

    function test_facetSwap_preservesRotationCursor()
        public
    {
        uint256 seed = 1_000_000 * 1e18;

        wise.mint(
            address(diamond),
            seed
        );

        vm.prank(
            randomEOA
        );

        uint256 firstBurn = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            firstBurn,
            seed * _orig(0) / 10_000
        );

        assertEq(
            BurnWiseFacet(address(diamond)).burnWiseIndex(),
            1
        );

        _swapToAltFacet();

        assertEq(
            BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
            _alt(1)
        );

        uint256 bal = BurnWiseFacet(address(diamond)).getBurnableWise();

        vm.prank(
            other
        );

        uint256 secondBurn = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            secondBurn,
            bal * _alt(1) / 10_000
        );

        assertEq(
            BurnWiseFacet(address(diamond)).burnWiseIndex(),
            2
        );
    }

    // ---- 4. the sweep threshold is swappable along with the schedule ----

    function test_facetSwap_changesSweepThreshold()
        public
    {
        uint256 seed = 75 * 1e18;

        wise.mint(
            address(diamond),
            seed
        );

        vm.prank(
            randomEOA
        );

        uint256 sliced = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            sliced,
            seed * _orig(0) / 10_000
        );

        uint256 remaining = seed - sliced;

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            remaining
        );

        _swapToAltFacet();

        vm.prank(
            other
        );

        uint256 swept = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            swept,
            remaining
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            0
        );
    }
}
