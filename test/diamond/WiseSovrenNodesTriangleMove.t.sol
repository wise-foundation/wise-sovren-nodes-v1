// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

contract MockUSD6 is ERC20 {

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
 * @dev Proves the three-product single-chain posture (usdc / usdt /
 * usdg vaults on mainnet or arbitrum) supports free user movement:
 * three 6-decimal diamonds are deployed on one chain and
 * cross-registered as peers in every ordered direction via the
 * timelocked propose/execute flow, then a user round-trips the full
 * triangle. Every leg must relocate `totalDepositCap` with the moved
 * shares — destination cap up by the moved amount, source cap down
 * by the same amount, room (`totalDepositCap - totalSupply()`)
 * unchanged on both ends — and the full six-direction round trip
 * must return every cap exactly to its genesis value (the A->B->A
 * over-mint regression at triangle scale). Also proves the
 * dormant-chain gate (`depositsDisabled`, the shipped usdg posture)
 * blocks direct deposits but never a move in either direction, that
 * pending interest is banked into `cashedInterest` on the source on
 * the way out, and that a missing registration on either side of a
 * direction fails closed.
 */
contract WiseSovrenNodesTriangleMoveTest is Test {

    MockUSD6 internal usdA;
    MockUSD6 internal usdB;
    MockUSD6 internal usdC;

    WiseSovrenNodesDiamond internal vaultA;
    WiseSovrenNodesDiamond internal vaultB;
    WiseSovrenNodesDiamond internal vaultC;

    address internal master = address(this);
    address internal thirdPty = address(0xCAFE);
    address internal worker = address(0xD00D);
    address internal user1 = address(0xA1);

    uint256 internal constant TOTAL_DEPOSIT_CAP = type(uint128).max;
    uint256 internal constant INTEREST_RATE = 2000;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;
    uint256 internal constant AMOUNT = 600 * 1e6;

    function setUp()
        public
    {
        usdA = new MockUSD6();
        usdB = new MockUSD6();
        usdC = new MockUSD6();

        vm.warp(
            1_700_000_000
        );

        vaultA = _deployVault(
            address(usdA)
        );

        vaultB = _deployVault(
            address(usdB)
        );

        vaultC = _deployVault(
            address(usdC)
        );

        _wireTriangle();

        AdminFacet(address(vaultC)).setDepositsDisabled(
            true
        );
    }

    // ---- Deployment helpers ----

    function _deployVault(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: _usd,
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
            })
        );

        _wireOne(
            d,
            address(new AdminFacet()),
            WiseSovrenNodesDiamondSelectors.adminSelectors()
        );

        _wireOne(
            d,
            address(new UserFacet()),
            WiseSovrenNodesDiamondSelectors.userSelectors()
        );

        _wireOne(
            d,
            address(new MoveFacet()),
            WiseSovrenNodesDiamondSelectors.moveSelectors()
        );

        d.finalizeSetup();
    }

    function _wireOne(
        WiseSovrenNodesDiamond _d,
        address _facet,
        bytes4[] memory _sels
    )
        internal
    {
        _d.proposeSelectors(
            _sels,
            _facet
        );

        _d.executeSelectorChanges(
            _sels
        );
    }

    function _wireTriangle()
        internal
    {
        MoveFacet(address(vaultA)).proposePeerVault(
            address(vaultB)
        );

        MoveFacet(address(vaultA)).proposePeerVault(
            address(vaultC)
        );

        MoveFacet(address(vaultB)).proposePeerVault(
            address(vaultA)
        );

        MoveFacet(address(vaultB)).proposePeerVault(
            address(vaultC)
        );

        MoveFacet(address(vaultC)).proposePeerVault(
            address(vaultA)
        );

        MoveFacet(address(vaultC)).proposePeerVault(
            address(vaultB)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(vaultB)
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(vaultC)
        );

        MoveFacet(address(vaultB)).executePeerVaultChange(
            address(vaultA)
        );

        MoveFacet(address(vaultB)).executePeerVaultChange(
            address(vaultC)
        );

        MoveFacet(address(vaultC)).executePeerVaultChange(
            address(vaultA)
        );

        MoveFacet(address(vaultC)).executePeerVaultChange(
            address(vaultB)
        );
    }

    function _depositOnA(
        uint256 _amount
    )
        internal
    {
        usdA.mint(
            user1,
            _amount
        );

        vm.prank(
            user1
        );

        usdA.approve(
            address(vaultA),
            _amount
        );

        vm.prank(
            user1
        );

        UserFacet(address(vaultA)).deposit(
            _amount
        );
    }

    function _moveAs(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        uint256 _amount
    )
        internal
        returns (uint256)
    {
        vm.prank(
            user1
        );

        return MoveFacet(address(_src)).moveBetweenVaults(
            address(_dst),
            _amount
        );
    }

    function _moveExpectingCapRelocation(
        WiseSovrenNodesDiamond _src,
        WiseSovrenNodesDiamond _dst,
        uint256 _amount
    )
        internal
        returns (uint256 dstAmount)
    {
        uint256 srcCapBefore = _src.totalDepositCap();
        uint256 dstCapBefore = _dst.totalDepositCap();

        uint256 srcRoomBefore = srcCapBefore
            - _src.totalSupply();

        uint256 dstRoomBefore = dstCapBefore
            - _dst.totalSupply();

        dstAmount = _moveAs(
            _src,
            _dst,
            _amount
        );

        assertEq(
            _src.totalDepositCap(),
            srcCapBefore - _amount
        );

        assertEq(
            _dst.totalDepositCap(),
            dstCapBefore + _amount
        );

        assertEq(
            _src.totalDepositCap() - _src.totalSupply(),
            srcRoomBefore
        );

        assertEq(
            _dst.totalDepositCap() - _dst.totalSupply(),
            dstRoomBefore
        );
    }

    function _assertTriangleCaps(
        uint256 _capA,
        uint256 _capB,
        uint256 _capC
    )
        internal
    {
        assertEq(
            vaultA.totalDepositCap(),
            _capA
        );

        assertEq(
            vaultB.totalDepositCap(),
            _capB
        );

        assertEq(
            vaultC.totalDepositCap(),
            _capC
        );
    }

    // ---- Cap relocation across all six directions ----

    function test_triangle_allSixDirections_capConservationRoundTrip()
        public
    {
        _depositOnA(
            AMOUNT
        );

        uint256 dst = _moveExpectingCapRelocation(
            vaultA,
            vaultB,
            AMOUNT
        );

        assertEq(
            dst,
            AMOUNT
        );

        assertEq(
            vaultA.balanceOf(user1),
            0
        );

        assertEq(
            vaultB.balanceOf(user1),
            AMOUNT
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP - AMOUNT,
            TOTAL_DEPOSIT_CAP + AMOUNT,
            TOTAL_DEPOSIT_CAP
        );

        _moveExpectingCapRelocation(
            vaultB,
            vaultC,
            AMOUNT
        );

        assertEq(
            vaultC.balanceOf(user1),
            AMOUNT
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP - AMOUNT,
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP + AMOUNT
        );

        _moveExpectingCapRelocation(
            vaultC,
            vaultA,
            AMOUNT
        );

        assertEq(
            vaultA.balanceOf(user1),
            AMOUNT
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP
        );

        _moveExpectingCapRelocation(
            vaultA,
            vaultC,
            AMOUNT
        );

        assertEq(
            vaultC.balanceOf(user1),
            AMOUNT
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP - AMOUNT,
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP + AMOUNT
        );

        _moveExpectingCapRelocation(
            vaultC,
            vaultB,
            AMOUNT
        );

        assertEq(
            vaultB.balanceOf(user1),
            AMOUNT
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP - AMOUNT,
            TOTAL_DEPOSIT_CAP + AMOUNT,
            TOTAL_DEPOSIT_CAP
        );

        _moveExpectingCapRelocation(
            vaultB,
            vaultA,
            AMOUNT
        );

        assertEq(
            vaultA.balanceOf(user1),
            AMOUNT
        );

        assertEq(
            vaultB.balanceOf(user1),
            0
        );

        assertEq(
            vaultC.balanceOf(user1),
            0
        );

        assertEq(
            vaultA.totalSupply(),
            AMOUNT
        );

        assertEq(
            vaultB.totalSupply(),
            0
        );

        assertEq(
            vaultC.totalSupply(),
            0
        );

        _assertTriangleCaps(
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP,
            TOTAL_DEPOSIT_CAP
        );
    }

    // ---- Dormant vault (usdg posture): moves pass, deposits blocked ----

    function test_triangle_dormantVault_blocksDepositButMovesFreely()
        public
    {
        usdC.mint(
            user1,
            AMOUNT
        );

        vm.prank(
            user1
        );

        usdC.approve(
            address(vaultC),
            AMOUNT
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        UserFacet(address(vaultC)).deposit(
            AMOUNT
        );

        _depositOnA(
            AMOUNT
        );

        _moveExpectingCapRelocation(
            vaultA,
            vaultC,
            AMOUNT
        );

        assertEq(
            vaultC.balanceOf(user1),
            AMOUNT
        );

        assertEq(
            vaultC.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + AMOUNT
        );

        _moveExpectingCapRelocation(
            vaultC,
            vaultA,
            AMOUNT
        );

        assertEq(
            vaultA.balanceOf(user1),
            AMOUNT
        );

        assertEq(
            vaultC.balanceOf(user1),
            0
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            vaultC.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );
    }

    // ---- Pending interest banks into cashedInterest on the way out ----

    function test_triangle_moveWithPendingInterest_banksOnSource()
        public
    {
        _depositOnA(
            AMOUNT
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expectedInterest = AMOUNT
            * INTEREST_RATE
            / PRECISION_RATE;

        uint256 thirdPtyBefore = usdA.balanceOf(thirdPty);
        uint256 vaultUsdBefore = usdA.balanceOf(address(vaultA));

        _moveExpectingCapRelocation(
            vaultA,
            vaultB,
            AMOUNT
        );

        assertEq(
            vaultB.balanceOf(user1),
            AMOUNT
        );

        assertEq(
            vaultA.balanceOf(user1),
            0
        );

        assertEq(
            vaultA.cashedInterest(user1),
            expectedInterest
        );

        assertEq(
            usdA.balanceOf(thirdPty),
            thirdPtyBefore
        );

        assertEq(
            usdA.balanceOf(address(vaultA)),
            vaultUsdBefore
        );
    }

    // ---- Half-wired directions fail closed ----

    function test_triangle_missingReverseRegistration_reverts()
        public
    {
        WiseSovrenNodesDiamond vaultD = _deployVault(
            address(new MockUSD6())
        );

        MoveFacet(address(vaultA)).proposePeerVault(
            address(vaultD)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(vaultD)
        );

        _depositOnA(
            AMOUNT
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotPeerVault.selector
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultD),
            AMOUNT
        );
    }

    function test_triangle_unregisteredDestination_reverts()
        public
    {
        WiseSovrenNodesDiamond vaultD = _deployVault(
            address(new MockUSD6())
        );

        _depositOnA(
            AMOUNT
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.PeerVaultNotEnabled.selector
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultD),
            AMOUNT
        );
    }
}
