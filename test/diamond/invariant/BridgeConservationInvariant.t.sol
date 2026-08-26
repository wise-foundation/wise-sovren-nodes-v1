// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";

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
 * @dev Synchronous CCIP router stand-in: `ccipSend` relays the message
 * to the destination vault's `ccipReceive` in the same transaction, so a
 * bridge completes (burn on source, mint on destination) within one
 * handler call.
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
 * @dev Bridges a single holder's shares back and forth between two
 * peer vaults on equal decimals (zero dust). Every bridge is wrapped in
 * `try/catch`; amounts are bounded to the holder's balance on the source
 * side so the burn always has backing.
 */
contract BridgeInvariantHandler is Test {

    WiseSovrenNodesDiamond internal immutable vaultA;
    WiseSovrenNodesDiamond internal immutable vaultB;

    address internal immutable user;

    uint64 internal immutable selectorA;
    uint64 internal immutable selectorB;
    uint256 internal immutable fee;

    constructor(
        WiseSovrenNodesDiamond _vaultA,
        WiseSovrenNodesDiamond _vaultB,
        address _user,
        uint64 _selectorA,
        uint64 _selectorB,
        uint256 _fee
    ) {
        vaultA = _vaultA;
        vaultB = _vaultB;
        user = _user;
        selectorA = _selectorA;
        selectorB = _selectorB;
        fee = _fee;
    }

    function bridgeAtoB(
        uint256 _amountSeed
    )
        external
    {
        uint256 bal = vaultA.balanceOf(user);

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            user
        );

        try BridgeFacet(address(vaultA)).bridgeToVault{value: fee}(selectorB, amount) {} catch {}
    }

    function bridgeBtoA(
        uint256 _amountSeed
    )
        external
    {
        uint256 bal = vaultB.balanceOf(user);

        if (bal == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            bal
        );

        vm.prank(
            user
        );

        try BridgeFacet(address(vaultB)).bridgeToVault{value: fee}(selectorA, amount) {} catch {}
    }
}

/**
 * @dev Stateful-fuzz invariants: bridging shares between two peer
 * vaults on equal decimals conserves the combined share supply - burn
 * on the source and mint on the destination always net to zero, so
 * `vaultA.totalSupply() + vaultB.totalSupply()` never drifts from the
 * seeded total. The deposit-cap budget relocates with the shares
 * (`_reduceDepositCap` on the source, `_raiseDepositCap` on the
 * destination), and the router relays synchronously, so the combined
 * `totalDepositCap` never drifts from the genesis sum either.
 */
contract BridgeConservationInvariantTest is DiamondTestHarness {

    MockUSD usd;
    MockCCIPRouter router;

    WiseSovrenNodesDiamond vaultA;
    WiseSovrenNodesDiamond vaultB;

    BridgeInvariantHandler handler;

    address user = address(0xA1);

    uint64 constant SELECTOR_A = 1111;
    uint64 constant SELECTOR_B = 2222;
    uint256 constant FEE = 0.01 ether;
    uint256 constant INITIAL_TOTAL = 100_000_000 * 1e6;

    function setUp()
        public
    {
        usd = new MockUSD();
        router = new MockCCIPRouter();

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
            user,
            INITIAL_TOTAL
        );

        handler = new BridgeInvariantHandler(
            vaultA,
            vaultB,
            user,
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

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_combinedSupplyConserved()
        public
        view
    {
        assertEq(
            vaultA.totalSupply() + vaultB.totalSupply(),
            INITIAL_TOTAL,
            "combined cross-vault supply drifted"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_combinedCapConserved()
        public
        view
    {
        assertEq(
            vaultA.totalDepositCap() + vaultB.totalDepositCap(),
            2 * TOTAL_DEPOSIT_CAP,
            "combined cross-vault deposit cap drifted"
        );
    }
}
