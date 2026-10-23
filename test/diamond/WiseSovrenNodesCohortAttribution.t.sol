// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";
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
 * @dev Attribution discipline of the cohort clamp: a referrer's book
 * is only ever reduced by contribution that was credited to it. A
 * user's tracked contribution counts every deposit (it is the
 * self-stake ladder input), but deposits made while unreferred, or
 * while the registry lookup failed, credit no book, so a later clamp
 * must not charge the referrer the registry names at clamp time for
 * them. The scenarios stage exactly that gap: a plain deposit, then a
 * referral deposit that assigns the victim, then a balance drop
 * through the transfer hook or through the permissionless poke after
 * a master burn. In every case the victim keeps the credit earned
 * from other referees and loses exactly the attributed slice. A
 * clamp that charges nothing (an unattributed deficit) emits no
 * attribution charge; the sync event alone carries it.
 */
contract WiseSovrenNodesCohortAttributionTest is DiamondTestHarness {

    event CohortAttributionCharged(
        address indexed user,
        address indexed referrer,
        uint256 charged,
        uint256 uncharged
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant ONE = 1e6;

    address internal honest = address(0xA1);
    address internal attacker = address(0xA2);
    address internal sink = address(0xA3);
    address internal victim = address(0xB1);
    address internal poker = address(0xD1);

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
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortBridgeHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
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
            100_000_000 * ONE
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _plainDepositAs(
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

    function _pokeAs(
        address _caller,
        address _user
    )
        internal
    {
        vm.prank(
            _caller
        );

        _recorder().syncReferee(
            _user
        );
    }

    function _stageLateReferral()
        internal
    {
        _depositWithReferralAs(
            honest,
            5_000 * ONE,
            victim
        );

        _plainDepositAs(
            attacker,
            15_000 * ONE
        );

        _depositWithReferralAs(
            attacker,
            ONE,
            victim
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_001 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            15_001 * ONE
        );
    }

    // ---- late referral, transfer hook ----

    function test_transferHook_lateReferralTransferAll_chargesOnlyAttributed()
        public
    {
        _stageLateReferral();

        _transferAs(
            attacker,
            sink,
            15_001 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_001 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(
                sink
            ),
            0
        );

        assertEq(
            diamond.balanceOf(
                sink
            ),
            15_001 * ONE
        );
    }

    function test_transferHook_lateReferralPartialDrop_chargesAtMostAttributed()
        public
    {
        _stageLateReferral();

        _transferAs(
            attacker,
            sink,
            10_000 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            5_001 * ONE
        );

        _transferAs(
            attacker,
            sink,
            5_001 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            0
        );
    }

    function test_transferHook_lateReferral_attributedTracksOnlyCreditedDeposits()
        public
    {
        _stageLateReferral();

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                honest
            ),
            5_000 * ONE
        );

        _transferAs(
            attacker,
            sink,
            15_001 * ONE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortAttributionCharged(
            attacker,
            victim,
            ONE,
            15_000 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            0
        );

        assertEq(
            _recorder().getAttributedContribution(
                sink
            ),
            0
        );

        assertLe(
            _recorder().getAttributedContribution(
                honest
            ),
            _recorder().getTrackedContribution(
                honest
            )
        );
    }

    function test_transferHook_lateReferralThenRedeposit_attributesOnlyTheNewCredit()
        public
    {
        _stageLateReferral();

        _transferAs(
            attacker,
            sink,
            15_001 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        _plainDepositAs(
            attacker,
            700 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            700 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            700 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_700 * ONE
        );

        _transferAs(
            attacker,
            sink,
            700 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            0
        );
    }

    function test_lookupFailedCredit_neverChargesBeyondAttributed()
        public
    {
        _depositWithReferralAs(
            honest,
            10_000 * ONE,
            victim
        );

        _depositWithReferralAs(
            attacker,
            5_000 * ONE,
            victim
        );

        bytes memory realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );

        _plainDepositAs(
            attacker,
            2_000 * ONE
        );

        vm.etch(
            address(registry),
            realCode
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            7_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            15_000 * ONE
        );

        _transferAs(
            attacker,
            sink,
            7_000 * ONE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortAttributionCharged(
            attacker,
            victim,
            5_000 * ONE,
            2_000 * ONE
        );

        _pokeAs(
            poker,
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            10_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            0
        );
    }

    // ---- late referral, permissionless poke after a master burn ----

    function test_syncReferee_lateReferralBurnDeficit_chargesOnlyAttributed()
        public
    {
        _stageLateReferral();

        AdminFacet(address(diamond)).burnSupply(
            attacker,
            15_001 * ONE
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_001 * ONE
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            attacker
        );

        assertEq(
            _recorder().getCohortScore(
                victim
            ),
            5_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            0
        );
    }

    function test_syncReferee_unattributedDeficit_emitsNoAttributionCharge()
        public
    {
        _plainDepositAs(
            attacker,
            5_000 * ONE
        );

        _transferAs(
            attacker,
            sink,
            2_000 * ONE
        );

        vm.recordLogs();

        _pokeAs(
            poker,
            attacker
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 charged = keccak256(
            "CohortAttributionCharged(address,address,uint256,uint256)"
        );

        bytes32 synced = keccak256(
            "CohortContributionSynced(address,address,uint256,uint256)"
        );

        uint256 chargedCount;

        uint256 syncedCount;

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == charged) {
                ++chargedCount;
            }

            if (logs[i].topics[0] == synced) {
                ++syncedCount;
            }
        }

        assertEq(
            chargedCount,
            0
        );

        assertEq(
            syncedCount,
            1
        );

        assertEq(
            _recorder().getTrackedContribution(
                attacker
            ),
            3_000 * ONE
        );

        assertEq(
            _recorder().getAttributedContribution(
                attacker
            ),
            0
        );
    }
}
