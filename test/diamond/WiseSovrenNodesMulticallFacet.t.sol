// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {FacetBase} from "../../src/diamond/vault/facets/FacetBase.sol";

import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {FacetNotFound, OnlyDelegateCall, NestedMulticall} from "../../src/diamond/shared/DiamondErrors.sol";

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
        public
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Reentrant swap target: tries to re-enter `transfer` on the
 * diamond while the outer transfer still holds the reentrancy guard.
 * Test-only - never added to src/, a deploy script, or a selector
 * list.
 */
contract ReentrantTransferHookFacet is FacetBase {

    function applyTransferHook(
        address,
        address _to
    )
        external
        onlyDelegateCall
    {
        WiseSovrenNodesDiamond(payable(address(this))).transfer(
            _to,
            1
        );
    }
}

/**
 * @dev Exercises {MulticallFacet}: the delegatecall-to-self batch
 * executor. Proves single-call equivalence, `msg.sender` preservation
 * across the batch, the non-payable ETH rejection, the nested-multicall
 * guard, atomic verbatim revert bubbling, `onlyDelegateCall`, and that
 * the shared reentrancy guard neither false-trips on sequential inner
 * `nonReentrant` calls nor lets a genuine reentrant callback through.
 * The test contract is master.
 */
contract WiseSovrenNodesMulticallFacetTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address stranger = address(0xBEEF);

    uint256 constant DEPOSIT = 1_000 * 1e6;
    uint256 constant PRINCIPAL = 1_000 * 1e6;
    uint256 constant TRANSFER_AMT = 100 * 1e6;

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployDiamond(
            address(usd)
        );
    }

    // ---- helpers ----

    function _fundAndApprove(
        address _user,
        uint256 _amount
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
    }

    function _mc(
        bytes[] memory _data
    )
        internal
        returns (bytes[] memory)
    {
        return MulticallFacet(address(diamond)).multicall(
            _data
        );
    }

    // ---- empty / equivalence ----

    function test_multicall_emptyArray_returnsEmpty()
        public
    {
        bytes[] memory data = new bytes[](0);

        bytes[] memory results = _mc(
            data
        );

        assertEq(
            results.length,
            0
        );
    }

    function test_multicall_singleDeposit_equivalentToDirect()
        public
    {
        _fundAndApprove(
            user1,
            DEPOSIT
        );

        _fundAndApprove(
            user2,
            DEPOSIT
        );

        vm.prank(
            user2
        );

        UserFacet(address(diamond)).deposit(
            DEPOSIT
        );

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        _mc(
            data
        );

        assertGt(
            diamond.balanceOf(user1),
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            diamond.balanceOf(user2)
        );
    }

    function test_multicall_twoSequentialNonReentrant_succeed()
        public
    {
        _fundAndApprove(
            user2,
            DEPOSIT
        );

        vm.prank(
            user2
        );

        UserFacet(address(diamond)).deposit(
            DEPOSIT
        );

        uint256 singleShares = diamond.balanceOf(
            user2
        );

        _fundAndApprove(
            user1,
            2 * DEPOSIT
        );

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            DEPOSIT
        );
        data[1] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        _mc(
            data
        );

        assertGt(
            singleShares,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            2 * singleShares
        );
    }

    function test_multicall_returnData_decodesView()
        public
    {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            SweepFacet.getOverhang.selector
        );

        bytes[] memory results = _mc(
            data
        );

        uint256 decoded = abi.decode(
            results[0],
            (uint256)
        );

        assertEq(
            decoded,
            SweepFacet(address(diamond)).getOverhang()
        );
    }

    // ---- msg.sender preservation ----

    function test_multicall_nonMasterAdminCall_reverts_NotMaster()
        public
    {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            AdminFacet.mintSupply.selector,
            user1,
            DEPOSIT
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _mc(
            data
        );
    }

    function test_multicall_masterAdminBatch_succeeds()
        public
    {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            AdminFacet.mintSupply.selector,
            user1,
            DEPOSIT
        );

        _mc(
            data
        );

        assertEq(
            diamond.balanceOf(user1),
            DEPOSIT
        );
    }

    // ---- non-payable ----

    function test_multicall_rejectsMsgValue()
        public
    {
        vm.deal(
            address(this),
            1 ether
        );

        bytes[] memory data = new bytes[](0);

        (
            bool ok,
        ) = address(diamond).call{value: 1}(
            abi.encodeWithSelector(
                MulticallFacet.multicall.selector,
                data
            )
        );

        assertFalse(
            ok
        );
    }

    // ---- nested multicall ----

    function test_multicall_nested_firstElement_reverts()
        public
    {
        bytes[] memory inner = new bytes[](0);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            MulticallFacet.multicall.selector,
            inner
        );

        vm.expectRevert(
            NestedMulticall.selector
        );

        _mc(
            data
        );
    }

    function test_multicall_nested_secondElement_reverts_andRollsBack()
        public
    {
        _fundAndApprove(
            user1,
            DEPOSIT
        );

        bytes[] memory inner = new bytes[](0);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            DEPOSIT
        );
        data[1] = abi.encodeWithSelector(
            MulticallFacet.multicall.selector,
            inner
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            NestedMulticall.selector
        );

        _mc(
            data
        );

        assertEq(
            diamond.balanceOf(user1),
            0
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            0
        );
    }

    // ---- routing / bubbling ----

    function test_multicall_shortCalldata_reverts_FacetNotFound()
        public
    {
        bytes[] memory data = new bytes[](1);
        data[0] = hex"abcd";

        vm.expectRevert(
            FacetNotFound.selector
        );

        _mc(
            data
        );
    }

    function test_multicall_unregisteredSelector_reverts_FacetNotFound()
        public
    {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            bytes4(0xdeadbeef)
        );

        vm.expectRevert(
            FacetNotFound.selector
        );

        _mc(
            data
        );
    }

    // ---- onlyDelegateCall ----

    function test_multicall_directCallOnFacet_reverts_OnlyDelegateCall()
        public
    {
        MulticallFacet standalone = new MulticallFacet();

        bytes[] memory data = new bytes[](0);

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        standalone.multicall(
            data
        );
    }

    // ---- reentrancy ----

    function test_multicall_reentrantInnerCall_blockedByGuard()
        public
    {
        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new ReentrantTransferHookFacet())
        );

        vm.warp(
            block.timestamp + 3 days + 1
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        AdminFacet(address(diamond)).mintSupply(
            user1,
            PRINCIPAL
        );

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSignature(
            "transfer(address,uint256)",
            user2,
            TRANSFER_AMT
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        _mc(
            data
        );
    }
}
