// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesQueueStructs} from "../../src/diamond/vault/WiseSovrenNodesQueueStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

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
 * @dev Fee-quoting sink for outbound bridges: `getFee` returns a flat
 * fee and `ccipSend` just mints a message id. No relay — the gate
 * tests only assert that outbound bridging stays open while the
 * deposit gate is closed.
 */
contract MockRouterSink {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return FIXED_FEE;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata
    )
        external
        payable
        returns (bytes32 messageId)
    {
        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                nonce
            )
        );

        nonce++;
    }
}

/**
 * @dev Tests for the master-gated `depositsDisabled` flag: every
 * share-minting deposit entrypoint (direct, combos, Permit2) must
 * revert while the gate is closed, and everything else — inbound
 * `ccipReceive` mints, outbound bridging, queue joins, incentive
 * switches, queue leaves and transfers — must keep working, so a
 * dormant chain stays fully wired into the mesh. Queue operations
 * only move already-minted shares, not new capital, so they are
 * never gated. Re-enabling restores deposits.
 */
contract WiseSovrenNodesDepositGateTest is DiamondTestHarness {

    event DepositsDisabledSet(
        bool depositsDisabled
    );

    uint64 internal constant REMOTE_SELECTOR = 1111;

    address internal remotePeer = address(0xBEEF);
    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    MockRouterSink internal router;

    function setUp()
        public
    {
        usd = new MockUSD();
        router = new MockRouterSink();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireQueueFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors.bridgeSelectors()
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            REMOTE_SELECTOR,
            remotePeer,
            6
        );

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            REMOTE_SELECTOR
        );

        diamond.finalizeSetup();
    }

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

    function _disableDeposits()
        internal
    {
        AdminFacet(address(diamond)).setDepositsDisabled(
            true
        );
    }

    // ---- 1. setter access control ----

    function test_setDepositsDisabled_nonMasterReverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setDepositsDisabled(
            true
        );
    }

    function test_setDepositsDisabled_directFacetCallReverts()
        public
    {
        AdminFacet facet = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.setDepositsDisabled(
            true
        );
    }

    // ---- 2. setter toggles state and emits ----

    function test_setDepositsDisabled_togglesStateAndEmits()
        public
    {
        assertEq(
            diamond.depositsDisabled(),
            false
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositsDisabledSet(
            true
        );

        AdminFacet(address(diamond)).setDepositsDisabled(
            true
        );

        assertEq(
            diamond.depositsDisabled(),
            true
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit DepositsDisabledSet(
            false
        );

        AdminFacet(address(diamond)).setDepositsDisabled(
            false
        );

        assertEq(
            diamond.depositsDisabled(),
            false
        );
    }

    // ---- 3. direct deposits revert while disabled ----

    function test_deposit_revertsWhenDepositsDisabled()
        public
    {
        _fundAndApprove(
            user1,
            1_000 * 1e6
        );

        _disableDeposits();

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );
    }

    function test_depositCombos_revertWhenDepositsDisabled()
        public
    {
        _fundAndApprove(
            user1,
            2_000 * 1e6
        );

        _disableDeposits();

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        UserFacet(address(diamond)).depositAndClaimInterest(
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        UserFacet(address(diamond)).depositAndCompoundInterest(
            1_000 * 1e6
        );
    }

    // ---- 4. Permit2 deposits revert while disabled ----

    function test_permit2Deposits_revertWhenDepositsDisabled()
        public
    {
        _disableDeposits();

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            1_000 * 1e6,
            0,
            block.timestamp,
            ""
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        Permit2UserFacet(address(diamond)).depositAndClaimInterestWithPermit2(
            1_000 * 1e6,
            0,
            block.timestamp,
            ""
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        Permit2UserFacet(address(diamond)).depositAndCompoundInterestWithPermit2(
            1_000 * 1e6,
            0,
            block.timestamp,
            ""
        );
    }

    // ---- 5. queue joins keep working while disabled ----

    function test_joinQue_worksWhenDepositsDisabled()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        _disableDeposits();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            500 * 1e6,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            500 * 1e6
        );

        assertEq(
            diamond.balanceOf(address(diamond)),
            500 * 1e6
        );
    }

    // ---- 5b. incentive switches keep working while disabled ----

    function test_switchQueIncentive_worksWhenDepositsDisabled()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
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

        _disableDeposits();

        vm.prank(
            user1
        );

        (
            WiseSovrenNodesQueueStructs.QueMember memory newMember,
        ) = QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            id,
            0,
            100
        );

        assertEq(
            newMember.amount,
            500 * 1e6
        );

        assertEq(
            diamond.balanceOf(address(diamond)),
            500 * 1e6
        );
    }

    // ---- 6. inbound bridge mints keep working while disabled ----

    function test_ccipReceive_mintsWhenDepositsDisabled()
        public
    {
        _disableDeposits();

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_SELECTOR,
            sender: abi.encode(remotePeer),
            data: abi.encode(user1, uint256(500 * 1e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        IAny2EVMMessageReceiver(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            diamond.balanceOf(user1),
            500 * 1e6
        );
    }

    // ---- 7. outbound bridging keeps working while disabled ----

    function test_bridgeOut_worksWhenDepositsDisabled()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        _disableDeposits();

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(diamond)).bridgeToVault{
            value: 0.01 ether
        }(
            REMOTE_SELECTOR,
            400 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            600 * 1e6
        );
    }

    // ---- 8. queue leaves keep working while disabled ----

    function test_leaveQue_worksWhenDepositsDisabled()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
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

        _disableDeposits();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            1_000 * 1e6
        );
    }

    // ---- 9. transfers keep working while disabled ----

    function test_transfer_worksWhenDepositsDisabled()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        _disableDeposits();

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            250 * 1e6
        );

        assertEq(
            diamond.balanceOf(user2),
            250 * 1e6
        );
    }

    // ---- 10. re-enabling restores deposits ----

    function test_reenable_restoresDeposits()
        public
    {
        _fundAndApprove(
            user1,
            1_000 * 1e6
        );

        _disableDeposits();

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).setDepositsDisabled(
            false
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            1_000 * 1e6
        );
    }
}
