// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {TestUSD} from "./utils/mocks/TestUSD.sol";
import {MockWise} from "./utils/mocks/MockWise.sol";

/**
 * @dev Non-fork coverage for the configurable WISE token: the
 * `setWiseToken` master setter, the `address(0)` revert path on
 * chains with no WISE, and a full mint/burn round-trip against a
 * locally deployed {MockWise} — no mainnet fork required.
 */
contract WiseSovrenNodesBurnWiseConfigurableTest is Test {

    TestUSD usd;
    MockWise wise;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address randomEOA = address(0xBADCAFE);
    address nonMaster = address(0xBEEF);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    event WiseTokenSet(
        address wiseToken
    );

    event WiseBurned(
        address indexed caller,
        uint256 amount,
        uint256 percentageBps
    );

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
    }

    function _buildInitParams()
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: thirdPty,
            workerAddress: worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: TOTAL_DEPOSIT_CAP,
            interestRate: INTEREST_RATE,
            decimalsValue: 6,
            tokenName: "Wise Sovren Nodes",
            tokenSymbol: "WTN"
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

        d.finalizeSetup();
    }

    function _pct(
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

    function _setAndMint(
        uint256 _amount
    )
        internal
    {
        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );

        wise.mint(
            address(diamond),
            _amount
        );
    }

    // ---- 1. WISE_TOKEN defaults to address(0) ----

    function test_wiseToken_defaultsToZero()
        public
        view
    {
        assertEq(
            BurnWiseFacet(address(diamond)).WISE_TOKEN(),
            address(0)
        );
    }

    // ---- 2. setWiseToken by master updates storage and emits ----

    function test_setWiseToken_master_updatesAndEmits()
        public
    {
        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WiseTokenSet(
            address(wise)
        );

        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );

        assertEq(
            BurnWiseFacet(address(diamond)).WISE_TOKEN(),
            address(wise)
        );
    }

    // ---- 3. setWiseToken by non-master reverts ----

    function test_setWiseToken_nonMaster_reverts_NotMaster()
        public
    {
        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(
            nonMaster
        );

        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );
    }

    // ---- 4. setWiseToken can clear back to address(0) ----

    function test_setWiseToken_clearsToZero()
        public
    {
        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );

        AdminFacet(address(diamond)).setWiseToken(
            address(0)
        );

        assertEq(
            BurnWiseFacet(address(diamond)).WISE_TOKEN(),
            address(0)
        );
    }

    // ---- 5. burnWise reverts when the WISE token is unset ----

    function test_burnWise_unset_reverts_WiseTokenNotSet()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.WiseTokenNotSet.selector
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 6. getBurnableWise returns zero when unset ----

    function test_getBurnableWise_unset_returnsZero()
        public
        view
    {
        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            0
        );
    }

    // ---- 7. burnWise reverts when set but the balance is zero ----

    function test_burnWise_setButZeroBalance_reverts_NoWiseToBurn()
        public
    {
        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoWiseToBurn.selector
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 8. getBurnableWise reflects the diamond's balance once set ----

    function test_getBurnableWise_set_returnsBalance()
        public
    {
        uint256 amount = 12_345 * 1e18;

        AdminFacet(address(diamond)).setWiseToken(
            address(wise)
        );

        wise.mint(
            address(diamond),
            amount
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            amount
        );
    }

    // ---- 9. burnWise burns the first scheduled slice (5%), drops supply, emits ----

    function test_burnWise_burnsScheduledPercentage()
        public
    {
        uint256 amount = 5_000 * 1e18;

        _setAndMint(
            amount
        );

        uint256 supplyBefore = wise.totalSupply();

        uint256 expected = amount
            * 500
            / 10_000;

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WiseBurned(
            randomEOA,
            expected,
            500
        );

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            expected
        );

        assertEq(
            IERC20(address(wise)).balanceOf(address(diamond)),
            amount - expected
        );

        assertEq(
            wise.totalSupply(),
            supplyBefore - expected
        );
    }

    // ---- 10. first call from a fresh address is never cooldown-blocked ----

    function test_burnWise_firstCall_notBlockedByCooldown()
        public
    {
        _setAndMint(
            1_000 * 1e18
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            BurnWiseFacet(address(diamond)).lastBurnWiseAt(randomEOA),
            block.timestamp
        );
    }

    // ---- 11. same caller within the cooldown window reverts ----

    function test_burnWise_sameCaller_withinCooldown_reverts()
        public
    {
        _setAndMint(
            1_000 * 1e18
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.WiseBurnCooldownNotElapsed.selector
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 12. same caller can burn again once the cooldown elapses ----

    function test_burnWise_sameCaller_afterCooldown_succeeds()
        public
    {
        _setAndMint(
            1_000 * 1e18
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 balance = BurnWiseFacet(address(diamond)).getBurnableWise();

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            balance * 1000 / 10_000
        );
    }

    // ---- 13. the global index rotates 5/10/20/15/5/1% and wraps ----

    function test_burnWise_rotationSequenceAndWrap()
        public
    {
        _setAndMint(
            10_000_000 * 1e18
        );

        for (uint256 i; i < 7; ++i) {
            assertEq(
                BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
                _pct(i)
            );

            vm.prank(
                address(uint160(0xB0 + i))
            );

            BurnWiseFacet(address(diamond)).burnWise();

            assertEq(
                BurnWiseFacet(address(diamond)).burnWiseIndex(),
                (i + 1) % 6
            );
        }
    }

    // ---- 14. each slice is the exact percentage of the running balance ----

    function test_burnWise_percentageMath_runningBalance()
        public
    {
        _setAndMint(
            1_000 * 1e18
        );

        uint256 bal = 1_000 * 1e18;

        for (uint256 i; i < 4; ++i) {
            uint256 expected = bal
                * _pct(i)
                / 10_000;

            vm.prank(
                address(uint160(0xC0 + i))
            );

            uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

            assertEq(
                burned,
                expected
            );

            bal -= expected;

            assertEq(
                BurnWiseFacet(address(diamond)).getBurnableWise(),
                bal
            );
        }
    }

    // ---- 15. a balance below the sweep threshold burns in full (100%) ----

    function test_burnWise_belowThreshold_sweepsEntireBalance()
        public
    {
        uint256 amount = 40 * 1e18;

        _setAndMint(
            amount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WiseBurned(
            randomEOA,
            amount,
            10_000
        );

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            amount
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            0
        );

        assertEq(
            BurnWiseFacet(address(diamond)).burnWiseIndex(),
            1
        );
    }

    // ---- 16. a balance exactly at the threshold still sweeps (inclusive) ----

    function test_burnWise_atThreshold_sweepsEntireBalance()
        public
    {
        uint256 amount = 50 * 1e18;

        _setAndMint(
            amount
        );

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            amount
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            0
        );
    }

    // ---- 17. a balance above the threshold still burns only the slice ----

    function test_burnWise_aboveThreshold_burnsSlice()
        public
    {
        uint256 amount = 100 * 1e18;

        _setAndMint(
            amount
        );

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            amount * 500 / 10_000
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            amount - burned
        );
    }

    // ---- 18. getNextBurnPercentage tracks the advancing index ----

    function test_getNextBurnPercentage_tracksIndex()
        public
    {
        assertEq(
            BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
            500
        );

        _setAndMint(
            1_000 * 1e18
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
            1000
        );
    }
}
