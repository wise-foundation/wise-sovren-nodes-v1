// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {AutoCompoundFacet} from "../../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortFlushFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {CohortFlushPolicyFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushPolicyFacet.sol";

import {FacetNotFound, SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";
import {WiseSovrenNodesDiamondErrors} from "../../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {IReferralHub} from "../../referral/hub/IReferralHub.sol";
import {HubLeverGrants} from "../../referral/hub/utils/HubLeverGrants.sol";
import {ReferralRegistryDeclarations} from "../../referral/registry/ReferralRegistryDeclarations.sol";

/**
 * @dev The surface of the live Sovren diamond this rehearsal drives: the genesis admin
 * and user entrypoints plus the selectors the two rounds route.
 */
interface ISovrenReferralVault {

    function master()
        external
        view
        returns (address);

    function paused()
        external
        view
        returns (bool);

    function depositsDisabled()
        external
        view
        returns (bool);

    function totalSupply()
        external
        view
        returns (uint256);

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function USD_TOKEN()
        external
        view
        returns (address);

    function selectorToFacet(
        bytes4 _selector
    )
        external
        view
        returns (address);

    function transferHookFacet()
        external
        view
        returns (address);

    function bridgeGasLimit()
        external
        view
        returns (uint64);

    function proposeSelectors(
        bytes4[] memory _selectors,
        address facet
    )
        external;

    function executeSelectorChanges(
        bytes4[] memory _selectors
    )
        external;

    function proposeTransferHookFacet(
        address _facet
    )
        external;

    function executeTransferHookFacetChange()
        external;

    function unpauseDeposits()
        external;

    function setDepositsDisabled(
        bool _disabled
    )
        external;

    function setTotalDepositCap(
        uint256 _newCap
    )
        external;

    function setBridgeGasLimit(
        uint256 _gasLimit
    )
        external;

    function proposeReferralRegistry(
        address _registry
    )
        external;

    function executeReferralRegistryChange()
        external;

    function getReferralRegistry()
        external
        view
        returns (address);

    function setCohortSyncEnabled(
        bool _enabled
    )
        external;

    function getCohortSyncEnabled()
        external
        view
        returns (bool);

    function proposeFlushHub(
        address _hub,
        uint64 chainSelector
    )
        external;

    function executeFlushHubChange()
        external;

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        );

    function deposit(
        uint256 _amount
    )
        external;

    function depositWithReferral(
        uint256 _amount,
        address referrer
    )
        external;

    function getReferrerOf(
        address _user
    )
        external
        view
        returns (address);

    function getTrackedContribution(
        address _user
    )
        external
        view
        returns (uint256);

    function quoteFlushFee(
        address[] memory _referrers
    )
        external
        view
        returns (uint256);

    function flushReferrals(
        address[] memory _referrers
    )
        external
        payable;

    function getFlushedThroughWeek(
        address _referrer
    )
        external
        view
        returns (uint256);
}

interface ILiveReferralRegistry {

    function master()
        external
        view
        returns (address);

    function allowedVault(
        address _vault
    )
        external
        view
        returns (bool);

    function proposeAllowedVault(
        address _vault
    )
        external;

    function executeAllowedVaultChange(
        address _vault
    )
        external;

    function syncInitialized()
        external
        view
        returns (bool);

    function referrerOf(
        address _user
    )
        external
        view
        returns (address);
}

interface IUsdDecimals {

    function decimals()
        external
        view
        returns (uint8);
}

/**
 * @dev Rehearsal of the Sovren vault joining the live referral system, on a fork of
 * Ethereum mainnet at its head: the shared registry and hub are read from
 * `config/registry.mainnet.json` and `config/hub.mainnet.json` (deployed and operated from
 * the WiseTelecomNodes repository, never redeployed here), the vault from
 * `config/vault.usdc.mainnet.json`. The order rehearsed is the one the rollout follows:
 * 1. the registry allow lane for this vault (propose, three days, execute), from the
 *    registry master; 2. the hub source tag `setSourceSystem(sourceKeyOf(1, vault), 1)`
 *    from the hub master, cast before the reporter grant; 3. the reporter grant through the
 *    hub lever timelock; 4. the registry round of {UpgradeReferralRegistry} (the fourteen
 *    facets over thirteen selector batches plus the transfer hook, the auto compound batch
 *    re routing the seven live selectors to the facet with the cohort stubs), the legacy
 *    referral bridge pair retired to the zero facet, the registry pointer and the arm;
 * 5. the flush round of {UpgradeCohortFlush} and the flush hub pointer in local mode (the
 *    hub lives on this chain, selector zero); 6. a referred deposit, two weeks of age and a
 *    self flush that lands the week's referred average on the hub and prices it. Every
 *    timelock is first driven early and pinned refusing. The suite skips when the live
 *    diamond already routes the recorder group (the rollout has run) and it tolerates an
 *    allow lane, tag or grant already in place, so it stays green through the rollout
 *    days. Needs `MAINNET_RPC_URL` (an archive endpoint) and is excluded from CI with the
 *    other fork suites.
 */
contract WiseSovrenNodesReferralUpgradeForkTest is Test {

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant ARMED_BRIDGE_GAS_LIMIT = 5_000_000;

    uint256 internal constant SOVREN_SYSTEM = 1;

    ISovrenReferralVault internal v;

    ILiveReferralRegistry internal registry;

    IReferralHub internal hub;

    address internal usd;

    address internal master;

    uint256 internal one;

    address internal user;

    address internal referrer;

    struct RoundFacets {
        address admin;
        address user;
        address permit2User;
        address move;
        address bridge;
        address queueJoinLeave;
        address queueFulfill;
        address autoCompound;
        address referral;
        address permit2Referral;
        address recorder;
        address hook;
        address bridgeHook;
        address moveHook;
    }

    function setUp()
        public
    {
        address diamond = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdc.mainnet.json"
            ),
            ".diamond"
        );

        address registryAddress = vm.parseJsonAddress(
            vm.readFile(
                "config/registry.mainnet.json"
            ),
            ".registry"
        );

        address hubAddress = vm.parseJsonAddress(
            vm.readFile(
                "config/hub.mainnet.json"
            ),
            ".hub"
        );

        vm.createSelectFork(
            "mainnet"
        );

        require(
            diamond.code.length > 0,
            "vault not deployed on this fork"
        );

        require(
            registryAddress.code.length > 0,
            "registry not deployed on this fork"
        );

        require(
            hubAddress.code.length > 0,
            "hub not deployed on this fork"
        );

        v = ISovrenReferralVault(
            diamond
        );

        registry = ILiveReferralRegistry(
            registryAddress
        );

        hub = IReferralHub(
            hubAddress
        );

        usd = v.USD_TOKEN();
        master = v.master();
        one = 10 ** IUsdDecimals(usd).decimals();

        user = makeAddr(
            "sovrenReferralUser"
        );

        referrer = makeAddr(
            "sovrenReferrer"
        );
    }

    function test_sovrenJoin_rehearsalEndToEnd()
        public
    {
        if (v.selectorToFacet(WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]) != address(0)) {
            vm.skip(
                true
            );
            return;
        }

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "depositWithReferral(uint256,address)",
                one,
                referrer
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getReferralRegistry()"
            )
        );

        _joinThroughAllowLane();
        _tagAndGrantOnHub();

        RoundFacets memory facets = _proposeRegistryRound();
        _executeRegistryRound(
            facets
        );

        _retireLegacyReferralBridge();
        _wirePointerAndArm();
        _flushRound();
        _referredDepositAndSelfFlush();
    }

    function _joinThroughAllowLane()
        internal
    {
        require(
            registry.syncInitialized(),
            "registry sync setup not finalized on the live chain"
        );

        if (registry.allowedVault(address(v))) {
            return;
        }

        address registryMaster = registry.master();

        vm.prank(
            registryMaster
        );
        registry.proposeAllowedVault(
            address(v)
        );

        vm.prank(
            registryMaster
        );
        vm.expectRevert(
            ReferralRegistryDeclarations.VaultAllowTimelockNotElapsed.selector
        );
        registry.executeAllowedVaultChange(
            address(v)
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.prank(
            registryMaster
        );
        registry.executeAllowedVaultChange(
            address(v)
        );

        assertTrue(
            registry.allowedVault(
                address(v)
            ),
            "allow lane did not admit the vault"
        );
    }

    function _tagAndGrantOnHub()
        internal
    {
        address hubMaster = hub.master();

        bytes32 sourceKey = hub.sourceKeyOf(
            block.chainid,
            address(v)
        );

        if (hub.sourceSystemOf(sourceKey) != SOVREN_SYSTEM) {
            vm.prank(
                hubMaster
            );
            hub.setSourceSystem(
                sourceKey,
                SOVREN_SYSTEM
            );
        }

        assertEq(
            hub.sourceSystemOf(
                sourceKey
            ),
            SOVREN_SYSTEM,
            "source tag not set"
        );

        if (hub.allowedReporter(address(v)) == false) {
            vm.startPrank(
                hubMaster
            );
            HubLeverGrants._grant(
                address(hub),
                abi.encodeCall(
                    IReferralHub.setAllowedReporter,
                    (
                        address(v),
                        true
                    )
                )
            );
            vm.stopPrank();
        }

        assertTrue(
            hub.allowedReporter(
                address(v)
            ),
            "reporter grant not in place"
        );
    }

    function _proposeRegistryRound()
        internal
        returns (RoundFacets memory facets)
    {
        facets.admin = address(new AdminFacet());
        facets.user = address(new UserFacet());
        facets.permit2User = address(new Permit2UserFacet());
        facets.move = address(new MoveFacet());
        facets.bridge = address(new BridgeFacet());
        facets.queueJoinLeave = address(new QueueJoinLeaveFacet());
        facets.queueFulfill = address(new QueueFulfillFacet());
        facets.autoCompound = address(new AutoCompoundFacet());
        facets.referral = address(new ReferralFacet());
        facets.permit2Referral = address(new Permit2ReferralFacet());
        facets.recorder = address(new CohortRecorderFacet());
        facets.hook = address(new CohortHookFacet());
        facets.bridgeHook = address(new CohortBridgeHookFacet());
        facets.moveHook = address(new CohortMoveHookFacet());

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._adminSelectors(),
            facets.admin
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._userSelectors(),
            facets.user
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._permit2Selectors(),
            facets.permit2User
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._moveSelectors(),
            facets.move
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._bridgeSelectors(),
            facets.bridge
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors(),
            facets.queueJoinLeave
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._queueFulfillSelectors(),
            facets.queueFulfill
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._referralSelectors(),
            facets.referral
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors(),
            facets.permit2Referral
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors(),
            facets.recorder
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors(),
            facets.bridgeHook
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors(),
            facets.moveHook
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors(),
            facets.autoCompound
        );

        vm.prank(
            master
        );
        v.proposeTransferHookFacet(
            facets.hook
        );
    }

    function _executeRegistryRound(
        RoundFacets memory _facets
    )
        internal
    {
        address hookBefore = v.transferHookFacet();

        address autoCompoundBefore = v.selectorToFacet(
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors()[0]
        );

        vm.prank(
            master
        );
        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );
        v.executeSelectorChanges(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        vm.prank(
            master
        );
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.TransferHookTimelockNotElapsed.selector
        );
        v.executeTransferHookFacetChange();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._adminSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._userSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._permit2Selectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._moveSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._queueFulfillSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._autoCompoundSelectors()
        );

        vm.prank(
            master
        );
        v.executeTransferHookFacetChange();

        assertEq(
            v.transferHookFacet(),
            _facets.hook,
            "cohort hook not installed"
        );

        assertTrue(
            v.transferHookFacet() != hookBefore,
            "hook unchanged"
        );

        assertEq(
            v.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()[0]
            ),
            _facets.recorder,
            "recorder group not routed"
        );

        assertEq(
            v.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()[0]
            ),
            _facets.bridgeHook,
            "bridge hook group not routed"
        );

        assertEq(
            v.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._autoCompoundSelectors()[0]
            ),
            _facets.autoCompound,
            "auto compound batch not re routed"
        );

        assertTrue(
            autoCompoundBefore != address(0)
                && autoCompoundBefore != _facets.autoCompound,
            "the live auto compound facet must be replaced, not installed"
        );

        assertEq(
            v.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._queueJoinLeaveSelectors()[0]
            ),
            _facets.queueJoinLeave,
            "queue join leave batch not routed"
        );
    }

    function _retireLegacyReferralBridge()
        internal
    {
        bytes4[] memory pair = WiseSovrenNodesDiamondSelectors._legacyReferralBridgeSelectors();

        assertTrue(
            v.selectorToFacet(
                pair[0]
            ) != address(0),
            "legacy pair must be routed before the retirement"
        );

        _proposeGroup(
            pair,
            address(0)
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeGroup(
            pair
        );

        assertEq(
            v.selectorToFacet(
                pair[0]
            ),
            address(0),
            "legacy pair still routed"
        );

        assertEq(
            v.selectorToFacet(
                pair[1]
            ),
            address(0),
            "legacy quote still routed"
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "quoteBridgeFeeWithReferral(uint64,uint256,bytes)",
                uint64(0),
                one,
                bytes("")
            )
        );
    }

    function _wirePointerAndArm()
        internal
    {
        assertEq(
            v.getReferralRegistry(),
            address(0),
            "pointer must start unset"
        );

        vm.prank(
            master
        );
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryNotSet.selector
        );
        v.setCohortSyncEnabled(
            true
        );

        vm.prank(
            master
        );
        v.proposeReferralRegistry(
            address(registry)
        );

        vm.prank(
            master
        );
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ReferralRegistryTimelockNotElapsed.selector
        );
        v.executeReferralRegistryChange();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.prank(
            master
        );
        v.executeReferralRegistryChange();

        assertEq(
            v.getReferralRegistry(),
            address(registry),
            "pointer not wired"
        );

        vm.prank(
            master
        );
        v.setBridgeGasLimit(
            ARMED_BRIDGE_GAS_LIMIT
        );

        vm.prank(
            master
        );
        v.setCohortSyncEnabled(
            true
        );

        assertTrue(
            v.getCohortSyncEnabled(),
            "arming failed"
        );

        assertEq(
            uint256(v.bridgeGasLimit()),
            ARMED_BRIDGE_GAS_LIMIT,
            "bridge gas limit not raised"
        );
    }

    function _flushRound()
        internal
    {
        address adminFacet = address(new AdminFacet());
        address flushFacet = address(new CohortFlushFacet());
        address policyFacet = address(new CohortFlushPolicyFacet());
        address hookFacet = address(new CohortHookFacet());

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._adminSelectors(),
            adminFacet
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors(),
            flushFacet
        );

        _proposeGroup(
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors(),
            policyFacet
        );

        vm.prank(
            master
        );
        v.proposeTransferHookFacet(
            hookFacet
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._adminSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()
        );

        _executeGroup(
            WiseSovrenNodesDiamondSelectors._cohortFlushPolicySelectors()
        );

        vm.prank(
            master
        );
        v.executeTransferHookFacetChange();

        assertEq(
            v.transferHookFacet(),
            hookFacet,
            "settle aware hook not installed"
        );

        assertEq(
            v.selectorToFacet(
                WiseSovrenNodesDiamondSelectors._cohortFlushSelectors()[0]
            ),
            flushFacet,
            "flush group not routed"
        );

        vm.prank(
            master
        );
        v.proposeFlushHub(
            address(hub),
            0
        );

        vm.prank(
            master
        );
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.FlushHubTimelockNotElapsed.selector
        );
        v.executeFlushHubChange();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.prank(
            master
        );
        v.executeFlushHubChange();

        (
            address wiredHub,
            uint64 wiredSelector
        ) = v.getFlushHub();

        assertEq(
            wiredHub,
            address(hub),
            "flush hub pointer not wired"
        );

        assertEq(
            uint256(wiredSelector),
            0,
            "flush hub must be local"
        );
    }

    function _referredDepositAndSelfFlush()
        internal
    {
        _openDoors();

        uint256 amount = 10_000 * one;

        deal(
            usd,
            user,
            amount
        );

        vm.prank(
            user
        );
        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(v),
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );

        vm.prank(
            user
        );
        v.depositWithReferral(
            amount,
            referrer
        );

        assertEq(
            v.getReferrerOf(
                user
            ),
            referrer,
            "referrer not written through the shared registry"
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            referrer,
            "registry does not hold the referral"
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            amount,
            "referred deposit not tracked"
        );

        vm.warp(
            (block.timestamp / CohortWeeks.WEEK + 2) * CohortWeeks.WEEK + 1
        );

        address[] memory referrers = new address[](1);
        referrers[0] = referrer;

        uint256 fee = v.quoteFlushFee(
            referrers
        );

        assertEq(
            fee,
            0,
            "a local flush charges no fee"
        );

        uint256 accruedBefore = hub.totalAccrued();

        vm.prank(
            referrer
        );
        v.flushReferrals(
            referrers
        );

        uint256 currentWeek = block.timestamp
            / CohortWeeks.WEEK;

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            currentWeek - 1,
            "flush cursor did not reach the last closed week"
        );

        (
            uint256 referredInput,
        ) = hub.ladderInputsAt(
            referrer,
            currentWeek - 1
        );

        assertEq(
            referredInput,
            amount,
            "the hub must hold the full week's referred average"
        );

        assertGt(
            hub.claimable(
                block.chainid,
                referrer
            ),
            0,
            "the hub priced nothing for the Sovren referrer"
        );

        assertGt(
            hub.totalAccrued(),
            accruedBefore,
            "the hub booked nothing"
        );
    }

    function _openDoors()
        internal
    {
        if (v.paused()) {
            vm.prank(
                master
            );
            v.unpauseDeposits();
        }

        if (v.depositsDisabled()) {
            vm.prank(
                master
            );
            v.setDepositsDisabled(
                false
            );
        }

        uint256 liftedCap = v.totalSupply()
            + 100_000 * one;

        vm.prank(
            master
        );
        v.setTotalDepositCap(
            liftedCap
        );
    }

    function _proposeGroup(
        bytes4[] memory _sels,
        address _facet
    )
        internal
    {
        vm.prank(
            master
        );
        v.proposeSelectors(
            _sels,
            _facet
        );
    }

    function _executeGroup(
        bytes4[] memory _sels
    )
        internal
    {
        vm.prank(
            master
        );
        v.executeSelectorChanges(
            _sels
        );
    }

    function _assertSelectorUnknown(
        bytes memory _calldata
    )
        internal
    {
        (
            bool ok,
            bytes memory ret
        ) = address(v).call(
            _calldata
        );

        assertFalse(
            ok,
            "selector live"
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector,
            "expected FacetNotFound from the live fallback"
        );
    }
}
