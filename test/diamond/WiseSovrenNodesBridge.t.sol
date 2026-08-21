// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

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
 * @dev Simulates the CCIP router + DON: `getFee` returns a flat fee,
 * and `ccipSend` synchronously relays the message to the destination
 * diamond's `ccipReceive` (as the DON would after finality), so a
 * bridge can be asserted end-to-end inside one test transaction. Each
 * registered diamond is mapped to the chain selector it lives on so
 * the relayed `Any2EVMMessage` carries the correct source selector.
 */
contract MockCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 internal nonce;

    bytes public lastData;

    bytes public lastExtraArgs;

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

        lastData = _message.data;
        lastExtraArgs = _message.extraArgs;

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
 * @dev Share holder that rejects native refunds, used to exercise the
 * `BridgeRefundFailed` path when `bridgeToVault` overpays the fee.
 */
contract RejectEther {

    function bridge(
        address _diamond,
        uint64 _destChainSelector,
        uint256 _amount
    )
        external
        payable
    {
        BridgeFacet(_diamond).bridgeToVault{value: msg.value}(
            _destChainSelector,
            _amount
        );
    }
}

/**
 * @dev Share holder whose `receive` hook attempts to reenter
 * `bridgeToVault` when it is handed the native refund. Used to prove
 * the diamond-wide `nonReentrant` guard blocks a reentrant callback on
 * the bridge refund path itself, not only on the transfer / multicall
 * paths. The reentry is caught so the outer bridge still completes,
 * letting the test assert both the block and the successful refund.
 */
contract ReentrantRefundRecipient {

    bool public attempted;

    string public reentryReason;

    address internal diamond;

    uint64 internal destChainSelector;

    uint256 internal reentryValue;

    function bridge(
        address _diamond,
        uint64 _destChainSelector,
        uint256 _amount,
        uint256 _value,
        uint256 _reentryValue
    )
        external
    {
        diamond = _diamond;
        destChainSelector = _destChainSelector;
        reentryValue = _reentryValue;

        BridgeFacet(_diamond).bridgeToVault{value: _value}(
            _destChainSelector,
            _amount
        );
    }

    receive()
        external
        payable
    {
        attempted = true;

        try BridgeFacet(diamond).bridgeToVault{value: reentryValue}(
            destChainSelector,
            1
        ) {
            reentryReason = "NO_REVERT";
        } catch Error(
            string memory _reason
        ) {
            reentryReason = _reason;
        } catch {
            reentryReason = "NON_STRING_REVERT";
        }
    }
}

contract WiseSovrenNodesBridgeTest is Test {

    MockCCIPRouter router;

    MockUSD usdA;
    MockUSD usdB;

    WiseSovrenNodesDiamond vaultA;
    WiseSovrenNodesDiamond vaultB;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user = address(0xA1);
    address randomEOA = address(0xBADCAFE);

    uint64 constant SELECTOR_A = 1111;
    uint64 constant SELECTOR_B = 2222;
    uint64 constant SELECTOR_C = 3333;

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    uint256 constant CROSS_CHAIN_PEER_CHANGE_DELAY = 3 days;
    uint256 constant FEE = 0.01 ether;
    uint256 constant DEFAULT_BRIDGE_GAS_LIMIT = 200_000;

    event ReferralEnabledSet(
        bool enabled
    );

    event BridgeGasLimitSet(
        uint256 gasLimit
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

        vaultA = _deploy(
            address(usdA)
        );

        vaultB = _deploy(
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
    }

    function _buildInitParams(
        address _usd
    )
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
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
        });
    }

    function _deploy(
        address _usd
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        AdminFacet admin = new AdminFacet();
        UserFacet userF = new UserFacet();
        BridgeFacet bridge = new BridgeFacet();
        CashedInterestFacet cashedF = new CashedInterestFacet();

        d = new WiseSovrenNodesDiamond(
            _buildInitParams(
                _usd
            )
        );

        bytes4[] memory adminSels = WiseSovrenNodesDiamondSelectors.adminSelectors();
        bytes4[] memory userSels = WiseSovrenNodesDiamondSelectors.userSelectors();
        bytes4[] memory bridgeSels = WiseSovrenNodesDiamondSelectors.bridgeSelectors();
        bytes4[] memory cashedSels = WiseSovrenNodesDiamondSelectors.cashedInterestSelectors();

        d.proposeSelectors(
            adminSels,
            address(admin)
        );

        d.proposeSelectors(
            userSels,
            address(userF)
        );

        d.proposeSelectors(
            bridgeSels,
            address(bridge)
        );

        d.proposeSelectors(
            cashedSels,
            address(cashedF)
        );

        d.executeSelectorChanges(
            adminSels
        );

        d.executeSelectorChanges(
            userSels
        );

        d.executeSelectorChanges(
            bridgeSels
        );

        d.executeSelectorChanges(
            cashedSels
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

    function _seedWithPriorInterest(
        WiseSovrenNodesDiamond _vault,
        address _user,
        uint256 _principal
    )
        internal
    {
        AdminFacet(address(_vault)).mintSupply(
            _user,
            _principal
        );

        vm.warp(
            block.timestamp + 30 days
        );

        AdminFacet(address(_vault)).mintSupply(
            _user,
            1
        );

        vm.warp(
            block.timestamp + 30 days
        );
    }

    // ---- 1. burn on source banks pending interest, keeps it claimable ----

    function test_bridge_banksPendingInterest_staysClaimableOnSource()
        public
    {
        uint256 principal = 100_000 * 1e6;

        _seedWithPriorInterest(
            vaultA,
            user,
            principal
        );

        uint256 balanceBefore = vaultA.balanceOf(user);
        uint256 cashedBefore = vaultA.cashedInterest(user);
        uint256 pendingBefore = vaultA.getPendingInterest(user);

        assertGt(
            cashedBefore,
            0
        );

        assertGt(
            pendingBefore,
            0
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
            balanceBefore
        );

        assertEq(
            vaultA.balanceOf(user),
            0
        );

        assertEq(
            vaultA.cashedInterest(user),
            cashedBefore + pendingBefore
        );

        assertEq(
            CashedInterestFacet(address(vaultA)).getTotalCashedInterest(),
            cashedBefore + pendingBefore
        );

        assertEq(
            vaultA.getPendingInterest(user),
            0
        );

        usdA.mint(
            address(vaultA),
            cashedBefore + pendingBefore
        );

        vm.prank(
            user
        );

        uint256 claimed = UserFacet(address(vaultA)).claimInterest();

        assertEq(
            claimed,
            cashedBefore + pendingBefore
        );

        assertEq(
            usdA.balanceOf(user),
            cashedBefore + pendingBefore
        );

        assertEq(
            CashedInterestFacet(address(vaultA)).getTotalCashedInterest(),
            0
        );
    }

    // ---- 2. destination mints fresh, accrual starts at arrival ----

    function test_bridge_mintsFreshOnDestination()
        public
    {
        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        uint256 amount = vaultA.balanceOf(user);

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
            vaultB.balanceOf(user),
            amount
        );

        assertEq(
            vaultB.cashedInterest(user),
            0
        );

        assertEq(
            vaultB.getPendingInterest(user),
            0
        );

        assertEq(
            vaultB.lastSyncTimeStamp(user),
            block.timestamp
        );

        vm.warp(
            block.timestamp + 30 days
        );

        assertGt(
            vaultB.getPendingInterest(user),
            0
        );
    }

    // ---- 3. destination with an existing balance banks prior accrual ----

    function test_bridge_destinationExistingBalance_banksPriorInterest()
        public
    {
        uint256 principalA = 100_000 * 1e6;
        uint256 principalB = 40_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principalA
        );

        AdminFacet(address(vaultB)).mintSupply(
            user,
            principalB
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 pendingOnBBefore = vaultB.getPendingInterest(user);

        assertGt(
            pendingOnBBefore,
            0
        );

        uint256 amount = vaultA.balanceOf(user);

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
            vaultB.balanceOf(user),
            principalB + amount
        );

        assertEq(
            vaultB.cashedInterest(user),
            pendingOnBBefore
        );

        assertEq(
            CashedInterestFacet(address(vaultB)).getTotalCashedInterest(),
            vaultB.cashedInterest(user)
        );

        assertEq(
            vaultB.getPendingInterest(user),
            0
        );

        assertEq(
            vaultB.lastSyncTimeStamp(user),
            block.timestamp
        );
    }

    // ---- 4. round trip closes the share balance ----

    function test_bridge_roundTrip_closesBalance()
        public
    {
        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        uint256 amount = vaultA.balanceOf(user);

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
            vaultB.balanceOf(user),
            amount
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultB)).bridgeToVault{value: FEE}(
            SELECTOR_A,
            amount
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

    // ---- 5. excess native fee is refunded ----

    function test_bridge_refundsExcessFee()
        public
    {
        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        uint256 amount = vaultA.balanceOf(user);
        uint256 fee = FEE;

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: fee + 0.05 ether}(
            SELECTOR_B,
            amount
        );

        assertEq(
            user.balance,
            1 ether - fee
        );
    }

    // ---- 6. insufficient native fee reverts ----

    function test_bridge_insufficientFee_reverts()
        public
    {
        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        uint256 amount = vaultA.balanceOf(user);
        uint256 fee = FEE;

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientBridgeFee.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: fee - 1}(
            SELECTOR_B,
            amount
        );
    }

    // ---- 7. ccipReceive from a non-router caller reverts ----

    function test_ccipReceive_nonRouter_reverts()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(1_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotCcipRouter.selector
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    // ---- 8. ccipReceive from an unregistered source selector reverts ----

    function test_ccipReceive_unregisteredSelector_reverts()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SELECTOR_C,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(1_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerNotEnabled.selector
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    // ---- 9. ccipReceive with a mismatched sender reverts ----

    function test_ccipReceive_mismatchedSender_reverts()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(randomEOA),
            data: abi.encode(user, uint256(1_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerMismatch.selector
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    // ---- 10. bridging to a disabled peer reverts ----

    function test_bridge_peerNotEnabled_reverts()
        public
    {
        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerNotEnabled.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_C,
            principal
        );
    }

    // ---- 11. cross-chain peer change is timelocked after finalize ----

    function test_crossChainPeer_timelockedAfterFinalize()
        public
    {
        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_C,
            address(0xBEEF),
            6
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerTimelockNotElapsed.selector
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_C
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_C
        );

        assertEq(
            vaultA.crossChainPeerEnabled(SELECTOR_C),
            true
        );

        assertEq(
            vaultA.crossChainPeer(SELECTOR_C),
            address(0xBEEF)
        );
    }

    // ---- 12. setCcipRouter is one-shot ----

    function test_setCcipRouter_secondCall_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.RouterAlreadySet.selector
        );

        BridgeFacet(address(vaultA)).setCcipRouter(
            address(router)
        );
    }

    // ---- 13. direct facet call reverts ----

    function test_bridgeToVault_directFacetCall_reverts()
        public
    {
        BridgeFacet bridge = new BridgeFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        bridge.bridgeToVault(
            SELECTOR_B,
            1
        );
    }

    // ---- 14. supportsInterface advertises the CCIP receiver ----

    function test_supportsInterface_ccipReceiver()
        public
        view
    {
        assertEq(
            BridgeFacet(address(vaultA)).supportsInterface(
                type(IAny2EVMMessageReceiver).interfaceId
            ),
            true
        );

        assertEq(
            BridgeFacet(address(vaultA)).supportsInterface(
                bytes4(0xffffffff)
            ),
            false
        );
    }

    // ---- 15. cancel a pending cross-chain peer proposal ----

    function test_cancelCrossChainPeerChange_clears()
        public
    {
        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_C,
            address(0xBEEF),
            6
        );

        BridgeFacet(address(vaultA)).cancelCrossChainPeerChange(
            SELECTOR_C
        );

        assertEq(
            vaultA.crossChainPeerChangeQueuedAt(SELECTOR_C),
            0
        );

        assertEq(
            vaultA.crossChainPeerEnabled(SELECTOR_C),
            false
        );
    }

    function test_cancelCrossChainPeerChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoCrossChainPeerChangeProposed.selector
        );

        BridgeFacet(address(vaultA)).cancelCrossChainPeerChange(
            SELECTOR_C
        );
    }

    // ---- 16. remove an enabled peer disables the lane ----

    function test_removeCrossChainPeer_disablesLane()
        public
    {
        BridgeFacet(address(vaultA)).removeCrossChainPeer(
            SELECTOR_B
        );

        assertEq(
            vaultA.crossChainPeerEnabled(SELECTOR_B),
            false
        );

        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerNotEnabled.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            principal
        );
    }

    // ---- 17. getBridgeableBalance is the share balance ----

    function test_getBridgeableBalance_isShareBalance()
        public
    {
        uint256 principal = 77_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        assertEq(
            BridgeFacet(address(vaultA)).getBridgeableBalance(user),
            principal
        );
    }

    // ---- 18. quoteBridgeFee returns the router fee ----

    function test_quoteBridgeFee_returnsRouterFee()
        public
        view
    {
        assertEq(
            BridgeFacet(address(vaultA)).quoteBridgeFee(
                SELECTOR_B,
                1_000 * 1e6
            ),
            FEE
        );
    }

    // ---- 19. bridging before the router is set reverts ----

    function test_bridge_routerNotSet_reverts()
        public
    {
        WiseSovrenNodesDiamond fresh = _deploy(
            address(usdA)
        );

        AdminFacet(address(fresh)).mintSupply(
            user,
            100_000 * 1e6
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.RouterNotSet.selector
        );

        BridgeFacet(address(fresh)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            100_000 * 1e6
        );
    }

    // ---- 20. destination with more decimals scales the amount up ----

    function test_bridge_scaleUp_destHigherDecimals()
        public
    {
        _registerPeerTimelocked(
            vaultA,
            SELECTOR_C,
            address(vaultB),
            8
        );

        uint256 principal = 100 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        (
            uint256 dstAmount,
        ) = BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_C,
            principal
        );

        assertEq(
            dstAmount,
            principal * 100
        );

        assertEq(
            vaultB.balanceOf(user),
            principal * 100
        );
    }

    // ---- 21. fewer destination decimals scales down and surfaces dust ----

    function test_bridge_scaleDown_emitsDust()
        public
    {
        _registerPeerTimelocked(
            vaultA,
            SELECTOR_C,
            address(vaultB),
            4
        );

        uint256 amount = 12_345;

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

        (
            uint256 dstAmount,
        ) = BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_C,
            amount
        );

        assertEq(
            dstAmount,
            123
        );

        assertEq(
            vaultB.balanceOf(user),
            123
        );
    }

    // ---- 22. a bridge that rounds to zero on the destination reverts ----

    function test_bridge_scaleDown_tooSmall_reverts()
        public
    {
        _registerPeerTimelocked(
            vaultA,
            SELECTOR_C,
            address(vaultB),
            4
        );

        uint256 amount = 50;

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

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.MoveAmountTooSmall.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_C,
            amount
        );
    }

    // ---- 23. a caller that rejects the native refund reverts ----

    function test_bridge_refundToNonPayable_reverts()
        public
    {
        RejectEther rejecter = new RejectEther();

        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            address(rejecter),
            principal
        );

        vm.deal(
            address(rejecter),
            1 ether
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.BridgeRefundFailed.selector
        );

        rejecter.bridge{value: FEE + 0.05 ether}(
            address(vaultA),
            SELECTOR_B,
            principal
        );
    }

    // ---- 24. destination at full cap still mints, cap relocates in ----

    function test_ccipReceive_atFullCap_stillMints()
        public
    {
        AdminFacet(address(vaultB)).mintSupply(
            address(0xBEEF),
            TOTAL_DEPOSIT_CAP
        );

        uint256 capBefore = vaultB.totalDepositCap();

        assertEq(
            capBefore - vaultB.totalSupply(),
            0
        );

        uint256 amount = 1_000 * 1e6;

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCAF)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, amount),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );

        assertEq(
            vaultB.balanceOf(user),
            amount
        );

        assertEq(
            vaultB.totalDepositCap(),
            capBefore + amount
        );

        assertEq(
            vaultB.totalSupply(),
            TOTAL_DEPOSIT_CAP + amount
        );

        assertEq(
            vaultB.totalDepositCap() - vaultB.totalSupply(),
            0
        );
    }

    // ---- 25. peer proposal input validation ----

    function test_proposeCrossChainPeer_zeroSelector_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            0,
            address(0xBEEF),
            6
        );
    }

    function test_proposeCrossChainPeer_zeroPeer_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_C,
            address(0),
            6
        );
    }

    // ---- 26. router input validation ----

    function test_setCcipRouter_zero_reverts()
        public
    {
        WiseSovrenNodesDiamond fresh = _deploy(
            address(usdA)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        BridgeFacet(address(fresh)).setCcipRouter(
            address(0)
        );
    }

    // ---- 27. inbound zero amount reverts ----

    function test_ccipReceive_zeroAmount_reverts()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(0)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    // ---- 28. bridging zero reverts ----

    function test_bridge_zeroAmount_reverts()
        public
    {
        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            0
        );
    }

    // ---- the interest-rate proxy cannot bridge ----

    function test_bridge_senderIsInterestRateProxy_reverts()
        public
    {
        vm.deal(
            address(vaultA),
            1 ether
        );

        vm.prank(
            address(vaultA)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InterestRateProxyCannotMove.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            1
        );
    }

    // ---- bridging above the share balance reverts ----

    function test_bridge_insufficientShareBalance_reverts()
        public
    {
        AdminFacet(address(vaultA)).mintSupply(
            user,
            100 * 1e6
        );

        uint256 amount = vaultA.balanceOf(
            user
        ) + 1;

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientBalance.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVault{value: FEE}(
            SELECTOR_B,
            amount
        );
    }

    // ---- 29. executing an unproposed peer change reverts ----

    function test_executeCrossChainPeerChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoCrossChainPeerChangeProposed.selector
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_C
        );
    }

    // ---- 30. a replayed inbound message cannot mint twice ----

    function test_ccipReceive_replayedMessage_reverts()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xABC)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(1_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );

        assertEq(
            vaultB.balanceOf(user),
            1_000
        );

        assertEq(
            vaultB.processedMessageId(bytes32(uint256(0xABC))),
            true
        );

        vm.prank(
            address(router)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.MessageAlreadyProcessed.selector
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );

        assertEq(
            vaultB.balanceOf(user),
            1_000
        );
    }

    // ---- 31. distinct message ids both mint ----

    function test_ccipReceive_distinctMessageIds_bothMint()
        public
    {
        Client.Any2EVMMessage memory first = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x1)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(1_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        Client.Any2EVMMessage memory second = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x2)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(2_000)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            first
        );

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            second
        );

        assertEq(
            vaultB.balanceOf(user),
            3_000
        );

        assertEq(
            vaultB.processedMessageId(bytes32(uint256(0x1))),
            true
        );

        assertEq(
            vaultB.processedMessageId(bytes32(uint256(0x2))),
            true
        );
    }

    // ---- 32. repointing an already-enabled lane is timelocked ----

    function test_crossChainPeer_repointEnabledLane_timelocked()
        public
    {
        address newPeer = address(0xBEEF);

        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_B,
            newPeer,
            6
        );

        assertEq(
            vaultA.crossChainPeer(SELECTOR_B),
            address(vaultB)
        );

        assertEq(
            vaultA.crossChainPeerEnabled(SELECTOR_B),
            true
        );

        assertEq(
            vaultA.proposedCrossChainPeer(SELECTOR_B),
            newPeer
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CrossChainPeerTimelockNotElapsed.selector
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_B
        );

        assertEq(
            vaultA.crossChainPeer(SELECTOR_B),
            address(vaultB)
        );
    }

    // ---- 33. a repoint takes effect only after the delay ----

    function test_crossChainPeer_repoint_executeAfterDelay_updates()
        public
    {
        address newPeer = address(0xBEEF);

        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_B,
            newPeer,
            8
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_B
        );

        assertEq(
            vaultA.crossChainPeer(SELECTOR_B),
            newPeer
        );

        assertEq(
            vaultA.crossChainPeerDecimals(SELECTOR_B),
            8
        );

        assertEq(
            vaultA.proposedCrossChainPeer(SELECTOR_B),
            address(0)
        );

        assertEq(
            vaultA.crossChainPeerChangeQueuedAt(SELECTOR_B),
            0
        );
    }

    // ---- 34. cancelling a repoint keeps the old peer live ----

    function test_cancelCrossChainPeerChange_afterRepoint_keepsOldPeer()
        public
    {
        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_B,
            address(0xBEEF),
            6
        );

        BridgeFacet(address(vaultA)).cancelCrossChainPeerChange(
            SELECTOR_B
        );

        assertEq(
            vaultA.crossChainPeer(SELECTOR_B),
            address(vaultB)
        );

        assertEq(
            vaultA.crossChainPeerEnabled(SELECTOR_B),
            true
        );

        assertEq(
            vaultA.proposedCrossChainPeer(SELECTOR_B),
            address(0)
        );

        assertEq(
            vaultA.crossChainPeerChangeQueuedAt(SELECTOR_B),
            0
        );
    }

    function _registerPeerTimelocked(
        WiseSovrenNodesDiamond _vault,
        uint64 _selector,
        address _peer,
        uint8 _decimals
    )
        internal
    {
        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _selector,
            _peer,
            _decimals
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _selector
        );
    }

    // ---- 35. empty referral bridges accounting-identical to legacy 2-tuple ----

    function test_bridge_emptyReferral_accountingIdenticalToLegacy()
        public
    {
        address userLegacy = address(0xE1);
        address userEmpty = address(0xE2);
        uint256 amount = 5_000 * 1e6;

        Client.Any2EVMMessage memory legacy = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x100)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(userLegacy, amount),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        Client.Any2EVMMessage memory withEmpty = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x101)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(userEmpty, amount, ""),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        assertEq(
            legacy.data.length,
            64
        );

        assertGt(
            withEmpty.data.length,
            64
        );

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            legacy
        );

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            withEmpty
        );

        assertEq(
            vaultB.balanceOf(userLegacy),
            amount
        );

        assertEq(
            vaultB.balanceOf(userEmpty),
            amount
        );

        assertEq(
            vaultB.cashedInterest(userLegacy),
            vaultB.cashedInterest(userEmpty)
        );

        assertEq(
            vaultB.lastSyncTimeStamp(userLegacy),
            vaultB.lastSyncTimeStamp(userEmpty)
        );

        vm.warp(
            block.timestamp + 30 days
        );

        assertEq(
            vaultB.getPendingInterest(userLegacy),
            vaultB.getPendingInterest(userEmpty)
        );
    }

    // ---- 36. a non-empty referral payload still mints, no event while disabled ----

    function test_ccipReceive_referralPayload_mintsNoEventWhenDisabled()
        public
    {
        bytes memory referral = abi.encode(
            address(0xBEEF),
            uint256(7)
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x200)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(9_000), referral),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        assertEq(
            vaultB.referralEnabled(),
            false
        );

        vm.recordLogs();

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );

        assertEq(
            vaultB.balanceOf(user),
            9_000
        );

        assertEq(
            _countReferralLogs(vm.getRecordedLogs()),
            0
        );
    }

    // ---- 37. an enabled destination surfaces the referral payload verbatim ----

    function test_ccipReceive_referralPayload_emitsWhenEnabled()
        public
    {
        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        bytes memory referral = abi.encode(
            address(0xBEEF),
            uint256(7)
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x201)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(user, uint256(9_000), referral),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.recordLogs();

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countReferralLogs(logs),
            1
        );

        assertEq(
            keccak256(_referralLogData(logs)),
            keccak256(referral)
        );
    }

    // ---- 38. the send path carries the referral bytes on the wire ----

    function test_bridgeToVaultWithReferral_wireCarriesReferral()
        public
    {
        uint256 principal = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        bytes memory referral = abi.encode(
            uint256(42),
            address(0xCAFE)
        );

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            principal,
            referral
        );

        (
            address decUser,
            uint256 decAmount,
            bytes memory decRef
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );

        assertEq(
            decUser,
            user
        );

        assertEq(
            decAmount,
            principal
        );

        assertEq(
            keccak256(decRef),
            keccak256(referral)
        );

        assertEq(
            vaultB.balanceOf(user),
            principal
        );
    }

    // ---- 39. referral payload above the cap reverts ----

    function test_bridgeToVaultWithReferral_tooLong_reverts()
        public
    {
        uint256 principal = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        bytes memory big = new bytes(257);

        vm.deal(
            user,
            1 ether
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralDataTooLong.selector
        );

        BridgeFacet(address(vaultA)).bridgeToVaultWithReferral{value: FEE}(
            SELECTOR_B,
            principal,
            big
        );
    }

    // ---- 40. quoteBridgeFeeWithReferral returns the router fee ----

    function test_quoteBridgeFeeWithReferral_returnsFee()
        public
        view
    {
        assertEq(
            BridgeFacet(address(vaultA)).quoteBridgeFeeWithReferral(
                SELECTOR_B,
                1_000 * 1e6,
                abi.encode(uint256(1))
            ),
            FEE
        );
    }

    // ---- 41. direct facet call to the referral entry reverts ----

    function test_bridgeToVaultWithReferral_directFacetCall_reverts()
        public
    {
        BridgeFacet bridge = new BridgeFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        bridge.bridgeToVaultWithReferral(
            SELECTOR_B,
            1,
            ""
        );
    }

    // ---- 42. setReferralEnabled is master-only and emits ----

    function test_setReferralEnabled_setsAndEmits()
        public
    {
        assertEq(
            vaultA.referralEnabled(),
            false
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit ReferralEnabledSet(
            true
        );

        BridgeFacet(address(vaultA)).setReferralEnabled(
            true
        );

        assertEq(
            vaultA.referralEnabled(),
            true
        );
    }

    function test_setReferralEnabled_onlyMaster_reverts()
        public
    {
        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        BridgeFacet(address(vaultA)).setReferralEnabled(
            true
        );
    }

    // ---- 43. bridgeGasLimit defaults to the constant, override flows to the wire ----

    function test_bridgeGasLimit_defaultsToConstantOnWire()
        public
    {
        uint256 principal = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
        );

        assertEq(
            vaultA.bridgeGasLimit(),
            0
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
            principal
        );

        assertEq(
            _extraArgsGasLimit(router.lastExtraArgs()),
            DEFAULT_BRIDGE_GAS_LIMIT
        );
    }

    function test_bridgeGasLimit_overrideFlowsToWire()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(vaultA)
        );

        emit BridgeGasLimitSet(
            350_000
        );

        BridgeFacet(address(vaultA)).setBridgeGasLimit(
            350_000
        );

        assertEq(
            vaultA.bridgeGasLimit(),
            350_000
        );

        uint256 principal = 10_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            user,
            principal
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
            principal
        );

        assertEq(
            _extraArgsGasLimit(router.lastExtraArgs()),
            350_000
        );
    }

    function test_setBridgeGasLimit_belowMin_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidBridgeGasLimit.selector
        );

        BridgeFacet(address(vaultA)).setBridgeGasLimit(
            199_999
        );
    }

    function test_setBridgeGasLimit_aboveMax_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidBridgeGasLimit.selector
        );

        BridgeFacet(address(vaultA)).setBridgeGasLimit(
            5_000_001
        );
    }

    function test_setBridgeGasLimit_onlyMaster_reverts()
        public
    {
        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        BridgeFacet(address(vaultA)).setBridgeGasLimit(
            300_000
        );
    }

    // ---- 44. a reentrant refund recipient is blocked by the guard ----

    function test_bridge_reentrantRefundRecipient_blockedByGuard()
        public
    {
        ReentrantRefundRecipient attacker = new ReentrantRefundRecipient();

        uint256 principal = 100_000 * 1e6;

        AdminFacet(address(vaultA)).mintSupply(
            address(attacker),
            principal
        );

        uint256 sharesBefore = vaultA.balanceOf(
            address(attacker)
        );

        uint256 bridgeAmount = sharesBefore / 2;

        vm.deal(
            address(attacker),
            1 ether
        );

        attacker.bridge(
            address(vaultA),
            SELECTOR_B,
            bridgeAmount,
            FEE + 0.05 ether,
            FEE
        );

        assertTrue(
            attacker.attempted(),
            "refund callback never fired"
        );

        assertEq(
            keccak256(bytes(attacker.reentryReason())),
            keccak256(bytes("ReentrancyGuard: reentrant call")),
            "reentrant bridge was not blocked by the guard"
        );

        assertEq(
            vaultA.balanceOf(address(attacker)),
            sharesBefore - bridgeAmount,
            "shares burned more than once"
        );

        assertEq(
            address(attacker).balance,
            1 ether - FEE,
            "excess native fee was not refunded"
        );
    }

    function _countReferralLogs(
        Vm.Log[] memory _logs
    )
        internal
        pure
        returns (uint256 count)
    {
        bytes32 topic = keccak256(
            "BridgeReferral(address,uint64,bytes32,bytes)"
        );

        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _referralLogData(
        Vm.Log[] memory _logs
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes32 topic = keccak256(
            "BridgeReferral(address,uint64,bytes32,bytes)"
        );

        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == topic) {
                return abi.decode(_logs[i].data, (bytes));
            }
        }

        return "";
    }

    function _extraArgsGasLimit(
        bytes memory _extraArgs
    )
        internal
        pure
        returns (uint256 gasLimit)
    {
        bytes memory tail = new bytes(_extraArgs.length - 4);

        for (uint256 i; i < tail.length; ++i) {
            tail[i] = _extraArgs[i + 4];
        }

        bool allowOutOfOrderExecution;

        (
            gasLimit,
            allowOutOfOrderExecution
        ) = abi.decode(tail, (uint256, bool));
    }
}
