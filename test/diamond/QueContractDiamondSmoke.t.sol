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
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {WiseSovrenNodesQueueStructs} from "../../src/diamond/vault/WiseSovrenNodesQueueStructs.sol";

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
 * @dev Smoke test for the merged WiseSovrenNodes + queue diamond. Proves
 * the queue surface drives the vault's proxy accounting internally on
 * a single address: joinQue increases proxyBalance, fulfillOrder
 * decreases it and pays the member, leaveQue returns tokens.
 */
contract QueContractDiamondSmokeTest is Test {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address fulf = address(0xF1);

    function setUp()
        public
    {
        usd = new MockUSD();

        _deployDiamond();

        _fundUserWithVaultTokens(
            user1,
            10_000 * 1e6
        );

        _fundUserWithVaultTokens(
            user2,
            10_000 * 1e6
        );

        usd.mint(
            fulf,
            100_000 * 1e6
        );

        vm.prank(
            fulf
        );

        usd.approve(
            address(diamond),
            type(uint256).max
        );
    }

    function _deployDiamond()
        internal
    {
        diamond = new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: address(usd),
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 100_000_000 * 1e6,
                interestRate: 2000,
                decimalsValue: 6,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "WTN"
            })
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.adminSelectors(),
            address(new AdminFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.proxySelectors(),
            address(new ProxyFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.userSelectors(),
            address(new UserFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.queueAdminSelectors(),
            address(new QueueAdminFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.queueFulfillSelectors(),
            address(new QueueFulfillFacet())
        );

        _proposeAndExecute(
            WiseSovrenNodesDiamondSelectors.queueViewSelectors(),
            address(new QueueViewFacet())
        );

        diamond.finalizeSetup();
    }

    function _proposeAndExecute(
        bytes4[] memory _selectors,
        address _facet
    )
        internal
    {
        diamond.proposeSelectors(
            _selectors,
            _facet
        );

        diamond.executeSelectorChanges(
            _selectors
        );
    }

    function _fundUserWithVaultTokens(
        address _user,
        uint256 _amount
    )
        internal
    {
        AdminFacet(address(diamond)).mintSupply(
            _user,
            _amount
        );
    }

    function test_smoke_queueSetup()
        public
        view
    {
        assertEq(
            address(diamond.USD_TOKEN()),
            address(usd)
        );

        assertEq(
            diamond.minDepositAmount(),
            50 * 1e6
        );

        assertTrue(
            diamond.initialized()
        );

        assertEq(
            diamond.InterestRateProxy(),
            address(diamond)
        );
    }

    function test_smoke_joinQueIncreasesProxyBalance()
        public
    {
        vm.prank(
            user1
        );

        (
            WiseSovrenNodesQueueStructs.QueMember memory member,
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        assertEq(
            member.member,
            user1
        );

        assertEq(
            member.amount,
            1_000 * 1e6
        );

        assertEq(
            diamond.proxyBalance(user1),
            1_000 * 1e6
        );

        assertEq(
            diamond.totalActiveOrders(),
            1
        );
    }

    function test_smoke_fulfillOrder()
        public
    {
        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            500 * 1e6,
            0
        );

        uint256 fulfTokensBefore = IERC20(address(diamond)).balanceOf(
            fulf
        );

        vm.prank(
            fulf
        );

        (
            uint256 vt,
            uint256 usdAmt
        ) = QueueFulfillFacet(address(diamond)).fulfillOrder(
            id,
            0
        );

        assertEq(
            vt,
            500 * 1e6
        );

        assertEq(
            usdAmt,
            500 * 1e6
        );

        assertEq(
            IERC20(address(diamond)).balanceOf(fulf),
            fulfTokensBefore + 500 * 1e6
        );

        assertEq(
            diamond.proxyBalance(user1),
            0
        );
    }

    function test_smoke_leaveQueReturnsTokens()
        public
    {
        uint256 user1BalBefore = IERC20(address(diamond)).balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            500 * 1e6,
            0
        );

        assertEq(
            IERC20(address(diamond)).balanceOf(user1),
            user1BalBefore - 500 * 1e6
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            0
        );

        assertEq(
            IERC20(address(diamond)).balanceOf(user1),
            user1BalBefore
        );

        assertEq(
            diamond.proxyBalance(user1),
            0
        );
    }

    function test_smoke_adminMinDeposit()
        public
    {
        QueueAdminFacet(address(diamond)).changeMinDepositAmount(
            100 * 1e6
        );

        assertEq(
            diamond.minDepositAmount(),
            100 * 1e6
        );
    }
}
