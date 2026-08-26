// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

contract MockUSDFlex is ERC20 {

    uint8 internal _dec;

    constructor(
        uint8 _decimalsValue
    )
        ERC20("Mock USD", "MUSD")
    {
        _dec = _decimalsValue;
    }

    function decimals()
        public
        view
        override
        returns (uint8)
    {
        return _dec;
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
 * @dev Full coverage suite for `MoveFacet`, the
 * `WiseSovrenNodesMoveHelper` it wraps, and `PeerVaultDeclaration`.
 * Two `WiseSovrenNodesDiamond` instances (`diamondA`, `diamondB`) are
 * deployed and cross-registered as peers in `setUp` via the
 * timelocked propose/execute flow. Decimal scaling tests spin up
 * extra diamonds with non-default decimals.
 */
contract WiseSovrenNodesMoveFacetTest is Test {

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockUSDFlex internal usdA;
    MockUSDFlex internal usdB;

    WiseSovrenNodesDiamond internal diamondA;
    WiseSovrenNodesDiamond internal diamondB;

    address internal master = address(this);
    address internal thirdPty = address(0xCAFE);
    address internal worker = address(0xD00D);
    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal randomEOA = address(0xBADCAFE);

    uint256 internal constant TOTAL_DEPOSIT_CAP = type(uint128).max;
    uint256 internal constant INTEREST_RATE = 2000;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;

    event PeerVaultSet(
        address indexed peer,
        bool enabled
    );

    event PeerVaultProposed(
        address indexed peer,
        uint256 executableAt
    );

    event PeerVaultProposalCancelled(
        address indexed peer
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

    event DepositCapRelocated(
        uint256 newTotalDepositCap
    );

    event TotalCashedInterestChanged(
        uint256 totalCashedInterest
    );

    function setUp()
        public
    {
        _ensurePermit2();

        usdA = new MockUSDFlex(6);
        usdB = new MockUSDFlex(6);

        vm.warp(
            1_700_000_000
        );

        diamondA = _deployDiamond(
            address(usdA),
            6
        );

        diamondB = _deployDiamond(
            address(usdB),
            6
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            address(diamondB)
        );

        MoveFacet(address(diamondB)).proposePeerVault(
            address(diamondA)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            address(diamondB)
        );

        MoveFacet(address(diamondB)).executePeerVaultChange(
            address(diamondA)
        );
    }

    // ---- Deployment helpers ----

    function _deployDiamond(
        address _usd,
        uint8 _decimalsValue
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
                decimalsValue: _decimalsValue,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "wsnUSDC"
            })
        );

        _wireAllFacets(
            d
        );

        d.finalizeSetup();
    }

    function _wireAllFacets(
        WiseSovrenNodesDiamond _d
    )
        internal
    {
        _wireOne(
            _d,
            address(new AdminFacet()),
            WiseSovrenNodesDiamondSelectors.adminSelectors()
        );

        _wireOne(
            _d,
            address(new ProxyFacet()),
            WiseSovrenNodesDiamondSelectors.proxySelectors()
        );

        _wireOne(
            _d,
            address(new UserFacet()),
            WiseSovrenNodesDiamondSelectors.userSelectors()
        );

        _wireOne(
            _d,
            address(new SweepFacet()),
            WiseSovrenNodesDiamondSelectors.sweepSelectors()
        );

        _wireOne(
            _d,
            address(new BurnWiseFacet()),
            WiseSovrenNodesDiamondSelectors.burnWiseSelectors()
        );

        _wireOne(
            _d,
            address(new MoveFacet()),
            WiseSovrenNodesDiamondSelectors.moveSelectors()
        );

        _wireOne(
            _d,
            address(new Permit2UserFacet()),
            WiseSovrenNodesDiamondSelectors.permit2Selectors()
        );
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

    function _ensurePermit2()
        internal
    {
        if (CANONICAL_PERMIT2.code.length > 0) {
            return;
        }

        vm.etch(
            CANONICAL_PERMIT2,
            hex"00"
        );
    }

    function _registerPeerInstantly(
        WiseSovrenNodesDiamond _on,
        address _peer
    )
        internal
    {
        MoveFacet(address(_on)).proposePeerVault(
            _peer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(_on)).executePeerVaultChange(
            _peer
        );
    }

    function _depositAs(
        WiseSovrenNodesDiamond _d,
        MockUSDFlex _u,
        address _user,
        uint256 _amount
    )
        internal
    {
        _u.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _u.approve(
            address(_d),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_d)).deposit(
            _amount
        );
    }

    function _topUpBuffer(
        WiseSovrenNodesDiamond _d,
        MockUSDFlex _u,
        uint256 _amount
    )
        internal
    {
        _u.mint(
            address(_d),
            _amount
        );
    }

    // ---- proposePeerVault ----

    function test_proposePeerVault_byNonMaster_reverts()
        public
    {
        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            address(0xBEEF)
        );
    }

    function test_proposePeerVault_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            address(0)
        );
    }

    function test_proposePeerVault_self_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfPeerNotAllowed.selector
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            address(diamondA)
        );
    }

    function test_proposePeerVault_storesQueuedAt()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        assertEq(
            MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer),
            block.timestamp
        );

        assertFalse(
            MoveFacet(address(diamondA)).peerVault(newPeer)
        );
    }

    function test_proposePeerVault_emitsEvent()
        public
    {
        address newPeer = address(0xBEEF);

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamondA)
        );

        emit PeerVaultProposed(
            newPeer,
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );
    }

    function test_proposePeerVault_overwritesExistingProposal()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        uint256 firstQueuedAt = MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer);

        vm.warp(
            block.timestamp + 1_000
        );

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        uint256 secondQueuedAt = MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer);

        assertEq(
            secondQueuedAt,
            firstQueuedAt + 1_000
        );
    }

    function test_proposePeerVault_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.proposePeerVault(
            address(0xBEEF)
        );
    }

    // ---- executePeerVaultChange ----

    function test_executePeerVaultChange_byNonMaster_reverts()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );
    }

    function test_executePeerVaultChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoPeerVaultChangeProposed.selector
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            address(0xBEEF)
        );
    }

    function test_executePeerVaultChange_beforeTimelock_reverts()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY - 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.PeerVaultTimelockNotElapsed.selector
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );
    }

    function test_executePeerVaultChange_atExactBoundary_succeeds()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );

        assertTrue(
            MoveFacet(address(diamondA)).peerVault(newPeer)
        );
    }

    function test_executePeerVaultChange_clearsQueuedAt()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );

        assertEq(
            MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer),
            0
        );
    }

    function test_executePeerVaultChange_emitsEvent()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamondA)
        );

        emit PeerVaultSet(
            newPeer,
            true
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );
    }

    function test_executePeerVaultChange_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.executePeerVaultChange(
            address(0xBEEF)
        );
    }

    // ---- cancelPeerVaultChange ----

    function test_cancelPeerVaultChange_byNonMaster_reverts()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).cancelPeerVaultChange(
            newPeer
        );
    }

    function test_cancelPeerVaultChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoPeerVaultChangeProposed.selector
        );

        MoveFacet(address(diamondA)).cancelPeerVaultChange(
            address(0xBEEF)
        );
    }

    function test_cancelPeerVaultChange_clearsQueuedAt()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        MoveFacet(address(diamondA)).cancelPeerVaultChange(
            newPeer
        );

        assertEq(
            MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer),
            0
        );
    }

    function test_cancelPeerVaultChange_emitsEvent()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamondA)
        );

        emit PeerVaultProposalCancelled(
            newPeer
        );

        MoveFacet(address(diamondA)).cancelPeerVaultChange(
            newPeer
        );
    }

    function test_cancelPeerVaultChange_thenExecute_reverts()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        MoveFacet(address(diamondA)).cancelPeerVaultChange(
            newPeer
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoPeerVaultChangeProposed.selector
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );
    }

    function test_cancelPeerVaultChange_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.cancelPeerVaultChange(
            address(0xBEEF)
        );
    }

    // ---- removePeerVault ----

    function test_removePeerVault_byNonMaster_reverts()
        public
    {
        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).removePeerVault(
            address(diamondB)
        );
    }

    function test_removePeerVault_instantDisables()
        public
    {
        MoveFacet(address(diamondA)).removePeerVault(
            address(diamondB)
        );

        assertFalse(
            MoveFacet(address(diamondA)).peerVault(address(diamondB))
        );
    }

    function test_removePeerVault_clearsPendingProposal()
        public
    {
        address newPeer = address(0xBEEF);

        MoveFacet(address(diamondA)).proposePeerVault(
            newPeer
        );

        MoveFacet(address(diamondA)).removePeerVault(
            newPeer
        );

        assertEq(
            MoveFacet(address(diamondA)).peerVaultChangeQueuedAt(newPeer),
            0
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoPeerVaultChangeProposed.selector
        );

        MoveFacet(address(diamondA)).executePeerVaultChange(
            newPeer
        );
    }

    function test_removePeerVault_emitsEvent()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamondA)
        );

        emit PeerVaultSet(
            address(diamondB),
            false
        );

        MoveFacet(address(diamondA)).removePeerVault(
            address(diamondB)
        );
    }

    function test_removePeerVault_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.removePeerVault(
            address(0xBEEF)
        );
    }

    // ---- Move: happy paths ----

    function test_moveBetweenVaults_noInterest_balancesAndSupplyMove()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        uint256 srcSupplyBefore = diamondA.totalSupply();
        uint256 dstSupplyBefore = diamondB.totalSupply();

        vm.prank(
            user1
        );

        uint256 dstAmount = MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            dstAmount,
            amount
        );

        assertEq(
            diamondA.balanceOf(user1),
            0
        );

        assertEq(
            diamondB.balanceOf(user1),
            amount
        );

        assertEq(
            diamondA.totalSupply(),
            srcSupplyBefore - amount
        );

        assertEq(
            diamondB.totalSupply(),
            dstSupplyBefore + amount
        );
    }

    function test_moveBetweenVaults_banksPendingInterestOnSource()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        _topUpBuffer(
            diamondA,
            usdA,
            500 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expectedInterest = amount * INTEREST_RATE / PRECISION_RATE;

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamondA)
        );

        emit TotalCashedInterestChanged(
            expectedInterest
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            diamondA.balanceOf(user1),
            0
        );

        assertEq(
            diamondB.balanceOf(user1),
            amount
        );

        assertEq(
            diamondA.cashedInterest(user1),
            expectedInterest
        );

        assertEq(
            diamondA.lastSyncTimeStamp(user1),
            block.timestamp
        );

        uint256 userUsdBefore = usdA.balanceOf(user1);

        vm.prank(
            user1
        );

        uint256 claimed = UserFacet(address(diamondA)).claimInterest();

        assertEq(
            claimed,
            expectedInterest
        );

        assertEq(
            usdA.balanceOf(user1),
            userUsdBefore + expectedInterest
        );
    }

    function test_moveBetweenVaults_emitsCapRelocationAndMoveEvents()
        public
    {
        uint256 amount = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamondA)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP - amount
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamondA)
        );

        emit MovedOut(
            user1,
            address(diamondB),
            amount,
            amount
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamondB)
        );

        emit DepositCapRelocated(
            TOTAL_DEPOSIT_CAP + amount
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamondB)
        );

        emit MovedIn(
            user1,
            address(diamondA),
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );
    }

    function test_moveBetweenVaults_partial_residueRemains()
        public
    {
        uint256 deposit = 1_000 * 1e6;
        uint256 moveAmount = 300 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            moveAmount
        );

        assertEq(
            diamondA.balanceOf(user1),
            deposit - moveAmount
        );

        assertEq(
            diamondB.balanceOf(user1),
            moveAmount
        );
    }

    function test_moveBetweenVaults_balancePlusPending_reverts()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expectedInterest = amount * INTEREST_RATE / PRECISION_RATE;

        assertGt(
            expectedInterest,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientBalance.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount + expectedInterest
        );
    }

    function test_moveBetweenVaults_noPendingInterest_noCompoundEmitted()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        bytes32 compoundTopic = keccak256("CompoundInterest(address,uint256)");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != compoundTopic
            );
        }

        assertEq(
            diamondA.cashedInterest(user1),
            0
        );

        assertEq(
            diamondA.lastSyncTimeStamp(user1),
            block.timestamp
        );

        assertEq(
            diamondA.balanceOf(user1),
            0
        );

        assertEq(
            diamondB.balanceOf(user1),
            amount
        );
    }

    function test_moveBetweenVaults_pendingInterest_noCompoundNoUsdTransfer()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expectedInterest = amount * INTEREST_RATE / PRECISION_RATE;

        uint256 thirdPtyBefore = usdA.balanceOf(thirdPty);
        uint256 vaultUsdBefore = usdA.balanceOf(address(diamondA));

        vm.recordLogs();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        bytes32 compoundTopic = keccak256("CompoundInterest(address,uint256)");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != compoundTopic
            );
        }

        assertEq(
            usdA.balanceOf(thirdPty),
            thirdPtyBefore
        );

        assertEq(
            usdA.balanceOf(address(diamondA)),
            vaultUsdBefore
        );

        assertEq(
            diamondA.cashedInterest(user1),
            expectedInterest
        );

        assertEq(
            diamondB.balanceOf(user1),
            amount
        );
    }

    function test_moveBetweenVaults_preservesPreExistingCashedInterest()
        public
    {
        uint256 deposit1 = 1_000 * 1e6;
        uint256 deposit2 = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit1
        );

        _topUpBuffer(
            diamondA,
            usdA,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 cashedExpected = deposit1 * INTEREST_RATE / PRECISION_RATE;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit2
        );

        assertEq(
            diamondA.cashedInterest(user1),
            cashedExpected
        );

        uint256 balanceAfterSecondDeposit = diamondA.balanceOf(user1);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 freshPending = balanceAfterSecondDeposit * INTEREST_RATE / PRECISION_RATE;

        uint256 moveAmount = 400 * 1e6;

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            moveAmount
        );

        assertEq(
            diamondA.cashedInterest(user1),
            cashedExpected + freshPending
        );

        assertEq(
            diamondA.balanceOf(user1),
            balanceAfterSecondDeposit - moveAmount
        );

        assertEq(
            diamondB.balanceOf(user1),
            moveAmount
        );

        uint256 userUsdBefore = usdA.balanceOf(user1);

        vm.prank(
            user1
        );

        uint256 claimed = UserFacet(address(diamondA)).claimInterest();

        assertEq(
            claimed,
            cashedExpected + freshPending
        );

        assertEq(
            usdA.balanceOf(user1),
            userUsdBefore + cashedExpected + freshPending
        );
    }

    function test_moveBetweenVaults_fullMovePreservesCashedSourceZero()
        public
    {
        uint256 deposit1 = 1_000 * 1e6;
        uint256 deposit2 = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit1
        );

        _topUpBuffer(
            diamondA,
            usdA,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 cashedExpected = deposit1 * INTEREST_RATE / PRECISION_RATE;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit2
        );

        uint256 balanceAfterSecondDeposit = diamondA.balanceOf(user1);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 freshPending = balanceAfterSecondDeposit * INTEREST_RATE / PRECISION_RATE;

        uint256 fullMovable = balanceAfterSecondDeposit;

        assertEq(
            MoveFacet(address(diamondA)).getMoveableBalance(user1),
            fullMovable
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            fullMovable
        );

        assertEq(
            diamondA.balanceOf(user1),
            0
        );

        assertEq(
            diamondB.balanceOf(user1),
            fullMovable
        );

        assertEq(
            diamondA.cashedInterest(user1),
            cashedExpected + freshPending
        );
    }

    function test_moveBetweenVaults_atZeroRoom_succeeds()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        AdminFacet(address(diamondA)).setTotalDepositCap(
            diamondA.totalSupply()
        );

        uint256 capBefore = diamondA.totalDepositCap();

        assertEq(
            capBefore,
            diamondA.totalSupply()
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            diamondA.totalDepositCap(),
            capBefore - amount
        );

        assertEq(
            diamondA.totalDepositCap(),
            diamondA.totalSupply()
        );
    }

    function test_moveBetweenVaults_pendingInterestAtCap_succeeds()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        AdminFacet(address(diamondA)).setTotalDepositCap(
            diamondA.totalSupply()
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 pending = amount * INTEREST_RATE / PRECISION_RATE;

        assertGt(
            pending,
            0
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            diamondA.cashedInterest(user1),
            pending
        );

        assertEq(
            diamondA.totalSupply(),
            0
        );

        assertEq(
            diamondA.totalDepositCap(),
            0
        );

        assertEq(
            diamondB.balanceOf(user1),
            amount
        );
    }

    // ---- Move: validation reverts ----

    function test_moveBetweenVaults_zeroAmount_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            0
        );
    }

    function test_moveBetweenVaults_zeroDestination_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(0),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_selfDestination_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfPeerNotAllowed.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondA),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_unregisteredDestination_reverts()
        public
    {
        address strangerDiamond = address(0xDEAD);

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.PeerVaultNotEnabled.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            strangerDiamond,
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_destinationRemoved_reverts()
        public
    {
        MoveFacet(address(diamondA)).removePeerVault(
            address(diamondB)
        );

        _depositAs(
            diamondA,
            usdA,
            user1,
            1_000 * 1e6
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.PeerVaultNotEnabled.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_insufficientBalance_reverts()
        public
    {
        _depositAs(
            diamondA,
            usdA,
            user1,
            100 * 1e6
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InsufficientBalance.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            500 * 1e6
        );
    }

    function test_moveBetweenVaults_sourcePaused_reverts()
        public
    {
        _depositAs(
            diamondA,
            usdA,
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamondA)).pauseDeposits();

        vm.expectRevert();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_destinationPaused_reverts()
        public
    {
        _depositAs(
            diamondA,
            usdA,
            user1,
            1_000 * 1e6
        );

        AdminFacet(address(diamondB)).pauseDeposits();

        vm.expectRevert();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_byInterestRateProxy_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InterestRateProxyCannotMove.selector
        );

        vm.prank(
            address(diamondA)
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    function test_moveBetweenVaults_raisesDestinationCap_succeeds()
        public
    {
        AdminFacet(address(diamondB)).setTotalDepositCap(
            100 * 1e6
        );

        _depositAs(
            diamondA,
            usdA,
            user1,
            1_000 * 1e6
        );

        uint256 dstCapBefore = diamondB.totalDepositCap();
        uint256 balBefore = diamondB.balanceOf(user1);

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );

        assertEq(
            diamondB.balanceOf(user1) - balBefore,
            1_000 * 1e6
        );

        assertEq(
            diamondB.totalDepositCap() - dstCapBefore,
            1_000 * 1e6
        );

        assertEq(
            diamondB.totalDepositCap() - diamondB.totalSupply(),
            dstCapBefore
        );
    }

    function test_moveBetweenVaults_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.moveBetweenVaults(
            address(diamondB),
            1_000 * 1e6
        );
    }

    // ---- mintFromPeer: auth ----

    function test_mintFromPeer_byNonPeer_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotPeerVault.selector
        );

        vm.prank(
            randomEOA
        );

        MoveFacet(address(diamondB)).mintFromPeer(
            user1,
            1_000 * 1e6
        );
    }

    function test_mintFromPeer_byDisabledPeer_reverts()
        public
    {
        MoveFacet(address(diamondB)).removePeerVault(
            address(diamondA)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotPeerVault.selector
        );

        vm.prank(
            address(diamondA)
        );

        MoveFacet(address(diamondB)).mintFromPeer(
            user1,
            1_000 * 1e6
        );
    }

    function test_mintFromPeer_zeroAmount_reverts()
        public
    {
        vm.prank(
            address(diamondA)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        MoveFacet(address(diamondB)).mintFromPeer(
            user1,
            0
        );
    }

    function test_mintFromPeer_directFacetCall_reverts()
        public
    {
        MoveFacet moveF = new MoveFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        moveF.mintFromPeer(
            user1,
            1_000 * 1e6
        );
    }

    // ---- Decimal scaling ----

    function test_decimalScaling_equalDecimals_passthrough()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.prank(
            user1
        );

        uint256 dstAmount = MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            dstAmount,
            amount
        );
    }

    function test_decimalScaling_scaleUp_6to18()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        uint256 srcAmount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            srcAmount
        );

        vm.prank(
            user1
        );

        uint256 dstAmount = MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamond18),
            srcAmount
        );

        assertEq(
            dstAmount,
            srcAmount * 1e12
        );

        assertEq(
            diamond18.balanceOf(user1),
            srcAmount * 1e12
        );
    }

    function test_decimalScaling_scaleDown_18to6_exactDivisible()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        uint256 srcAmount = 1_000 * 1e18;

        _depositAs(
            diamond18,
            usd18,
            user1,
            srcAmount
        );

        vm.prank(
            user1
        );

        uint256 dstAmount = MoveFacet(address(diamond18)).moveBetweenVaults(
            address(diamondA),
            srcAmount
        );

        assertEq(
            dstAmount,
            srcAmount / 1e12
        );

        assertEq(
            diamondA.balanceOf(user1),
            srcAmount / 1e12
        );
    }

    function test_decimalScaling_scaleDownToZero_reverts()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        uint256 dustAmount = 1e6;

        _depositAs(
            diamond18,
            usd18,
            user1,
            dustAmount
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.MoveAmountTooSmall.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond18)).moveBetweenVaults(
            address(diamondA),
            dustAmount
        );
    }

    function test_decimalScaling_roundTrip_equalDecimals_preservesValue()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondB)).moveBetweenVaults(
            address(diamondA),
            amount
        );

        assertEq(
            diamondA.balanceOf(user1),
            amount
        );

        assertEq(
            diamondB.balanceOf(user1),
            0
        );
    }

    // ---- MoveDust event ----

    function test_moveDust_emittedOnScaleDownNonDivisible()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        uint256 srcAmount = 1_000 * 1e18 + 12_345;

        _depositAs(
            diamond18,
            usd18,
            user1,
            srcAmount
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond18)
        );

        emit MoveDust(
            user1,
            address(diamondA),
            12_345
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond18)).moveBetweenVaults(
            address(diamondA),
            srcAmount
        );
    }

    function test_moveDust_notEmittedOnEqualDecimals()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        bytes32 moveDustTopic = keccak256("MoveDust(address,address,uint256)");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != moveDustTopic
            );
        }
    }

    function test_moveDust_notEmittedOnScaleUp()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        uint256 srcAmount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            srcAmount
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamond18),
            srcAmount
        );

        bytes32 moveDustTopic = keccak256("MoveDust(address,address,uint256)");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != moveDustTopic
            );
        }
    }

    function test_moveDust_notEmittedOnScaleDownExactDivisible()
        public
    {
        MockUSDFlex usd18 = new MockUSDFlex(18);

        WiseSovrenNodesDiamond diamond18 = _deployDiamond(
            address(usd18),
            18
        );

        _registerPeerInstantly(
            diamond18,
            address(diamondA)
        );

        _registerPeerInstantly(
            diamondA,
            address(diamond18)
        );

        uint256 srcAmount = 1_000 * 1e18;

        _depositAs(
            diamond18,
            usd18,
            user1,
            srcAmount
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        MoveFacet(address(diamond18)).moveBetweenVaults(
            address(diamondA),
            srcAmount
        );

        bytes32 moveDustTopic = keccak256("MoveDust(address,address,uint256)");

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != moveDustTopic
            );
        }
    }

    // ---- Views & invariants ----

    function test_getMoveableBalance_zeroForFreshUser()
        public
        view
    {
        assertEq(
            MoveFacet(address(diamondA)).getMoveableBalance(user1),
            0
        );
    }

    function test_getMoveableBalance_excludesPendingInterest()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expectedInterest = amount * INTEREST_RATE / PRECISION_RATE;

        assertGt(
            expectedInterest,
            0
        );

        assertEq(
            MoveFacet(address(diamondA)).getMoveableBalance(user1),
            amount
        );

        assertEq(
            MoveFacet(address(diamondA)).getMoveableBalance(user1),
            diamondA.balanceOf(user1)
        );
    }

    function test_getMoveableBalance_excludesCashedInterest()
        public
    {
        uint256 deposit1 = 1_000 * 1e6;
        uint256 deposit2 = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit1
        );

        _topUpBuffer(
            diamondA,
            usdA,
            1_000 * 1e6
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        _depositAs(
            diamondA,
            usdA,
            user1,
            deposit2
        );

        assertGt(
            diamondA.cashedInterest(user1),
            0
        );

        uint256 balanceNow = diamondA.balanceOf(user1);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        assertEq(
            MoveFacet(address(diamondA)).getMoveableBalance(user1),
            balanceNow
        );
    }

    function test_moveBetweenVaults_lastSyncUpdatedOnDestination()
        public
    {
        uint256 amount = 1_000 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        _topUpBuffer(
            diamondA,
            usdA,
            50 * 1e6
        );

        uint256 t = block.timestamp + 1_000;

        vm.warp(
            t
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            amount
        );

        assertEq(
            diamondB.lastSyncTimeStamp(user1),
            t
        );
    }

    function test_moveBetweenVaults_existingDstBalance_addsCorrectly()
        public
    {
        uint256 srcAmount = 1_000 * 1e6;
        uint256 priorDstAmount = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            srcAmount
        );

        _depositAs(
            diamondB,
            usdB,
            user1,
            priorDstAmount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            srcAmount
        );

        assertEq(
            diamondB.balanceOf(user1),
            srcAmount + priorDstAmount
        );
    }

    // ---- Three vaults on one chain ----

    function _deployThirdVaultPeeredWithA()
        internal
        returns (WiseSovrenNodesDiamond diamondC)
    {
        MockUSDFlex usdC = new MockUSDFlex(6);

        diamondC = _deployDiamond(
            address(usdC),
            6
        );

        _registerPeerInstantly(
            diamondA,
            address(diamondC)
        );

        _registerPeerInstantly(
            diamondC,
            address(diamondA)
        );
    }

    function test_threeVaults_pairwiseMovesAndIsolation()
        public
    {
        WiseSovrenNodesDiamond diamondC = _deployThirdVaultPeeredWithA();

        uint256 amount = 900 * 1e6;
        uint256 slice = 300 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondB),
            slice
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondC),
            slice
        );

        assertEq(
            diamondA.balanceOf(user1),
            slice
        );

        assertEq(
            diamondB.balanceOf(user1),
            slice
        );

        assertEq(
            diamondC.balanceOf(user1),
            slice
        );

        assertEq(
            diamondA.totalSupply(),
            slice
        );

        assertEq(
            diamondB.totalSupply(),
            slice
        );

        assertEq(
            diamondC.totalSupply(),
            slice
        );
    }

    function test_threeVaults_unpeeredPair_reverts()
        public
    {
        WiseSovrenNodesDiamond diamondC = _deployThirdVaultPeeredWithA();

        uint256 amount = 400 * 1e6;

        _depositAs(
            diamondB,
            usdB,
            user1,
            amount
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.PeerVaultNotEnabled.selector
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondB)).moveBetweenVaults(
            address(diamondC),
            amount
        );
    }

    function test_threeVaults_moveBackToFirstVault()
        public
    {
        WiseSovrenNodesDiamond diamondC = _deployThirdVaultPeeredWithA();

        uint256 amount = 500 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondC),
            amount
        );

        vm.prank(
            user1
        );

        uint256 backAmount = MoveFacet(address(diamondC)).moveBetweenVaults(
            address(diamondA),
            amount
        );

        assertEq(
            backAmount,
            amount
        );

        assertEq(
            diamondC.balanceOf(user1),
            0
        );

        assertEq(
            diamondA.balanceOf(user1),
            amount
        );

        assertEq(
            diamondC.totalSupply(),
            0
        );
    }

    function test_threeVaults_moveIntoDormantVault_succeeds()
        public
    {
        WiseSovrenNodesDiamond diamondC = _deployThirdVaultPeeredWithA();

        AdminFacet(address(diamondC)).setDepositsDisabled(
            true
        );

        uint256 amount = 250 * 1e6;

        _depositAs(
            diamondA,
            usdA,
            user1,
            amount
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamondA)).moveBetweenVaults(
            address(diamondC),
            amount
        );

        assertEq(
            diamondC.balanceOf(user1),
            amount
        );

        assertEq(
            diamondC.totalSupply(),
            amount
        );
    }
}
