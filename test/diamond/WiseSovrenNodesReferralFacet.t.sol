// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../referral/registry/ReferralRegistryDeclarations.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall, SelectorTimelockNotElapsed} from "../../src/diamond/shared/DiamondErrors.sol";
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
 * @dev Mirror of the real Permit2 surface used for unit testing.
 * The signature is intentionally ignored: we only validate the
 * facet's call shape and the resulting token movement; real
 * signature verification is covered by the fork tests against the
 * canonical Permit2 deployment.
 */
contract MockPermit2 is IPermit2 {

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata
    )
        external
    {
        require(
            block.timestamp <= _permit.deadline,
            "deadline"
        );

        IERC20(_permit.permitted.token).transferFrom(
            _owner,
            _transferDetails.to,
            _transferDetails.requestedAmount
        );
    }
}

/**
 * @dev Tests for the referral surface with the registry as
 * sole truth: the six `...WithReferral` deposit entrypoints on
 * {ReferralFacet} / {Permit2ReferralFacet} (validation with the
 * fixed revert priority, the write-once rule now enforced by
 * the standalone {ReferralRegistry}: first referrer sticks
 * forever, {ReferralAssigned} emitted by the REGISTRY with the
 * vault identity, the vault emits nothing), parity with the
 * non-referral paths, transfers never touching referrer state
 * (pinned under the production {GraceFreezeHookFacet}), and the
 * diamond slot-67 mapping staying forever virgin (raw `vm.load`).
 * The slot-77 pointer's full life is covered: instant pre-finalize
 * install (setUp), post-finalize 3-day timelocked
 * propose/execute/cancel through the {AdminFacet} trio and its
 * routed getters, the shape probe rejecting codeless and
 * wrong-shaped candidates, the zero-proposal revert-to-off state
 * ({ReferralRegistryNotSet} on referral deposits, zero from
 * `getReferrerOf`), and hostile-registry behavior on the view
 * surface (reverts bubble, the deliberate asymmetry against the
 * recorder's guarded seam, which the cohort suites pin). A
 * live-upgrade simulation walks the exact timelocked selector +
 * pointer sequence the registry upgrade round runs against the
 * production diamonds.
 */
contract WiseSovrenNodesReferralFacetTest is DiamondTestHarness {

    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    event Deposited(
        address indexed user,
        uint256 amount
    );

    uint256 internal constant THRESHOLD = 10_000 * 1e6;
    uint256 internal constant SELECTOR_DELAY = 3 days;
    uint256 internal constant REGISTRY_DELAY = 3 days;

    bytes32 internal constant REFERRAL_ASSIGNED_TOPIC = keccak256(
        "ReferralAssigned(address,address,address)"
    );

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
        );

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            diamond,
            address(new Permit2ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        vm.prank(
            user1
        );

        usd.approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );

        vm.prank(
            user2
        );

        usd.approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    // ---- helpers ----

    function _fundAndApprove(
        WiseSovrenNodesDiamond _d,
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
            address(_d),
            _amount
        );
    }

    function _depositWithReferralAs(
        WiseSovrenNodesDiamond _d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApprove(
            _d,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _permit2DepositWithReferral(
        address _user,
        uint256 _amount,
        uint256 _nonce,
        address _referrer
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

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            _amount,
            _nonce,
            block.timestamp + 1 hours,
            hex"",
            _referrer
        );
    }

    // ---- 1. wiring, getter, delegatecall guards ----

    function test_referrerOf_defaultZero()
        public
        view
    {
        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            address(0)
        );
    }

    function test_referralFacet_directCall_reverts()
        public
    {
        ReferralFacet facet = new ReferralFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_permit2ReferralFacet_directCall_reverts()
        public
    {
        Permit2ReferralFacet facet = new Permit2ReferralFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            refA
        );
    }

    // ---- 2. referrer validation ----

    function test_depositWithReferral_zeroReferrer_reverts()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            address(0)
        );
    }

    function test_depositWithReferral_selfReferral_reverts()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            user1
        );
    }

    function test_depositAndClaimInterestWithReferral_zeroReferrer_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            address(0)
        );
    }

    function test_depositAndCompoundInterestWithReferral_selfReferral_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            user1
        );
    }

    function test_depositWithPermit2WithReferral_zeroReferrer_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            address(0)
        );
    }

    function test_depositWithPermit2WithReferral_selfReferral_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfReferral.selector
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            user1
        );
    }

    function test_depositWithReferral_referrerValidatedBeforeAmount()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SelfReferral.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            0,
            user1
        );
    }

    // ---- 3. deposit-time assignment rule ----

    function test_depositWithReferral_firstDeposit_setsReferrerAndEmits()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralAssigned(
            user1,
            refA,
            address(diamond)
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    function test_depositWithReferral_smallerSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            500 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            500 * 1e6,
            refB
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            1_500 * 1e6
        );
    }

    function test_depositWithReferral_equalSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refB
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    function test_depositWithReferral_largerSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            2_000 * 1e6,
            refB
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != REFERRAL_ASSIGNED_TOPIC
            );
        }

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    function test_depositWithReferral_aboveBalanceSecondDeposit_keepsReferrer()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6 + 1,
            refB
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            2_000 * 1e6 + 1
        );
    }

    function test_depositWithReferral_sameReferrerAgain_noEvent()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            2_000 * 1e6,
            refA
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != REFERRAL_ASSIGNED_TOPIC
            );
        }

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    function testFuzz_depositWithReferral_writeOnceRule(
        uint256 _first,
        uint256 _second
    )
        public
    {
        _first = bound(
            _first,
            1,
            400_000 * 1e6
        );

        _second = bound(
            _second,
            1,
            400_000 * 1e6
        );

        _depositWithReferralAs(
            diamond,
            user1,
            _first,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            _second,
            refB
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    // ---- 4. plain referral deposits: parity + modifier stacks ----

    function test_depositWithReferral_mintsSharesAndPullsUsd()
        public
    {
        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        uint256 before3rd = usd.balanceOf(
            thirdPty
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit Deposited(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            usd.balanceOf(
                thirdPty
            ),
            before3rd + 1_000 * 1e6
        );

        assertEq(
            diamond.lastSyncTimeStamp(
                user1
            ),
            block.timestamp
        );
    }

    function test_depositAndClaimInterestWithReferral_claimsInterest()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        uint256 beforeUsd = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 claimed = ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            refA
        );

        assertGt(
            claimed,
            0
        );

        assertEq(
            usd.balanceOf(
                user1
            ),
            beforeUsd - 1_000 * 1e6 + claimed
        );
    }

    function test_depositAndCompoundInterestWithReferral_compoundsInterest()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        uint256 compounded = ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            2_000 * 1e6 + compounded
        );
    }

    function test_depositWithReferral_depositsDisabled_reverts()
        public
    {
        AdminFacet(address(diamond)).setDepositsDisabled(
            true
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositsDisabled.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositWithReferral_whenPaused_reverts()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert();

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositWithReferral_largeDeposit_stampsGrace()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        assertEq(
            diamond.lastLargeDepositAt(
                user1
            ),
            block.timestamp
        );
    }

    function test_depositWithReferral_graceLocked_stillAllowed()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            THRESHOLD + 1_000 * 1e6
        );
    }

    function test_depositAndClaimInterestWithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositAndCompoundInterestWithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    // ---- 5. permit2 referral deposits ----

    function test_depositWithPermit2WithReferral_setsReferrerAndDeposits()
        public
    {
        uint256 before3rd = usd.balanceOf(
            thirdPty
        );

        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            usd.balanceOf(
                thirdPty
            ),
            before3rd + 1_000 * 1e6
        );
    }

    function test_depositAndClaimInterestWithPermit2WithReferral_claims()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        uint256 beforeUsd = usd.balanceOf(
            user1
        );

        vm.prank(
            user1
        );

        uint256 claimed = Permit2ReferralFacet(address(diamond)).depositAndClaimInterestWithPermit2WithReferral(
            1_000 * 1e6,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertGt(
            claimed,
            0
        );

        assertEq(
            usd.balanceOf(
                user1
            ),
            beforeUsd - 1_000 * 1e6 + claimed
        );
    }

    function test_depositAndCompoundInterestWithPermit2WithReferral_compounds()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        vm.warp(
            block.timestamp + 365 days
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        uint256 compounded = Permit2ReferralFacet(address(diamond)).depositAndCompoundInterestWithPermit2WithReferral(
            1_000 * 1e6,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            2_000 * 1e6 + compounded
        );
    }

    function test_depositWithPermit2WithReferral_writeOnceRule()
        public
    {
        _permit2DepositWithReferral(
            user1,
            1_000 * 1e6,
            0,
            refA
        );

        _permit2DepositWithReferral(
            user1,
            2_000 * 1e6,
            1,
            refB
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    function test_depositWithPermit2WithReferral_expiredDeadline_reverts()
        public
    {
        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            bytes("deadline")
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp - 1,
            hex"",
            refA
        );
    }

    function test_depositAndClaimInterestWithPermit2WithReferral_graceLocked_reverts()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            THRESHOLD,
            refA
        );

        usd.mint(
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        Permit2ReferralFacet(address(diamond)).depositAndClaimInterestWithPermit2WithReferral(
            1_000 * 1e6,
            0,
            block.timestamp + 1 hours,
            hex"",
            refA
        );
    }

    function test_permit2ReferralFacetConstructor_revertsWhenPermit2Missing()
        public
    {
        vm.etch(
            CANONICAL_PERMIT2,
            hex""
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.Permit2NotDeployed.selector
        );

        new Permit2ReferralFacet();
    }

    // ---- 6. transfers never touch the registry ----

    function test_transfer_doesNotAffectReferrals()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            5_000 * 1e6,
            refA
        );

        vm.prank(
            user1
        );

        diamond.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(
                user2
            ),
            1_000 * 1e6
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user2
            ),
            address(0)
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );
    }

    // ---- 7. live-upgrade simulation ----

    function test_liveUpgrade_timelockedInstall_endToEnd()
        public
    {
        WiseSovrenNodesDiamond live = _deployDiamond(
            address(usd)
        );

        address referral = address(
            new ReferralFacet()
        );

        address permit2Referral = address(
            new Permit2ReferralFacet()
        );

        live.proposeSelectors(
            WiseSovrenNodesDiamondSelectors._referralSelectors(),
            referral
        );

        live.proposeSelectors(
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors(),
            permit2Referral
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        live.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        live.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        live.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        assertEq(
            live.selectorToFacet(
                ReferralFacet.getReferrerOf.selector
            ),
            referral
        );

        ReferralRegistry liveRegistry = new ReferralRegistry(
            address(this),
            0
        );

        liveRegistry.setAllowedVault(
            address(live),
            true
        );

        AdminFacet(address(live)).proposeReferralRegistry(
            address(liveRegistry)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryTimelockNotElapsed.selector
        );

        AdminFacet(address(live)).executeReferralRegistryChange();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        ReferralFacet(address(live)).depositWithReferral(
            5_000 * 1e6,
            refA
        );

        assertEq(
            ReferralFacet(address(live)).getReferrerOf(
                user1
            ),
            address(0)
        );

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        AdminFacet(address(live)).executeReferralRegistryChange();

        assertEq(
            AdminFacet(address(live)).getReferralRegistry(),
            address(liveRegistry)
        );

        _depositWithReferralAs(
            live,
            user1,
            5_000 * 1e6,
            refA
        );

        assertEq(
            ReferralFacet(address(live)).getReferrerOf(
                user1
            ),
            refA
        );

        assertEq(
            liveRegistry.referrerOf(
                user1
            ),
            refA
        );

        vm.prank(
            user1
        );

        live.transfer(
            user2,
            1_000 * 1e6
        );

        assertEq(
            ReferralFacet(address(live)).getReferrerOf(
                user2
            ),
            address(0)
        );
    }

    // ---- 8. registry pointer lifecycle + hostile registries ----

    function test_registryPointer_lifecycleGettersAndCancel()
        public
    {
        ReferralRegistry next = new ReferralRegistry(
            address(this),
            0
        );

        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(next)
        );

        assertEq(
            AdminFacet(address(diamond)).getProposedReferralRegistry(),
            address(next)
        );

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistryChangeQueuedAt(),
            block.timestamp
        );

        AdminFacet(address(diamond)).cancelReferralRegistryChange();

        assertEq(
            AdminFacet(address(diamond)).getProposedReferralRegistry(),
            address(0)
        );

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistryChangeQueuedAt(),
            0
        );

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistry(),
            address(registry)
        );
    }

    function test_RevertWhen_executeRegistryChange_nothingProposed()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoReferralRegistryChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();
    }

    function test_RevertWhen_registryPointer_calledByStranger()
        public
    {
        vm.prank(
            user2
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(registry)
        );

        vm.prank(
            user2
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();

        vm.prank(
            user2
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).cancelReferralRegistryChange();
    }

    function test_registryPointer_shapeProbe_rejectsCodelessAndWrongShape()
        public
    {
        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(0xDEAD)
        );

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();

        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(usd)
        );

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistry(),
            address(registry)
        );
    }

    function test_registryPointer_zeroProposal_revertsToOffState()
        public
    {
        AdminFacet(address(diamond)).proposeReferralRegistry(
            address(0)
        );

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        AdminFacet(address(diamond)).executeReferralRegistryChange();

        assertEq(
            AdminFacet(address(diamond)).getReferralRegistry(),
            address(0)
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            address(0)
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_depositWithReferral_unallowlistedVault_reverts()
        public
    {
        registry.setAllowedVault(
            address(diamond),
            false
        );

        _fundAndApprove(
            diamond,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            1_000 * 1e6,
            refA
        );
    }

    function test_getReferrerOf_hostileRegistry_revertBubbles()
        public
    {
        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.expectRevert();

        ReferralFacet(address(diamond)).getReferrerOf(
            user1
        );
    }

    function test_slot67_staysVirgin_afterAssignment()
        public
    {
        _depositWithReferralAs(
            diamond,
            user1,
            1_000 * 1e6,
            refA
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            vm.load(
                address(diamond),
                keccak256(
                    abi.encode(
                        user1,
                        uint256(67)
                    )
                )
            ),
            bytes32(0)
        );
    }
}
