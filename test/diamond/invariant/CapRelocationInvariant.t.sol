// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";

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
 * @dev Asynchronous CCIP router stand-in: `ccipSend` queues the
 * message instead of relaying it, and `deliver` pushes a queued
 * message into the destination vault's `ccipReceive` on demand. The
 * handler picks queue indices at random, so messages arrive
 * out-of-order relative to send order, and delivering an
 * already-delivered index replays the exact same `messageId`.
 */
contract MockAsyncCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    mapping(address => uint64) public selectorOf;

    struct QueuedMessage {
        address dest;
        bool delivered;
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sourceSender;
        bytes data;
    }

    QueuedMessage[] internal queue;

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

        queue.push(
            QueuedMessage({
                dest: dest,
                delivered: false,
                messageId: messageId,
                sourceChainSelector: selectorOf[msg.sender],
                sourceSender: msg.sender,
                data: _message.data
            })
        );
    }

    function deliver(
        uint256 _index
    )
        external
    {
        QueuedMessage storage queued = queue[_index];

        Client.Any2EVMMessage memory any2 = Client.Any2EVMMessage({
            messageId: queued.messageId,
            sourceChainSelector: queued.sourceChainSelector,
            sender: abi.encode(queued.sourceSender),
            data: queued.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        IAny2EVMMessageReceiver(queued.dest).ccipReceive(
            any2
        );

        queued.delivered = true;
    }

    function queueLength()
        external
        view
        returns (uint256)
    {
        return queue.length;
    }

    function isDelivered(
        uint256 _index
    )
        external
        view
        returns (bool)
    {
        return queue[_index].delivered;
    }

    function destOf(
        uint256 _index
    )
        external
        view
        returns (address)
    {
        return queue[_index].dest;
    }
}

/**
 * @dev Fuzz actions over the two-vault async-router harness:
 * bridge-out (burn + cap reduction + queue), delayed message delivery
 * (out-of-order by random index), replay attempts on delivered
 * messages, local deposits, interest compounds, master burns and
 * master cap resets.
 *
 * Ghost accounting: `expectedRoom` starts at each vault's live room
 * `totalDepositCap - totalSupply()` and is adjusted by local
 * originations (deposit and compound consume it), master burns
 * (burnSupply frees `amount` of it) and cap resets (setTotalDepositCap
 * rebases it to `newCap - totalSupply()`). Relocations never touch it:
 * a bridge-out burns shares and lowers the cap equally, a delivery
 * raises the cap and mints equally, so both ends are room-neutral;
 * replays adjust nothing. A replay that mints (or moves the cap) flips
 * `replayViolation`.
 */
contract CapRelocationHandler is Test {

    MockUSD internal immutable usd;
    MockAsyncCCIPRouter internal immutable router;

    WiseSovrenNodesDiamond internal immutable vaultA;
    WiseSovrenNodesDiamond internal immutable vaultB;

    address internal immutable master;

    uint64 internal immutable selectorA;
    uint64 internal immutable selectorB;
    uint256 internal immutable fee;

    address[] internal users;

    mapping(address => int256) public expectedRoom;

    bool public replayViolation;

    uint256 internal constant MAX_DEPOSIT = 1_000_000 * 1e6;
    uint256 internal constant MAX_CAP_ROOM = 2_000_000_000 * 1e6;

    constructor(
        MockUSD _usd,
        MockAsyncCCIPRouter _router,
        WiseSovrenNodesDiamond _vaultA,
        WiseSovrenNodesDiamond _vaultB,
        address _master,
        address[] memory _users,
        uint64 _selectorA,
        uint64 _selectorB,
        uint256 _fee
    ) {
        usd = _usd;
        router = _router;
        vaultA = _vaultA;
        vaultB = _vaultB;
        master = _master;
        users = _users;
        selectorA = _selectorA;
        selectorB = _selectorB;
        fee = _fee;

        expectedRoom[address(_vaultA)] = _roomOf(
            _vaultA
        );

        expectedRoom[address(_vaultB)] = _roomOf(
            _vaultB
        );
    }

    function bridgeOut(
        uint256 _userSeed,
        uint256 _vaultSeed,
        uint256 _amountSeed
    )
        external
    {
        (
            WiseSovrenNodesDiamond src,
            uint64 dstSelector
        ) = _pickLane(
            _vaultSeed
        );

        address user = _pickUser(
            _userSeed
        );

        uint256 bal = src.balanceOf(
            user
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.deal(
            user,
            fee
        );

        vm.prank(
            user
        );

        try BridgeFacet(address(src)).bridgeToVault{value: fee}(dstSelector, amount) {} catch {}
    }

    function deliverMessage(
        uint256 _indexSeed
    )
        external
    {
        uint256 count = router.queueLength();

        if (count == 0) {
            return;
        }

        uint256 start = bound(
            _indexSeed,
            0,
            count - 1
        );

        for (uint256 i; i < count; i++) {

            uint256 index = (start + i) % count;

            if (router.isDelivered(index) == true) {
                continue;
            }

            router.deliver(
                index
            );

            return;
        }
    }

    function replayMessage(
        uint256 _indexSeed
    )
        external
    {
        uint256 count = router.queueLength();

        if (count == 0) {
            return;
        }

        uint256 start = bound(
            _indexSeed,
            0,
            count - 1
        );

        for (uint256 i; i < count; i++) {

            uint256 index = (start + i) % count;

            if (router.isDelivered(index) == false) {
                continue;
            }

            _attemptReplay(
                index
            );

            return;
        }
    }

    function depositLocal(
        uint256 _userSeed,
        uint256 _vaultSeed,
        uint256 _amountSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        address user = _pickUser(
            _userSeed
        );

        uint256 amount = bound(
            _amountSeed,
            1,
            MAX_DEPOSIT
        );

        usd.mint(
            user,
            amount
        );

        vm.startPrank(
            user
        );

        usd.approve(
            address(vault),
            amount
        );

        try UserFacet(address(vault)).deposit(amount) {
            expectedRoom[address(vault)] -= int256(amount);
        } catch {}

        vm.stopPrank();
    }

    function compound(
        uint256 _userSeed,
        uint256 _vaultSeed,
        uint256 _warpSeed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(
                _warpSeed,
                1 hours,
                30 days
            )
        );

        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        address user = _pickUser(
            _userSeed
        );

        uint256 due = vault.cashedInterest(user)
            + vault.getPendingInterest(user);

        if (due == 0) {
            return;
        }

        usd.mint(
            address(vault),
            due
        );

        vm.prank(
            user
        );

        try UserFacet(address(vault)).compoundInterest() returns (uint256 interest) {
            expectedRoom[address(vault)] -= int256(interest);
        } catch {}
    }

    function burnSupplyAction(
        uint256 _userSeed,
        uint256 _vaultSeed,
        uint256 _amountSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        address user = _pickUser(
            _userSeed
        );

        uint256 bal = vault.balanceOf(
            user
        );

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            master
        );

        try AdminFacet(address(vault)).burnSupply(user, amount) {
            expectedRoom[address(vault)] += int256(amount);
        } catch {}
    }

    function setCapAction(
        uint256 _vaultSeed,
        uint256 _capSeed
    )
        external
    {
        WiseSovrenNodesDiamond vault = _pickVault(
            _vaultSeed
        );

        uint256 supply = vault.totalSupply();

        uint256 newCap = bound(
            _capSeed,
            supply,
            supply + MAX_CAP_ROOM
        );

        vm.prank(
            master
        );

        try AdminFacet(address(vault)).setTotalDepositCap(newCap) {
            expectedRoom[address(vault)] = int256(newCap)
                - int256(supply);
        } catch {}
    }

    function _attemptReplay(
        uint256 _index
    )
        internal
    {
        WiseSovrenNodesDiamond dest = router.destOf(_index) == address(vaultA)
            ? vaultA
            : vaultB;

        uint256 capBefore = dest.totalDepositCap();
        uint256 supplyBefore = dest.totalSupply();

        try router.deliver(_index) {
            replayViolation = true;
        } catch {}

        if (dest.totalDepositCap() != capBefore) {
            replayViolation = true;
        }

        if (dest.totalSupply() != supplyBefore) {
            replayViolation = true;
        }
    }

    function _pickLane(
        uint256 _seed
    )
        internal
        view
        returns (
            WiseSovrenNodesDiamond src,
            uint64 dstSelector
        )
    {
        if (_seed % 2 == 0) {
            return (
                vaultA,
                selectorB
            );
        }

        return (
            vaultB,
            selectorA
        );
    }

    function _pickVault(
        uint256 _seed
    )
        internal
        view
        returns (WiseSovrenNodesDiamond)
    {
        return _seed % 2 == 0
            ? vaultA
            : vaultB;
    }

    function _pickUser(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return users[_seed % users.length];
    }

    function _roomOf(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (int256)
    {
        return int256(_vault.totalDepositCap())
            - int256(_vault.totalSupply());
    }
}

/**
 * @dev Stateful-fuzz invariants for the cap-relocation redesign:
 * across any interleaving of bridge sends, out-of-order deliveries,
 * replay attempts, deposits, compounds, master burns and master cap
 * resets, each vault's room `totalDepositCap - totalSupply()` tracks
 * local originations, burns and cap resets exactly (bridge-out and
 * bridge-in relocate cap and supply equally, so both are
 * room-neutral), `totalSupply()` never exceeds `totalDepositCap`
 * (the global SUP-1 law), and a replayed bridge message is never
 * processed a second time.
 */
contract CapRelocationInvariantTest is DiamondTestHarness {

    MockUSD usd;
    MockAsyncCCIPRouter router;

    WiseSovrenNodesDiamond vaultA;
    WiseSovrenNodesDiamond vaultB;

    CapRelocationHandler handler;

    address userOne = address(0xA1);
    address userTwo = address(0xA2);
    address userThree = address(0xA3);

    uint64 constant SELECTOR_A = 1111;
    uint64 constant SELECTOR_B = 2222;
    uint256 constant FEE = 0.01 ether;
    uint256 constant SEED_A = 100_000_000 * 1e6;
    uint256 constant SEED_B = 50_000_000 * 1e6;

    function setUp()
        public
    {
        usd = new MockUSD();
        router = new MockAsyncCCIPRouter();

        vm.warp(
            1_700_000_000
        );

        vaultA = _deployBridgeVault(
            address(usd)
        );

        vaultB = _deployBridgeVault(
            address(usd)
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridgePeer(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridgePeer(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();
        vaultB.finalizeSetup();


        AdminFacet(address(vaultA)).mintSupply(
            userOne,
            SEED_A
        );

        AdminFacet(address(vaultB)).mintSupply(
            userTwo,
            SEED_B
        );

        address[] memory users = new address[](3);
        users[0] = userOne;
        users[1] = userTwo;
        users[2] = userThree;

        handler = new CapRelocationHandler(
            usd,
            router,
            vaultA,
            vaultB,
            address(this),
            users,
            SELECTOR_A,
            SELECTOR_B,
            FEE
        );

        vm.deal(
            address(handler),
            1_000_000 ether
        );

        targetContract(
            address(handler)
        );
    }

    function _deployBridgeVault(
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

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors.bridgeSelectors()
        );
    }

    function _wireBridgePeer(
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

    function _roomOf(
        WiseSovrenNodesDiamond _vault
    )
        internal
        view
        returns (int256)
    {
        return int256(_vault.totalDepositCap())
            - int256(_vault.totalSupply());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_relocationPreservesRoom()
        public
        view
    {
        assertEq(
            _roomOf(
                vaultA
            ),
            handler.expectedRoom(
                address(vaultA)
            ),
            "vault A room drifted off the relocation ledger"
        );

        assertEq(
            _roomOf(
                vaultB
            ),
            handler.expectedRoom(
                address(vaultB)
            ),
            "vault B room drifted off the relocation ledger"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyNeverExceedsCap()
        public
        view
    {
        assertLe(
            vaultA.totalSupply(),
            vaultA.totalDepositCap(),
            "vault A totalSupply exceeds totalDepositCap"
        );

        assertLe(
            vaultB.totalSupply(),
            vaultB.totalDepositCap(),
            "vault B totalSupply exceeds totalDepositCap"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_replayNeverProcessed()
        public
        view
    {
        assertFalse(
            handler.replayViolation(),
            "replayed bridge message was processed"
        );
    }
}
