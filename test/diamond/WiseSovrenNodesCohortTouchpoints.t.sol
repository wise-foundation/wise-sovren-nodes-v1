// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
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
 * @dev Touchpoint suite for the cohort recorder: the
 * default-off arming discipline (sections 0), the contribution credit
 * paths through every deposit and compound variant including the
 * all-depositor tracking of unreferred users (section 1), and the
 * one-way lazy clamp: transfer deficits landing on the NEXT sync,
 * two-party hook sync, the permissionless poke, and clamp-before-credit
 * ordering (section 2). The recorder engine lives in one deployment
 * ({CohortHookFacet}) installed as the transfer hook; the suite wires
 * the full production selector groups plus the pending referral and
 * cohort groups, exactly as the cohort upgrade will route them.
 */
contract WiseSovrenNodesCohortTouchpointsTest is DiamondTestHarness {

    event Deposited(
        address indexed user,
        uint256 amount
    );

    event CohortContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortBookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    event CohortSyncEnabledSet(
        bool enabled
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    bytes32 internal constant CREDITED_TOPIC = keccak256(
        "CohortContributionCredited(address,address,uint256)"
    );

    bytes32 internal constant SYNCED_TOPIC = keccak256(
        "CohortContributionSynced(address,address,uint256,uint256)"
    );

    bytes32 internal constant REDUCED_TOPIC = keccak256(
        "CohortBookReduced(address,uint256,uint256,uint256,uint256)"
    );

    bytes32 internal constant LOOKUP_FAILED_TOPIC = keccak256(
        "CohortReferrerLookupFailed(address)"
    );

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal outsider = address(0xC1);
    address internal poker = address(0xD1);
    address internal bot = address(0xE1);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
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

        _wireQueueFacets(
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

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            diamond,
            address(new AutoCompoundFacet()),
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
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

    function _arm()
        internal
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
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

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
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

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    function _botCompound(
        address _user
    )
        internal
        returns (uint256 netAmount)
    {
        AutoCompoundFacet(address(diamond)).setAutoCompoundBot(
            bot,
            true
        );

        AutoCompoundFacet(address(diamond)).setAutoCompoundFeeBps(
            100
        );

        vm.prank(
            _user
        );

        AutoCompoundFacet(address(diamond)).setAutoCompoundAllowed(
            true
        );

        vm.warp(
            block.timestamp + 30 days
        );

        vm.prank(
            bot
        );

        netAmount = AutoCompoundFacet(address(diamond)).compoundInterestOnBehalf(
            _user
        );
    }

    function _currentRingSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks) % 52;
    }

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    function _assertRecorderVirgin(
        address _user,
        address _referrer
    )
        internal
        view
    {
        assertEq(
            _recorder().getTrackedContribution(
                _user
            ),
            0
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorder().getCohortBook(_referrer);

        assertEq(
            year1,
            0
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            0
        );

        assertEq(
            lastSettle,
            0
        );

        assertEq(
            _recorder().getCohortScore(
                _referrer
            ),
            0
        );
    }

    // ---- 0. default-off arming discipline ----

    function test_unarmed_deposit_writesNoRecorderState()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        assertEq(
            ReferralFacet(address(diamond)).getReferrerOf(
                user1
            ),
            refA
        );

        _assertRecorderVirgin(
            user1,
            refA
        );
    }

    function test_unarmed_transfer_recorderUntouched()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        _assertRecorderVirgin(
            user1,
            refA
        );
    }

    function test_unarmed_queueJoin_recorderUntouched()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            1_000 * 1e6,
            0
        );

        _assertRecorderVirgin(
            user1,
            refA
        );
    }

    function test_unarmed_syncRefereePoke_isNoop()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        _assertRecorderVirgin(
            user1,
            refA
        );
    }

    function test_unarmed_advanceBook_isNoop()
        public
    {
        vm.prank(
            poker
        );

        _recorder().advanceBook(
            refA,
            10
        );

        _assertRecorderVirgin(
            user1,
            refA
        );
    }

    function test_setCohortSyncEnabled_revertsWhenNotMaster()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function test_setCohortSyncEnabled_revertsWhenHookNotInstalled()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        bare.finalizeSetup();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.CohortHookNotInstalled.selector
        );

        AdminFacet(address(bare)).setCohortSyncEnabled(
            true
        );
    }

    function test_setCohortSyncEnabled_revertsWhenHookNotCohortAware()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        AdminFacet(address(bare)).proposeTransferHookFacet(
            address(new GraceFreezeHookFacet())
        );

        AdminFacet(address(bare)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            bare
        );

        bare.finalizeSetup();

        vm.expectRevert();

        AdminFacet(address(bare)).setCohortSyncEnabled(
            true
        );
    }

    function test_setCohortSyncEnabled_revertsWhenRegistryNotSet()
        public
    {
        WiseSovrenNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        AdminFacet(address(bare)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(bare)).executeTransferHookFacetChange();

        bare.finalizeSetup();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        AdminFacet(address(bare)).setCohortSyncEnabled(
            true
        );
    }

    function test_setCohortSyncEnabled_emitsEvent()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSyncEnabledSet(
            true
        );

        _arm();

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortSyncEnabledSet(
            false
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );
    }

    // ---- 1. contribution credit paths ----

    function test_depositWithReferral_creditsContributionRingBookScore()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1,
            DEPOSIT
        );

        assertEq(
            year2,
            0
        );

        assertEq(
            mature,
            0
        );

        assertEq(
            lastSettle,
            block.timestamp
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[_currentRingSlot()]),
            DEPOSIT
        );

        assertEq(
            uint256(ring2[_currentRingSlot()]),
            0
        );
    }

    function test_depositWithReferral_emitsCredited()
        public
    {
        _arm();

        _fundAndApprove(
            user1,
            DEPOSIT
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionCredited(
            user1,
            refA,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            DEPOSIT,
            refA
        );
    }

    function test_deposit_unreferredUser_tracksContributionOnly()
        public
    {
        _arm();

        vm.recordLogs();

        _depositAs(
            user2,
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            1
        );
    }

    function test_depositAndClaimInterestWithReferral_creditsDepositOnly()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 30 days
        );

        _fundAndApprove(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        ReferralFacet(address(diamond)).depositAndClaimInterestWithReferral(
            DEPOSIT,
            refA
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            diamond.balanceOf(
                user1
            )
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            2 * DEPOSIT
        );
    }

    function test_depositAndCompoundInterestWithReferral_creditsDepositPlusCompound()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 30 days
        );

        _fundAndApprove(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        uint256 compounded = ReferralFacet(address(diamond)).depositAndCompoundInterestWithReferral(
            DEPOSIT,
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            diamond.balanceOf(
                user1
            )
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            2 * DEPOSIT + compounded
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            2 * DEPOSIT + compounded
        );
    }

    function test_compoundInterest_creditsReferrer()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 30 days
        );

        vm.prank(
            user1
        );

        uint256 compounded = UserFacet(address(diamond)).compoundInterest();

        assertGt(
            compounded,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT + compounded
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT + compounded
        );
    }

    function test_compoundInterest_unreferred_tracksOnly()
        public
    {
        _arm();

        _depositAs(
            user2,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 30 days
        );

        vm.prank(
            user2
        );

        uint256 compounded = UserFacet(address(diamond)).compoundInterest();

        assertGt(
            compounded,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT + compounded
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );
    }

    function test_depositWithPermit2WithReferral_credits()
        public
    {
        _arm();

        usd.mint(
            user1,
            DEPOSIT
        );

        vm.prank(
            user1
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            DEPOSIT,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );
    }

    function test_depositAndCompoundInterestWithPermit2WithReferral_credits()
        public
    {
        _arm();

        usd.mint(
            user1,
            2 * DEPOSIT
        );

        vm.prank(
            user1
        );

        Permit2ReferralFacet(address(diamond)).depositWithPermit2WithReferral(
            DEPOSIT,
            1,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        vm.warp(
            block.timestamp + 30 days
        );

        vm.prank(
            user1
        );

        uint256 compounded = Permit2ReferralFacet(address(diamond)).depositAndCompoundInterestWithPermit2WithReferral(
            DEPOSIT,
            2,
            block.timestamp + 1 hours,
            hex"",
            refA
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            2 * DEPOSIT + compounded
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            2 * DEPOSIT + compounded
        );
    }

    function test_sameWeekDeposits_shareOneRingSlot()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralAs(
            user2,
            2_000 * 1e6,
            refA
        );

        (
            uint64[52] memory ring1,

        ) = _recorder().getCohortRings(refA);

        assertEq(
            uint256(ring1[_currentRingSlot()]),
            DEPOSIT + 2_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT + 2_000 * 1e6
        );
    }

    function test_mintSupply_neverCredits()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            1_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );
    }

    function test_compoundInterestOnBehalf_creditsReferrerWithNet()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.recordLogs();

        uint256 net = _botCompound(
            user1
        );

        assertGt(
            net,
            0
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                CREDITED_TOPIC
            ),
            1
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT + net
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT + net
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            DEPOSIT + net
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT + net
        );
    }

    function test_compoundInterestOnBehalf_unreferred_tracksOnly()
        public
    {
        _arm();

        _depositAs(
            user2,
            DEPOSIT
        );

        uint256 net = _botCompound(
            user2
        );

        assertGt(
            net,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT + net
        );

        assertEq(
            _recorder().getAttributedContribution(
                user2
            ),
            0
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            0
        );
    }

    function test_compoundInterestOnBehalf_afterDeficit_clampsBeforeCredit()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        uint256 net = _botCompound(
            user1
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
                - 2_000 * 1e6
                + net
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
                - 2_000 * 1e6
                + net
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
                - 2_000 * 1e6
                + net
        );
    }

    // ---- 2. one-way lazy clamp paths ----

    function test_transfer_deficitLandsOnNextSyncNotThisTransfer()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    function test_transfer_syncsToSideStaleReceiver()
        public
    {
        _arm();

        _depositWithReferralAs(
            user2,
            DEPOSIT,
            refB
        );

        _transferAs(
            user2,
            outsider,
            2_000 * 1e6
        );

        _depositAs(
            user1,
            DEPOSIT
        );

        _transferAs(
            user1,
            user2,
            100 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            3_000 * 1e6
        );
    }

    function test_transferFrom_routesRecorderSync()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            user1
        );

        diamond.approve(
            user2,
            1_000 * 1e6
        );

        vm.prank(
            user2
        );

        diamond.transferFrom(
            user1,
            outsider,
            1_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );
    }

    function test_syncReferee_pokePermissionlessAndIdempotent()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );
    }

    function test_syncReferee_emitsSyncedAndReduced()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortBookReduced(
            refA,
            2_000 * 1e6,
            2_000 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            DEPOSIT,
            3_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );
    }

    function test_syncReferee_unreferredWithDeficit_clampsTrackedOnly()
        public
    {
        _arm();

        _depositAs(
            user2,
            DEPOSIT
        );

        _transferAs(
            user2,
            outsider,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user2
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            3_000 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );
    }

    function test_burnSupply_deficitCaughtByPoke()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    function test_deposit_afterDeficit_clampsBeforeCredit()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        _depositAs(
            user1,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            diamond.balanceOf(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );
    }

    function test_deposit_afterDeficit_eventOrderSyncBeforeCredit()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.recordLogs();

        _depositAs(
            user1,
            2_000 * 1e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 syncedIndex = type(uint256).max;

        uint256 creditedIndex = type(uint256).max;

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == SYNCED_TOPIC && syncedIndex == type(uint256).max) {
                syncedIndex = i;
            }

            if (logs[i].topics[0] == CREDITED_TOPIC && creditedIndex == type(uint256).max) {
                creditedIndex = i;
            }
        }

        assertLt(
            syncedIndex,
            creditedIndex
        );
    }

    // ---- 4. registry lookup-failure arms (guarded staticcall seam) ----

    function _lookupFailedCount()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == LOOKUP_FAILED_TOPIC) {
                ++count;
            }
        }
    }

    function test_syncPoke_registryReverts_skipsClampThenRetries()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.recordLogs();

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _lookupFailedCount(),
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );

        vm.etch(
            address(registry),
            realCode
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );
    }

    function test_deposit_registryReverts_tracksButCreditsNobody()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        vm.recordLogs();

        _depositAs(
            user1,
            2_000 * 1e6
        );

        assertEq(
            _lookupFailedCount(),
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT + 2_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );

        vm.etch(
            address(registry),
            realCode
        );
    }

    function test_syncPoke_registryReturnsShortOrDirty_treatedAsFailure()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.etch(
            address(registry),
            hex"60106000f3"
        );

        vm.recordLogs();

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _lookupFailedCount(),
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        vm.etch(
            address(registry),
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff60005260206000f3"
        );

        vm.recordLogs();

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _lookupFailedCount(),
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );
    }

    // ---- moved-amount pins: transfer sides, self-transfer, partial claim, admin burn ----

    function _assertSelfCrumb(
        address _user,
        uint256 _settledAt,
        uint256 _current
    )
        internal
        view
    {
        (
            uint256 settledAt,
            uint256 current,
        ) = _recorder().getCohortSelfCrumb(
            _user
        );

        assertEq(
            settledAt,
            _settledAt
        );

        assertEq(
            current,
            _current
        );
    }

    function _assertZeroAddressBookEmpty()
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettle
        ) = _recorder().getCohortBook(
            address(0)
        );

        assertEq(
            year1 + year2 + mature + lastSettle,
            0
        );
    }

    function test_transfer_selfTransfer_neverClampsOrSettles()
        public
    {
        _arm();

        uint256 depositAt = block.timestamp;

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        vm.recordLogs();

        _transferAs(
            user1,
            user1,
            1_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT
        );

        _assertSelfCrumb(
            user1,
            depositAt,
            0
        );
    }

    function test_transfer_selfTransfer_unreferred_neverClampsOrSettles()
        public
    {
        _arm();

        uint256 depositAt = block.timestamp;

        _depositAs(
            user2,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 1 days
        );

        vm.recordLogs();

        _transferAs(
            user2,
            user2,
            1_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user2
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getAttributedContribution(
                user2
            ),
            0
        );

        _assertSelfCrumb(
            user2,
            depositAt,
            0
        );

        _assertZeroAddressBookEmpty();
    }

    function test_transfer_referredToReferred_debitsSenderReferrerOnly()
        public
    {
        _arm();

        uint256 depositAt = block.timestamp;

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _depositWithReferralAs(
            user2,
            DEPOSIT,
            refB
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 transferAt = block.timestamp;

        _transferAs(
            user1,
            user2,
            2_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getAttributedContribution(
                user2
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            DEPOSIT
        );

        (
            ,
            ,
            ,
            uint256 lastSettleB
        ) = _recorder().getCohortBook(
            refB
        );

        assertEq(
            lastSettleB,
            depositAt
        );

        _assertSelfCrumb(
            user2,
            depositAt,
            0
        );

        _assertSelfCrumb(
            user1,
            transferAt,
            DEPOSIT * 1 days
        );
    }

    function test_transfer_referredToUnreferred_recipientStaysUntracked()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                outsider
            ),
            0
        );

        assertEq(
            _recorder().getAttributedContribution(
                outsider
            ),
            0
        );

        _assertSelfCrumb(
            outsider,
            0,
            0
        );
    }

    function test_transfer_unreferredSender_settlesSelfCrumbAtParkOnly()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refB
        );

        _depositAs(
            user2,
            DEPOSIT
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 transferAt = block.timestamp;

        _transferAs(
            user2,
            user1,
            2_000 * 1e6
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user2
        );

        assertEq(
            _recorder().getTrackedContribution(
                user2
            ),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getAttributedContribution(
                user2
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorder().getCohortScore(
                refB
            ),
            DEPOSIT
        );

        _assertSelfCrumb(
            user2,
            transferAt,
            DEPOSIT * 1 days
        );

        _assertZeroAddressBookEmpty();
    }

    function test_deposit_unreferredUser_attributesNothingAndStampsCrumb()
        public
    {
        _arm();

        _depositAs(
            user2,
            DEPOSIT
        );

        assertEq(
            _recorder().getAttributedContribution(
                user2
            ),
            0
        );

        _assertSelfCrumb(
            user2,
            block.timestamp,
            0
        );

        _assertZeroAddressBookEmpty();
    }

    function test_claimInterestPartiallyAndCompound_creditsCompoundedRemainder()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 balanceBefore = diamond.balanceOf(
            user1
        );

        vm.recordLogs();

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterestPartiallyAndCompound(
            1e6
        );

        uint256 compounded = diamond.balanceOf(
            user1
        ) - balanceBefore;

        assertGt(
            compounded,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            DEPOSIT + compounded
        );

        assertEq(
            _recorder().getAttributedContribution(
                user1
            ),
            DEPOSIT + compounded
        );

        assertEq(
            _recorder().getCohortScore(
                refA
            ),
            DEPOSIT + compounded
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                CREDITED_TOPIC
            ),
            1
        );
    }

    function test_burnSupply_selfCrumbCountsBurnedStakeUntilPoke()
        public
    {
        _arm();

        uint256 depositAt = block.timestamp;

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            depositAt + 1 days
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            2_000 * 1e6
        );

        vm.warp(
            depositAt + 3 days
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(
                user1
            ),
            3_000 * 1e6
        );

        _assertSelfCrumb(
            user1,
            depositAt + 3 days,
            DEPOSIT * 3 days
        );
    }
}
