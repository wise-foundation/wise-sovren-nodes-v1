// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
import {BurnWiseFacet} from "../../../src/diamond/vault/facets/BurnWiseFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../../src/diamond/shared/DiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

interface IUniswapV2Router {

    function WETH()
        external
        view
        returns (address);

    function swapExactETHForTokens(
        uint256 _amountOutMin,
        address[] calldata _path,
        address _to,
        uint256 _deadline
    )
        external
        payable
        returns (uint256[] memory amounts);
}

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
 * @dev Mainnet-fork coverage for the BurnWiseFacet. Each test
 * pranks tokens into the diamond via `deal` (which adjusts the
 * WISE token's own totalSupply too), then drives `burnWise()`
 * from a random EOA so the permissionless surface is exercised.
 */
contract WiseSovrenNodesBurnWiseForkTest is Test {

    address constant WISE_TOKEN = 0x66a0f676479Cee1d7373f3DC2e2952778BfF5bd6;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address randomEOA = address(0xBADCAFE);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    event WiseBurned(
        address indexed caller,
        uint256 amount,
        uint256 percentageBps
    );

    function setUp()
        public
    {
        vm.createSelectFork(
            vm.rpcUrl(
                "mainnet"
            )
        );

        usd = new MockUSD();

        diamond = _deployFromTest();
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
            tokenSymbol: "wsnUSDC"
        });
    }

    function _deployFromTest()
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        AdminFacet admin = new AdminFacet();
        ProxyFacet proxyF = new ProxyFacet();
        UserFacet userF = new UserFacet();
        SweepFacet sweepF = new SweepFacet();
        BurnWiseFacet burnF = new BurnWiseFacet();

        d = new WiseSovrenNodesDiamond(
            _buildInitParams()
        );

        bytes4[] memory adminSels = WiseSovrenNodesDiamondSelectors.adminSelectors();
        bytes4[] memory proxySels = WiseSovrenNodesDiamondSelectors.proxySelectors();
        bytes4[] memory userSels = WiseSovrenNodesDiamondSelectors.userSelectors();
        bytes4[] memory sweepSels = WiseSovrenNodesDiamondSelectors.sweepSelectors();
        bytes4[] memory burnSels = WiseSovrenNodesDiamondSelectors.burnWiseSelectors();

        d.proposeSelectors(
            adminSels,
            address(admin)
        );

        d.proposeSelectors(
            proxySels,
            address(proxyF)
        );

        d.proposeSelectors(
            userSels,
            address(userF)
        );

        d.proposeSelectors(
            sweepSels,
            address(sweepF)
        );

        d.proposeSelectors(
            burnSels,
            address(burnF)
        );

        d.executeSelectorChanges(
            adminSels
        );

        d.executeSelectorChanges(
            proxySels
        );

        d.executeSelectorChanges(
            userSels
        );

        d.executeSelectorChanges(
            sweepSels
        );

        d.executeSelectorChanges(
            burnSels
        );

        AdminFacet(address(d)).setWiseToken(
            WISE_TOKEN
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

    function _expected(
        uint256 _balance,
        uint256 _index
    )
        internal
        pure
        returns (uint256)
    {
        return _balance
            * _pct(_index)
            / 10_000;
    }

    // ---- 1. WISE_TOKEN is configured to the mainnet contract ----

    function test_wiseToken_configuredToMainnet()
        public
        view
    {
        assertEq(
            BurnWiseFacet(address(diamond)).WISE_TOKEN(),
            WISE_TOKEN
        );

        assertGt(
            WISE_TOKEN.code.length,
            0
        );
    }

    // ---- 2. getBurnableWise reads the diamond's WISE balance ----

    function test_getBurnableWise_zeroBalance_returnsZero()
        public
        view
    {
        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            0
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            0
        );
    }

    function test_getBurnableWise_positiveBalance_returnsBalance()
        public
    {
        uint256 amount = 12_345 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            amount
        );
    }

    // ---- 3. burnWise reverts when balance is zero ----

    function test_burnWise_zeroBalance_reverts_NoWiseToBurn()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoWiseToBurn.selector
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 4. burnWise leaves the balance minus the first slice (5%) ----

    function test_burnWise_burnsFirstSlotPercentage()
        public
    {
        uint256 amount = 1_000 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            amount - _expected(amount, 0)
        );
    }

    // ---- 5. burnWise decreases WISE totalSupply by the burned amount ----

    function test_burnWise_decreasesWiseTotalSupply()
        public
    {
        uint256 amount = 5_000 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        uint256 supplyBefore = IERC20(WISE_TOKEN).totalSupply();

        BurnWiseFacet(address(diamond)).burnWise();

        uint256 supplyAfter = IERC20(WISE_TOKEN).totalSupply();

        assertEq(
            supplyBefore - supplyAfter,
            _expected(amount, 0)
        );
    }

    // ---- 6. burnWise emits WiseBurned with caller and amount ----

    function test_burnWise_emitsWiseBurned()
        public
    {
        uint256 amount = 777 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WiseBurned(
            randomEOA,
            _expected(amount, 0),
            _pct(0)
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 7. burnWise returns the burned amount ----

    function test_burnWise_returnsBurnedAmount()
        public
    {
        uint256 amount = 4_242 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        uint256 returned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            returned,
            _expected(amount, 0)
        );
    }

    // ---- 8. permissionless: any EOA can trigger the burn ----

    function test_burnWise_callerIsAnyEOA_succeeds()
        public
    {
        uint256 amount = 2_500 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        uint256 callerBalanceBefore = IERC20(WISE_TOKEN).balanceOf(
            randomEOA
        );

        vm.prank(
            randomEOA
        );

        BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            amount - _expected(amount, 0)
        );

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(randomEOA),
            callerBalanceBefore
        );
    }

    // ---- 9. same caller cannot burn twice within the cooldown window ----

    function test_burnWise_secondCall_sameCaller_reverts_Cooldown()
        public
    {
        uint256 amount = 1_111 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            amount,
            true
        );

        BurnWiseFacet(address(diamond)).burnWise();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.WiseBurnCooldownNotElapsed.selector
        );

        BurnWiseFacet(address(diamond)).burnWise();
    }

    // ---- 10. after the cooldown a fresh balance burns the next slot (10%) ----

    function test_burnWise_freshBalanceAfterCooldown_burnsNextSlot()
        public
    {
        uint256 firstAmount = 100 * 1e18;
        uint256 secondAmount = 250 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            firstAmount,
            true
        );

        BurnWiseFacet(address(diamond)).burnWise();

        deal(
            WISE_TOKEN,
            address(diamond),
            secondAmount,
            true
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            secondAmount
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 returned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            returned,
            _expected(secondAmount, 1)
        );
    }

    // ---- 11. direct facet call reverts (onlyDelegateCall) ----

    function test_burnWise_directFacetCall_reverts_OnlyDelegateCall()
        public
    {
        BurnWiseFacet burnF = new BurnWiseFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        burnF.burnWise();
    }

    // ---- 12. getBurnableWise direct facet call reads facet balance, not diamond ----

    function test_getBurnableWise_directFacetCall_readsFacetBalance()
        public
    {
        BurnWiseFacet burnF = new BurnWiseFacet();

        assertEq(
            burnF.getBurnableWise(),
            IERC20(WISE_TOKEN).balanceOf(address(burnF))
        );
    }

    // ---- 13. real Uniswap V2 buy + transfer + burn round-trip ----

    function test_burnWise_buyOnUniswapTransferAndBurn()
        public
    {
        address buyer = address(0xB7E5);

        vm.deal(
            buyer,
            5 ether
        );

        IUniswapV2Router router = IUniswapV2Router(
            UNISWAP_V2_ROUTER
        );

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = WISE_TOKEN;

        vm.prank(
            buyer
        );

        router.swapExactETHForTokens{value: 1 ether}(
            0,
            path,
            buyer,
            block.timestamp + 1
        );

        uint256 bought = IERC20(WISE_TOKEN).balanceOf(
            buyer
        );

        assertGt(
            bought,
            0
        );

        vm.prank(
            buyer
        );

        IERC20(WISE_TOKEN).transfer(
            address(diamond),
            bought
        );

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            bought
        );

        assertEq(
            BurnWiseFacet(address(diamond)).getBurnableWise(),
            bought
        );

        uint256 supplyBefore = IERC20(WISE_TOKEN).totalSupply();

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WiseBurned(
            randomEOA,
            _expected(bought, 0),
            _pct(0)
        );

        vm.prank(
            randomEOA
        );

        uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            burned,
            _expected(bought, 0)
        );

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            bought - _expected(bought, 0)
        );

        assertEq(
            IERC20(WISE_TOKEN).totalSupply(),
            supplyBefore - _expected(bought, 0)
        );
    }

    // ---- 14. burnWise does not touch the USD_TOKEN buffer ----

    function test_burnWise_doesNotTouchUsdBalance()
        public
    {
        uint256 usdBuffer = 10_000 * 1e6;
        uint256 wiseAmount = 333 * 1e18;

        usd.mint(
            address(diamond),
            usdBuffer
        );

        deal(
            WISE_TOKEN,
            address(diamond),
            wiseAmount,
            true
        );

        BurnWiseFacet(address(diamond)).burnWise();

        assertEq(
            usd.balanceOf(address(diamond)),
            usdBuffer
        );

        assertEq(
            IERC20(WISE_TOKEN).balanceOf(address(diamond)),
            wiseAmount - _expected(wiseAmount, 0)
        );
    }

    // ---- 15. same caller within the cooldown window reverts ----

    function test_burnWise_sameCaller_withinCooldown_reverts()
        public
    {
        deal(
            WISE_TOKEN,
            address(diamond),
            1_000 * 1e18,
            true
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

    // ---- 16. distinct callers advance the shared rotation across all six slots ----

    function test_burnWise_rotationAcrossDistinctCallers()
        public
    {
        uint256 seeded = 1_000_000 * 1e18;

        deal(
            WISE_TOKEN,
            address(diamond),
            seeded,
            true
        );

        uint256 bal = seeded;

        for (uint256 i; i < 6; ++i) {
            assertEq(
                BurnWiseFacet(address(diamond)).getNextBurnPercentage(),
                _pct(i)
            );

            vm.prank(
                address(uint160(0xE0 + i))
            );

            uint256 burned = BurnWiseFacet(address(diamond)).burnWise();

            assertEq(
                burned,
                bal * _pct(i) / 10_000
            );

            bal -= burned;

            assertEq(
                BurnWiseFacet(address(diamond)).burnWiseIndex(),
                (i + 1) % 6
            );
        }
    }
}
