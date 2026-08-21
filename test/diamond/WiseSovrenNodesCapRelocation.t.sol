// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

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
 * @dev Minimal copy of the Bridge suite's router mock: `getFee`
 * returns a flat fee and `ccipSend` synchronously relays the message
 * to the destination diamond's `ccipReceive`, so a bridge asserts
 * end-to-end inside one test transaction.
 */
contract MockCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    mapping(address => uint64) public selectorOf;

    function setSelector(
        address _diamond,
        uint64 _selector
    )
        external
    {
        selectorOf[_diamond] = _selector;
    }

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
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        address dest = abi.decode(
            _message.receiver,
            (address)
        );

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                nonce
            )
        );

        nonce++;

        Client.Any2EVMMessage memory any2 = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: selectorOf[msg.sender],
            sender: abi.encode(msg.sender),
            data: _message.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        IAny2EVMMessageReceiver(dest).ccipReceive(
            any2
        );
    }
}

/**
 * @dev Cap-relocation suite: share relocations move `totalDepositCap`
 * with them. Every relocation-out site (`moveBetweenVaults` /
 * `bridgeToVault`) burns and then lowers the local cap by the burned
 * amount, every relocation-in site (`mintFromPeer` / `ccipReceive`)
 * raises the local cap by the minted amount before the mint, and each
 * site emits `DepositCapRelocated` with the new cap. The invariants
 * under test: local room (`totalDepositCap - totalSupply()`) is
 * unchanged on BOTH ends of every relocation, the mesh-wide cap sum
 * is conserved by user flows (minus scale-down dust, which leaves the
 * mesh together with the burned supply), and `totalSupply()` can
 * never exceed `totalDepositCap`. `_checkDepositCap` is the plain
 * legacy formula `totalSupply() + amount > totalDepositCap`, gating
 * deposits, all compound paths and `mintSupply`. Two CCIP-wired
 * diamonds (`vaultA`, `vaultB`) are also registered as same-chain
 * move peers; `vaultB` carries the queue facets for the
 * compound-via-fulfill path.
 */
contract WiseSovrenNodesCapRelocationTest is DiamondTestHarness {

    MockCCIPRouter router;

    MockUSD usdA;
    MockUSD usdB;

    WiseSovrenNodesDiamond vaultA;
    WiseSovrenNodesDiamond vaultB;

    address user = address(0xA1);
    address depositor = address(0xA2);
    address recvUser = address(0xB0B);
    address filler = address(0xF11);
    address comp = address(0xC0FFEE);

    uint64 constant SELECTOR_A = 1111;
    uint64 constant SELECTOR_B = 2222;

    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant PEER_VAULT_CHANGE_DELAY = 3 days;
    uint256 constant CROSS_CHAIN_PEER_CHANGE_DELAY = 3 days;
    uint256 constant FEE = 0.01 ether;

    uint256 internal nextMessageId = 0xBEEF0000;

    event DepositCapRelocated(
        uint256 newTotalDepositCap
    );

    event MovedOut(
        address indexed user,
        address indexed dstVault,
        uint256 srcAmount,
        uint256 dstAmount
    );

    event MovedIn(
        address indexed user,
        address indexed srcVault,
        uint256 amount
    );

    event MoveDust(
        address indexed user,
        address indexed dstVault,
        uint256 dustAmount
    );

    event BridgeSent(
        address indexed user,
        uint64 indexed destChainSelector,
        uint256 srcAmount,
        uint256 dstAmount,
        bytes32 messageId
    );

    event BridgeReceived(
        address indexed user,
        uint64 indexed srcChainSelector,
        uint256 amount,
        bytes32 messageId
    );

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        router = new MockCCIPRouter();

        usdA = new MockUSD();
        usdB = new MockUSD();

        vaultA = _deployBridgedDiamond(
            address(usdA)
        );

        vaultB = _deployBridgedDiamond(
            address(usdB)
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridge(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridge(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();
        vaultB.finalizeSetup();

        _registerSameChainPeers();

        usdA.mint(
            address(vaultA),
            100_000_000 * 1e6
        );

        usdB.mint(
            address(vaultB),
            100_000_000 * 1e6
        );
    }

    // ---- Deployment helpers ----

    function _deployBridgedDiamond(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireQueueFacets(
            d
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors.bridgeSelectors()
        );
    }

    function _wireBridge(
        WiseSovrenNodesDiamond _vault,
        uint64 _peerSelector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _peerSelector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _peerSelector
        );
    }

    function _registerSameChainPeers()
        internal
    {
        MoveFacet(address(vaultA)).proposePeerVault(
            address(vaultB)
        );

        MoveFacet(address(vaultB)).proposePeerVault(
            address(vaultA)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(vaultA)).executePeerVaultChange(
            address(vaultB)
        );

        MoveFacet(address(vaultB)).executePeerVaultChange(
            address(vaultA)
        );
    }

    // ---- Scenario helpers ----

    function _bridgeIn(
        WiseSovrenNodesDiamond _vault,
        uint64 _srcSelector,
        address _srcPeer,
        address _user,
        uint256 _amount
    )
        internal
    {
        nextMessageId++;

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(nextMessageId),
            sourceChainSelector: _srcSelector,
            sender: abi.encode(_srcPeer),
            data: abi.encode(_user, _amount),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(_vault)).ccipReceive(
            message
        );
    }

    function _bridgeInA(
        address _user,
        uint256 _amount
    )
        internal
    {
        _bridgeIn(
            vaultA,
            SELECTOR_B,
            address(vaultB),
            _user,
            _amount
        );
    }

    function _bridgeInB(
        address _user,
        uint256 _amount
    )
        internal
    {
        _bridgeIn(
            vaultB,
            SELECTOR_A,
            address(vaultA),
            _user,
            _amount
        );
    }

    function _depositAs(
        WiseSovrenNodesDiamond _vault,
        MockUSD _usd,
        address _user,
        uint256 _amount
    )
        internal
    {
        _usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usd.approve(
            address(_vault),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_vault)).deposit(
            _amount
        );
    }

    function _expectDepositExceedCapDeposit(
        WiseSovrenNodesDiamond _vault,
        MockUSD _usd,
        address _user,
        uint256 _amount
    )
        internal
    {
        _usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usd.approve(
            address(_vault),
            _amount
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        vm.prank(
            _user
        );

        UserFacet(address(_vault)).deposit(
            _amount
        );
    }

    function _roomOf(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (uint256)
    {
        return _vault.totalDepositCap() - _vault.totalSupply();
    }

    // ---- 1. bridge-in grows cap and supply equally, deposit within old room succeeds ----

    function test_deposit_afterBridgeIn_roomUnchanged_succeeds()
        public
    {
        uint256 room = 500 * 1e6;
        uint256 bridged = 10_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - room
        );

        _bridgeInB(
            recvUser,
            bridged
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        assertEq(
            _roomOf(vaultB),
            room
        );

        _depositAs(
            vaultB,
            usdB,
            depositor,
            room
        );

        assertEq(
            vaultB.balanceOf(depositor),
            room
        );

        assertEq(
            vaultB.totalSupply(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        assertEq(
            _roomOf(vaultB),
            0
        );
    }

    // ---- 2. one unit beyond the unchanged room still reverts ----

    function test_deposit_beyondRoomAfterBridgeIn_reverts()
        public
    {
        uint256 room = 500 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - room
        );

        _bridgeInB(
            recvUser,
            10_000 * 1e6
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            room + 1
        );
    }

    // ---- 3. compoundInterest succeeds within the room bridge-in left unchanged ----

    function test_compoundInterest_afterBridgeIn_succeedsWithinRoom()
        public
    {
        uint256 principal = 100_000 * 1e6;
        uint256 room = 5_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - principal - room
        );

        _bridgeInB(
            recvUser,
            50_000 * 1e6
        );

        assertEq(
            _roomOf(vaultB),
            room
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 pending = vaultB.getPendingInterest(
            user
        );

        assertGt(
            pending,
            0
        );

        assertLt(
            pending,
            room
        );

        vm.prank(
            user
        );

        uint256 compounded = UserFacet(address(vaultB)).compoundInterest();

        assertEq(
            compounded,
            pending
        );

        assertEq(
            vaultB.balanceOf(user),
            principal + pending
        );

        assertEq(
            vaultB.cashedInterest(user),
            0
        );
    }

    // ---- 4. queue compound-via-fulfill remainder succeeds within the unchanged room ----

    function test_compoundViaFulfillBulk_afterBridgeIn_succeedsWithinRoom()
        public
    {
        uint256 principal = 10_000 * 1e6;
        uint256 orderAmount = 100 * 1e6;
        uint256 room = 5_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            comp,
            principal
        );

        AdminFacet(address(vaultB)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - 2 * principal - room
        );

        _bridgeInB(
            recvUser,
            50_000 * 1e6
        );

        assertEq(
            _roomOf(vaultB),
            room
        );

        vm.prank(
            user
        );

        IERC20(address(vaultB)).approve(
            address(vaultB),
            type(uint256).max
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        vm.prank(
            user
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(vaultB)).joinQue(
            orderAmount,
            0
        );

        uint256 pendingComp = vaultB.getPendingInterest(
            comp
        );

        assertGt(
            pendingComp,
            orderAmount
        );

        uint256 compBalanceBefore = vaultB.balanceOf(
            comp
        );

        int256[] memory incs = new int256[](1);
        incs[0] = 0;

        uint256[] memory orders = new uint256[](1);
        orders[0] = id;

        uint256[] memory partials = new uint256[](0);

        vm.prank(
            comp
        );

        (
            uint256 received,
            uint256 spent
        ) = QueueFulfillFacet(address(vaultB)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(
            spent,
            orderAmount
        );

        assertGt(
            received,
            0
        );

        assertEq(
            vaultB.cashedInterest(comp),
            0
        );

        assertEq(
            vaultB.balanceOf(comp),
            compBalanceBefore + received + pendingComp - spent
        );
    }

    // ---- 5. peer mint-in at full cap succeeds and stays room-neutral ----

    function test_mintFromPeer_atFullCap_succeeds_roomNeutral()
        public
    {
        uint256 amount = 500 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        vm.prank(
            address(vaultA)
        );

        MoveFacet(address(vaultB)).mintFromPeer(
            user,
            amount
        );

        assertEq(
            vaultB.balanceOf(user),
            amount
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + amount
        );

        assertEq(
            _roomOf(vaultB),
            0
        );
    }

    // ---- 6. move at full cap on both ends banks pending interest, no compound ----

    function test_moveBetweenVaults_atFullCap_banksPendingInterest()
        public
    {
        uint256 principal = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultA)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - principal
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            _roomOf(vaultA),
            0
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 pending = vaultA.getPendingInterest(
            user
        );

        assertGt(
            pending,
            0
        );

        vm.prank(
            user
        );

        uint256 dstAmount = MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultB),
            principal
        );

        assertEq(
            dstAmount,
            principal
        );

        assertEq(
            vaultB.balanceOf(user),
            principal
        );

        assertEq(
            vaultA.balanceOf(user),
            0
        );

        assertEq(
            vaultA.cashedInterest(user),
            pending
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP - principal
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + principal
        );

        assertEq(
            _roomOf(vaultA),
            0
        );

        assertEq(
            _roomOf(vaultB),
            0
        );
    }

    // ---- 7. master mintSupply within the unchanged room, boundary +1 reverts ----

    function test_mintSupply_afterBridgeIn_roomUnchangedBoundary()
        public
    {
        uint256 room = 500 * 1e6;
        uint256 bridged = 10_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - room
        );

        _bridgeInB(
            recvUser,
            bridged
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        AdminFacet(address(vaultB)).mintSupply(
            user,
            room
        );

        assertEq(
            vaultB.balanceOf(user),
            room
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        AdminFacet(address(vaultB)).mintSupply(
            user,
            1
        );
    }

    // ---- 8. bridge-out takes its cap budget along, room unchanged ----

    function test_bridgeOut_reducesCap_roomUnchanged()
        public
    {
        uint256 amount = 10_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            user,
            amount
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - amount
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultB)).bridgeToVault{value: FEE}(
            SELECTOR_A,
            amount
        );

        assertEq(
            vaultB.totalSupply(),
            TOTAL_DEPOSIT_CAP - amount
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP - amount
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            1
        );
    }

    // ---- 9. compound larger than the room still reverts ----

    function test_compound_exceedsRoom_reverts()
        public
    {
        uint256 principal = 100_000 * 1e6;
        uint256 room = 10 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - principal - room
        );

        _bridgeInB(
            recvUser,
            50_000 * 1e6
        );

        assertEq(
            _roomOf(vaultB),
            room
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 pending = vaultB.getPendingInterest(
            user
        );

        assertGt(
            pending,
            room
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        vm.prank(
            user
        );

        UserFacet(address(vaultB)).compoundInterest();
    }

    // ---- 10. cap boundary matches the legacy raw-cap formula ----

    function test_capSemantics_matchesLegacyBoundary()
        public
    {
        uint256 depositAmount = 1_000 * 1e6;

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - depositAmount
        );

        _depositAs(
            vaultB,
            usdB,
            depositor,
            depositAmount
        );

        assertEq(
            vaultB.totalSupply(),
            TOTAL_DEPOSIT_CAP
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            1
        );
    }

    // ---- 11. DepositCapRelocated on all four relocation sites, correct values and order ----

    function test_depositCapRelocated_emittedOnAllFourRelocationSites()
        public
    {
        uint256 outAmount = 10_000 * 1e6;
        uint256 backAmount = 4_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            outAmount
        );

        vm.deal(
            user,
            1 ether
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP - outAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP + outAmount
        );

        vm.expectEmit(
            true,
            true,
            false,
            false,
            address(vaultB)
        );

        emit BridgeReceived(
            user,
            SELECTOR_A,
            outAmount,
            bytes32(0)
        );

        vm.expectEmit(
            true,
            true,
            false,
            false,
            address(vaultA)
        );

        emit BridgeSent(
            user,
            SELECTOR_B,
            outAmount,
            outAmount,
            bytes32(0)
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            outAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP + outAmount - backAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit MovedOut(
            user,
            address(vaultA),
            backAmount,
            backAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP - outAmount + backAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit MovedIn(
            user,
            address(vaultB),
            backAmount
        );

        vm.prank(
            user
        );

        MoveFacet(address(vaultB)).moveBetweenVaults(
            address(vaultA),
            backAmount
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP - outAmount + backAmount
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + outAmount - backAmount
        );
    }

    // ---- 12. audit-DoS repro: bridge-out after locals fill the room strands nothing ----

    function test_bridgeOutAfterLocalsFillRoom_capFollowsShares_noStrandedRoom()
        public
    {
        uint256 bridged = 3_000_000 * 1e6;

        _bridgeInB(
            recvUser,
            bridged
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        assertEq(
            _roomOf(vaultB),
            TOTAL_DEPOSIT_CAP
        );

        AdminFacet(address(vaultB)).mintSupply(
            user,
            bridged
        );

        _depositAs(
            vaultB,
            usdB,
            depositor,
            TOTAL_DEPOSIT_CAP - bridged
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            1
        );

        uint256 capBefore = vaultB.totalDepositCap();
        uint256 supplyBefore = vaultB.totalSupply();

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultB)).bridgeToVault{value: FEE}(
            SELECTOR_A,
            bridged
        );

        assertEq(
            vaultB.totalDepositCap(),
            capBefore - bridged
        );

        assertEq(
            vaultB.totalSupply(),
            supplyBefore - bridged
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            1
        );

        _bridgeInB(
            recvUser,
            bridged
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        assertEq(
            vaultB.totalSupply(),
            TOTAL_DEPOSIT_CAP + bridged
        );

        assertEq(
            _roomOf(vaultB),
            0
        );

        _expectDepositExceedCapDeposit(
            vaultB,
            usdB,
            depositor,
            1
        );
    }

    // ---- 13. A -> B -> A round trip restores genesis caps and supplies exactly ----

    function test_roundTrip_restoresGenesisCapsAndSupplies()
        public
    {
        uint256 amount = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            amount
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            amount
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP - amount
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + amount
        );

        vm.prank(
            user
        );

        MoveFacet(address(vaultB)).moveBetweenVaults(
            address(vaultA),
            amount
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            vaultA.totalSupply(),
            amount
        );

        assertEq(
            vaultB.totalSupply(),
            0
        );

        assertEq(
            vaultA.balanceOf(user),
            amount
        );

        assertEq(
            vaultB.balanceOf(user),
            0
        );
    }

    // ---- 14. move is room-neutral on both ends in one tx ----

    function test_move_roomNeutralOnBothEnds()
        public
    {
        uint256 principal = 10_000 * 1e6;
        uint256 roomA = 7_000 * 1e6;
        uint256 roomB = 3_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultA)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - principal - roomA
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - roomB
        );

        uint256 capABefore = vaultA.totalDepositCap();
        uint256 capBBefore = vaultB.totalDepositCap();
        uint256 roomABefore = _roomOf(vaultA);
        uint256 roomBBefore = _roomOf(vaultB);

        vm.prank(
            user
        );

        MoveFacet(address(vaultA)).moveBetweenVaults(
            address(vaultB),
            principal
        );

        assertEq(
            vaultA.totalDepositCap(),
            capABefore - principal
        );

        assertEq(
            vaultB.totalDepositCap(),
            capBBefore + principal
        );

        assertEq(
            _roomOf(vaultA),
            roomABefore
        );

        assertEq(
            _roomOf(vaultB),
            roomBBefore
        );
    }

    // ---- 15. bridge is room-neutral on both ends in one tx ----

    function test_bridge_roomNeutralOnBothEnds()
        public
    {
        uint256 principal = 10_000 * 1e6;
        uint256 roomA = 7_000 * 1e6;
        uint256 roomB = 3_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        AdminFacet(address(vaultA)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - principal - roomA
        );

        AdminFacet(address(vaultB)).mintSupply(
            filler,
            TOTAL_DEPOSIT_CAP - roomB
        );

        uint256 capABefore = vaultA.totalDepositCap();
        uint256 capBBefore = vaultB.totalDepositCap();
        uint256 roomABefore = _roomOf(vaultA);
        uint256 roomBBefore = _roomOf(vaultB);

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            principal
        );

        assertEq(
            vaultA.totalDepositCap(),
            capABefore - principal
        );

        assertEq(
            vaultB.totalDepositCap(),
            capBBefore + principal
        );

        assertEq(
            _roomOf(vaultA),
            roomABefore
        );

        assertEq(
            _roomOf(vaultB),
            roomBBefore
        );
    }

    // ---- 16. scale-down dust leaves the mesh with the burn, rooms stay neutral ----

    function test_bridgeOut_scaleDownDust_capFollowsBurn_roomNeutralBothEnds()
        public
    {
        uint256 srcAmount = 1_234_567_891;
        uint256 dstAmount = 1_234_567;
        uint256 dust = 891;

        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_B,
            address(vaultB),
            3
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_B
        );

        AdminFacet(address(vaultA)).mintSupply(
            user,
            srcAmount
        );

        uint256 roomABefore = _roomOf(vaultA);
        uint256 roomBBefore = _roomOf(vaultB);
        uint256 capSumBefore = vaultA.totalDepositCap() + vaultB.totalDepositCap();

        vm.deal(
            user,
            1 ether
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP - srcAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP + dstAmount
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit MoveDust(
            user,
            address(vaultB),
            dust
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            srcAmount
        );

        assertEq(
            vaultA.totalDepositCap(),
            TOTAL_DEPOSIT_CAP - srcAmount
        );

        assertEq(
            vaultB.totalDepositCap(),
            TOTAL_DEPOSIT_CAP + dstAmount
        );

        assertEq(
            vaultB.balanceOf(user),
            dstAmount
        );

        assertEq(
            _roomOf(vaultA),
            roomABefore
        );

        assertEq(
            _roomOf(vaultB),
            roomBBefore
        );

        assertEq(
            vaultA.totalDepositCap() + vaultB.totalDepositCap(),
            capSumBefore - (srcAmount - dstAmount)
        );

        assertEq(
            srcAmount - dust,
            dstAmount * 1000
        );
    }

}
