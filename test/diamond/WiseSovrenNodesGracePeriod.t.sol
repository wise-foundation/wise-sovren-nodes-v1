// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";

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
 * fee and `ccipSend` just mints a message id. No relay — the grace
 * tests only assert that outbound bridging stays open during grace.
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
 * @dev Signature-blind Permit2 stand-in etched at the canonical
 * address: pulls the permitted amount from the owner to the
 * requested destination via a plain `transferFrom`, so Permit2
 * deposit entrypoints can be exercised without real signatures.
 */
contract MockPermit2 {

    function permitTransferFrom(
        IPermit2.PermitTransferFrom memory _permit,
        IPermit2.SignatureTransferDetails memory _details,
        address _owner,
        bytes calldata
    )
        external
    {
        ERC20(_permit.permitted.token).transferFrom(
            _owner,
            _details.to,
            _details.requestedAmount
        );
    }
}

/**
 * @dev Tests for the large-deposit grace period: a single deposit or
 * compound call growing a user's balance by `graceThresholdAmount`
 * or more stamps `lastLargeDepositAt[user]`, and until
 * `gracePeriodDuration` elapses that user cannot claim, compound or
 * reassign interest, nor relocate the position to another vault
 * (same-chain move or cross-chain bridge). Plain deposits,
 * withdrawals and transfers stay open, interest keeps accruing, and
 * non-deposit inflows (mintSupply, transfers, ccipReceive, queue
 * fulfillment receipts) never stamp. `graceThresholdAmount == 0`
 * disables the trigger so upgraded diamonds with zeroed tail storage
 * behave as before.
 */
contract WiseSovrenNodesGracePeriodTest is DiamondTestHarness {

    event GracePeriodDurationSet(
        uint256 gracePeriodDuration
    );

    event GraceThresholdAmountSet(
        uint256 graceThresholdAmount
    );

    event LargeDepositRegistered(
        address indexed user,
        uint256 balanceIncrease,
        uint256 graceEndsAt
    );

    uint64 internal constant REMOTE_SELECTOR = 1111;

    uint256 internal constant THRESHOLD = 10_000 * 1e6;
    uint256 internal constant GRACE_PERIOD = 45 days;
    uint256 internal constant MAX_GRACE = 365 days;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;

    address internal remotePeer = address(0xBEEF);
    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal bot = address(0xB07);

    WiseSovrenNodesDiamond internal diamond;
    WiseSovrenNodesDiamond internal diamondB;
    MockUSD internal usd;
    MockUSD internal usdB;
    MockRouterSink internal router;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        vm.etch(
            CANONICAL_PERMIT2,
            address(new MockPermit2()).code
        );

        usd = new MockUSD();
        usdB = new MockUSD();
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

        diamondB = _deployDiamond(
            address(usdB)
        );

        MoveFacet(address(diamond)).proposePeerVault(
            address(diamondB)
        );

        MoveFacet(address(diamondB)).proposePeerVault(
            address(diamond)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamond)).executePeerVaultChange(
            address(diamondB)
        );

        MoveFacet(address(diamondB)).executePeerVaultChange(
            address(diamond)
        );
    }

    // ---- shared helpers ----

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

    function _depositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApprove(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _stampViaDeposit(
        address _user
    )
        internal
    {
        _depositAs(
            _user,
            THRESHOLD
        );
    }

    function _accrueBigInterest(
        address _user,
        uint256 _principal
    )
        internal
        returns (uint256 interest)
    {
        AdminFacet(address(diamond)).mintSupply(
            _user,
            _principal
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        interest = _principal
            * INTEREST_RATE
            / PRECISION_RATE;
    }

    // ---- 1. constructor defaults ----

    function test_constructorDefaults_freshDeploy_matchSpec()
        public
        view
    {
        assertEq(
            diamond.gracePeriodDuration(),
            GRACE_PERIOD
        );

        assertEq(
            diamond.graceThresholdAmount(),
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.depositHookFacet(),
            address(0)
        );

        assertEq(
            diamond.depositAccumWindow(),
            0
        );

        assertEq(
            diamond.depositWindowStart(user1),
            0
        );

        assertEq(
            diamond.depositWindowTotal(user1),
            0
        );
    }

    // ---- 2. setter access control and bounds ----

    function test_setGracePeriodDuration_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setGracePeriodDuration(
            10 days
        );
    }

    function test_setGracePeriodDuration_directFacetCall_reverts()
        public
    {
        AdminFacet facet = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.setGracePeriodDuration(
            10 days
        );
    }

    function test_setGracePeriodDuration_aboveMax_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodTooLong.selector
        );

        AdminFacet(address(diamond)).setGracePeriodDuration(
            MAX_GRACE + 1
        );
    }

    function test_setGracePeriodDuration_byMaster_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit GracePeriodDurationSet(
            10 days
        );

        AdminFacet(address(diamond)).setGracePeriodDuration(
            10 days
        );

        assertEq(
            diamond.gracePeriodDuration(),
            10 days
        );
    }

    function test_setGraceThresholdAmount_nonMaster_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            1_000 * 1e6
        );
    }

    function test_setGraceThresholdAmount_byMaster_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit GraceThresholdAmountSet(
            1_000 * 1e6
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            1_000 * 1e6
        );

        assertEq(
            diamond.graceThresholdAmount(),
            1_000 * 1e6
        );
    }

    function test_setGraceThresholdAmount_dustValue_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GraceThresholdTooLow.selector
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            1
        );
    }

    function test_setGraceThresholdAmount_belowOneShareToken_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GraceThresholdTooLow.selector
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            1e6 - 1
        );
    }

    function test_setGraceThresholdAmount_oneShareToken_succeeds()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit GraceThresholdAmountSet(
            1e6
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            1e6
        );

        assertEq(
            diamond.graceThresholdAmount(),
            1e6
        );
    }

    // ---- 3. trigger: deposits ----

    function test_deposit_belowThreshold_doesNotStamp()
        public
    {
        _depositAs(
            user1,
            THRESHOLD - 1
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_deposit_atThreshold_stampsAndEmits()
        public
    {
        _fundAndApprove(
            user1,
            THRESHOLD
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit LargeDepositRegistered(
            user1,
            THRESHOLD,
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    function test_deposit_cumulativeSmallDeposits_windowOff_doNotStamp()
        public
    {
        _depositAs(
            user1,
            4_000 * 1e6
        );

        _depositAs(
            user1,
            4_000 * 1e6
        );

        _depositAs(
            user1,
            4_000 * 1e6
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_deposit_thresholdZero_neverStamps()
        public
    {
        AdminFacet(address(diamond)).setGraceThresholdAmount(
            0
        );

        _depositAs(
            user1,
            5 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_depositWithPermit2_atThreshold_stamps()
        public
    {
        usd.mint(
            user1,
            THRESHOLD
        );

        vm.prank(
            user1
        );

        usd.approve(
            CANONICAL_PERMIT2,
            THRESHOLD
        );

        vm.prank(
            user1
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            THRESHOLD,
            0,
            block.timestamp,
            ""
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    // ---- 4. trigger: compounds ----

    function test_compoundInterest_interestAtThreshold_stamps()
        public
    {
        _accrueBigInterest(
            user1,
            100_000 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).compoundInterest();

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );
    }

    // ---- 5. trigger: excluded inflow paths never stamp ----

    function test_mintSupply_atThreshold_doesNotStamp()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            5 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_transfer_atThreshold_doesNotStamp()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            5 * THRESHOLD
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            2 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamond.lastLargeDepositAt(user2),
            0
        );
    }

    function test_ccipReceive_atThreshold_doesNotStamp()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: REMOTE_SELECTOR,
            sender: abi.encode(remotePeer),
            data: abi.encode(user1, 2 * THRESHOLD),
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
            2 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );
    }

    function test_fulfillOrder_shareReceiptAtThreshold_doesNotStamp()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            2 * THRESHOLD
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2 * THRESHOLD,
            0
        );

        _fundAndApprove(
            user2,
            2 * THRESHOLD
        );

        vm.prank(
            user2
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            id,
            0
        );

        assertEq(
            diamond.balanceOf(user2),
            2 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user2),
            0
        );
    }

    // ---- 6. trigger: re-stamp and moves ----

    function test_largeDeposit_secondLargeDeposit_restampsGraceWindow()
        public
    {
        _stampViaDeposit(
            user1
        );

        uint256 firstStamp = diamond.lastLargeDepositAt(
            user1
        );

        vm.warp(
            block.timestamp + 10 days
        );

        _depositAs(
            user1,
            THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            firstStamp + 10 days
        );
    }

    function test_moveBetweenVaults_pendingAtThreshold_doesNotStampSource()
        public
    {
        uint256 interest = _accrueBigInterest(
            user1,
            100_000 * 1e6
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(diamondB),
            100 * 1e6
        );

        assertEq(
            diamond.cashedInterest(user1),
            interest
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamondB.lastLargeDepositAt(user1),
            0
        );
    }

    function test_moveBetweenVaults_fullMove_doesNotStamp()
        public
    {
        _accrueBigInterest(
            user1,
            100_000 * 1e6
        );

        uint256 moveable = MoveFacet(address(diamond)).getMoveableBalance(
            user1
        );

        assertEq(
            moveable,
            100_000 * 1e6
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(diamondB),
            moveable
        );

        assertEq(
            diamond.balanceOf(user1),
            0
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

        assertEq(
            diamondB.lastLargeDepositAt(user1),
            0
        );
    }

    // ---- 7. gate: claim and compound entrypoints revert during grace ----

    function test_claimInterest_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterest();
    }

    function test_claimInterestExactAmount_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterestExactAmount(
            1
        );
    }

    function test_claimInterestPartiallyAndCompound_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterestPartiallyAndCompound(
            1
        );
    }

    function test_compoundInterest_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).compoundInterest();
    }

    function test_depositAndClaimInterest_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        _fundAndApprove(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).depositAndClaimInterest(
            1_000 * 1e6
        );
    }

    function test_depositAndCompoundInterest_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        _fundAndApprove(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).depositAndCompoundInterest(
            1_000 * 1e6
        );
    }

    function test_permit2Combos_duringGrace_revert()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
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
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        Permit2UserFacet(address(diamond)).depositAndCompoundInterestWithPermit2(
            1_000 * 1e6,
            0,
            block.timestamp,
            ""
        );
    }

    function test_compoundInterestViaFulfillBulk_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        int256[] memory incs = new int256[](0);
        uint256[] memory orders = new uint256[](0);
        uint256[] memory partials = new uint256[](0);

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        QueueFulfillFacet(address(diamond)).compoundInterestViaFulfillBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );
    }

    function test_moveMyInterestTo_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).moveMyInterestTo(
            0,
            user2,
            true
        );
    }

    function test_moveBetweenVaults_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    function test_bridgeToVault_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        BridgeFacet(address(diamond)).bridgeToVault{
            value: 0.01 ether
        }(
            REMOTE_SELECTOR,
            1_000 * 1e6
        );
    }

    function test_bridgeToVaultWithReferral_duringGrace_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        BridgeFacet(address(diamond)).bridgeToVaultWithReferral{
            value: 0.01 ether
        }(
            REMOTE_SELECTOR,
            1_000 * 1e6,
            ""
        );
    }

    // ---- 8. gate ordering: triggering call completes, batch reverts ----

    function test_depositAndClaimInterest_triggeringCall_claimsInSameCall()
        public
    {
        _depositAs(
            user1,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        uint256 expectedInterest = 1_000 * 1e6
            * INTEREST_RATE
            / PRECISION_RATE;

        _fundAndApprove(
            user1,
            THRESHOLD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).depositAndClaimInterest(
            THRESHOLD
        );

        assertEq(
            usd.balanceOf(user1),
            expectedInterest
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            block.timestamp
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterest();
    }

    function test_multicall_depositThenClaim_revertsAtomically()
        public
    {
        _fundAndApprove(
            user1,
            15_000 * 1e6
        );

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            UserFacet.deposit.selector,
            15_000 * 1e6
        );

        calls[1] = abi.encodeWithSelector(
            UserFacet.claimInterest.selector
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        MulticallFacet(address(diamond)).multicall(
            calls
        );
    }

    // ---- 9. open paths during grace ----

    function test_deposit_duringGrace_succeeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        _depositAs(
            user1,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD + 1_000 * 1e6
        );
    }

    function test_transfer_duringGrace_succeeds()
        public
    {
        _stampViaDeposit(
            user1
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
    }

    function test_joinAndLeaveQue_duringGrace_succeeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 id
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            id,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD
        );
    }

    function test_bridgeToVault_unstampedUser_succeeds()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            2 * THRESHOLD
        );

        assertEq(
            diamond.lastLargeDepositAt(user1),
            0
        );

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
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            2 * THRESHOLD - 1_000 * 1e6
        );
    }

    function test_bridgeToVault_afterGraceElapsed_succeeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD
        );

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
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            THRESHOLD - 1_000 * 1e6
        );
    }

    function test_interestAccrual_duringGrace_continues()
        public
    {
        _stampViaDeposit(
            user1
        );

        uint256 before = diamond.getTotalInterestUser(
            user1
        );

        vm.warp(
            block.timestamp + 10 days
        );

        uint256 later = diamond.getTotalInterestUser(
            user1
        );

        assertGt(
            later,
            before
        );
    }

    // ---- 10. expiry and master overrides ----

    function test_claimInterest_oneSecondBeforeExpiry_reverts()
        public
    {
        _stampViaDeposit(
            user1
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD - 1
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterest();
    }

    function test_claimInterest_afterGraceElapsed_succeeds()
        public
    {
        _stampViaDeposit(
            user1
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        vm.warp(
            block.timestamp + GRACE_PERIOD
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterest();

        assertGt(
            usd.balanceOf(user1),
            0
        );
    }

    function test_setGracePeriodDuration_shortenedMidGrace_unlocksEarly()
        public
    {
        _stampViaDeposit(
            user1
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );

        AdminFacet(address(diamond)).setGracePeriodDuration(
            1 days
        );

        vm.warp(
            block.timestamp + 1 days
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterest();

        assertGt(
            usd.balanceOf(user1),
            0
        );
    }

    function test_setGraceThresholdAmount_zeroMidGrace_gateStillActive()
        public
    {
        _stampViaDeposit(
            user1
        );

        AdminFacet(address(diamond)).setGraceThresholdAmount(
            0
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        UserFacet(address(diamond)).claimInterest();
    }
}
