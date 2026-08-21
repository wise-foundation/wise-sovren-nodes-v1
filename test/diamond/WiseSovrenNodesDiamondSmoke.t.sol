// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";

import {DeployWiseSovrenNodesDiamond} from "../../script/diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

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
 * @dev Smoke test for the WiseSovrenNodes diamond: deploys facets and
 * diamond, wires selectors, finalizes, runs the core flows
 * (mintSupply, deposit, claim, transfer, proxy balance)
 * to prove the dispatcher routes correctly.
 */
contract WiseSovrenNodesDiamondSmokeTest is Test {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user1 = address(0xA1);
    address user2 = address(0xA2);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    function setUp()
        public
    {
        usd = new MockUSD();

        vm.etch(
            0x000000000022D473030F116dDEE9F6B43aC78BA3,
            hex"00"
        );

        DeployWiseSovrenNodesDiamond deployer = new DeployWiseSovrenNodesDiamond();

        (diamond,) = deployer.deploy(
            _buildInitParams(
                worker
            )
        );
    }

    function _buildInitParams(
        address _worker
    )
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: thirdPty,
            workerAddress: _worker,
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

        d = new WiseSovrenNodesDiamond(
            _buildInitParams(
                worker
            )
        );

        bytes4[] memory adminSels = WiseSovrenNodesDiamondSelectors.adminSelectors();
        bytes4[] memory proxySels = WiseSovrenNodesDiamondSelectors.proxySelectors();
        bytes4[] memory userSels = WiseSovrenNodesDiamondSelectors.userSelectors();
        bytes4[] memory sweepSels = WiseSovrenNodesDiamondSelectors.sweepSelectors();

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

        d.finalizeSetup();
    }

    function test_smoke_deployAndState()
        public
    {
        WiseSovrenNodesDiamond d = _deployFromTest();

        assertEq(
            address(d.USD_TOKEN()),
            address(usd)
        );

        assertEq(
            d.interestRate(),
            INTEREST_RATE
        );

        assertEq(
            d.master(),
            address(this)
        );

        assertEq(
            d.decimals(),
            6
        );

        assertTrue(
            d.initialized()
        );
    }

    function test_smoke_mintSupplyViaFacet()
        public
    {
        WiseSovrenNodesDiamond d = _deployFromTest();

        AdminFacet(address(d)).mintSupply(
            user1,
            1_000 * 1e6
        );

        assertEq(
            d.balanceOf(user1),
            1_000 * 1e6
        );
    }

    function test_smoke_transferIsOnDiamondDirectly()
        public
    {
        WiseSovrenNodesDiamond d = _deployFromTest();

        AdminFacet(address(d)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        d.transfer(
            user2,
            200 * 1e6
        );

        assertEq(
            d.balanceOf(user1),
            800 * 1e6
        );

        assertEq(
            d.balanceOf(user2),
            200 * 1e6
        );
    }

    function test_smoke_graceFreezeTogglableFromGenesisDeploy()
        public
    {
        assertTrue(
            diamond.transferHookFacet() != address(0)
        );

        assertEq(
            diamond.graceFreezeEnabled(),
            false
        );

        uint256 threshold = diamond.graceThresholdAmount();

        usd.mint(
            user1,
            threshold
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            threshold
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            1_000 * 1e6
        );

        vm.prank(
            diamond.master()
        );

        AdminFacet(address(diamond)).setGraceFreezeEnabled(
            true
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );
    }

    function test_smoke_depositAccumTogglableFromGenesisDeploy()
        public
    {
        assertTrue(
            diamond.depositHookFacet() != address(0)
        );

        assertEq(
            diamond.depositAccumWindow(),
            0
        );

        uint256 half = 6_000 * 1e6;

        usd.mint(
            user1,
            2 * half
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            type(uint256).max
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            half
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            half
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        vm.prank(
            diamond.master()
        );

        AdminFacet(address(diamond)).setDepositAccumWindow(
            1 days
        );

        usd.mint(
            user2,
            2 * half
        );

        vm.prank(
            user2
        );

        usd.approve(
            address(diamond),
            type(uint256).max
        );

        vm.prank(
            user2
        );

        UserFacet(address(diamond)).deposit(
            half
        );

        vm.prank(
            user2
        );

        UserFacet(address(diamond)).deposit(
            half
        );

        assertEq(
            diamond.lastLargeDepositAt(user2),
            block.timestamp
        );
    }

    function test_smoke_proxyFlow()
        public
    {
        WiseSovrenNodesDiamond d = _deployFromTest();

        AdminFacet(address(d)).mintSupply(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            address(d)
        );

        ProxyFacet(address(d)).increaseProxyBalance(
            user1,
            500 * 1e6
        );

        assertEq(
            d.proxyBalance(user1),
            500 * 1e6
        );

        vm.prank(
            address(d)
        );

        ProxyFacet(address(d)).decreaseProxyBalance(
            user1,
            300 * 1e6
        );

        assertEq(
            d.proxyBalance(user1),
            200 * 1e6
        );
    }

    function test_smoke_onlyDelegateCall_directRevert()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert();

        admin.disAllowSupplyChangeByOwner();
    }

    function test_smoke_facetNotFound()
        public
    {
        WiseSovrenNodesDiamond d = _deployFromTest();

        (bool ok,) = address(d).call(
            abi.encodeWithSignature(
                "nonExistent()"
            )
        );

        assertFalse(
            ok
        );
    }

    function test_deploy_wiresMoveFacet()
        public
    {
        uint256 moveable = MoveFacet(
            address(diamond)
        ).getMoveableBalance(
            user1
        );

        assertEq(
            moveable,
            0
        );
    }
}
