// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";

import {
    FacetNotFound,
    AlreadyInitialized,
    NoSelectorChangeQueued,
    SelectorTimelockNotElapsed,
    OnlyDelegateCall
} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

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
}

/**
 * @dev Focused unit tests for the WiseSovrenNodesDiamond selector-routing
 * machinery: finalizeSetup lifecycle, propose / execute / cancel, the
 * 3-day timelock that activates after finalizeSetup, the fallback
 * DELEGATECALL dispatcher, and onlyDelegateCall on facets.
 */
contract DiamondSelectorRoutingTest is Test {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address nonMaster = address(0xBEEF);

    uint256 constant DELAY = 3 days;

    bytes4 constant SEL_ALLOW = bytes4(keccak256("disAllowSupplyChangeByOwner()"));
    bytes4 constant SEL_DISALLOW = bytes4(keccak256("disallowWithdraw()"));
    bytes4 constant SEL_PAUSE = bytes4(keccak256("pauseDeposits()"));

    event SetupFinalized();

    event SelectorProposed(
        bytes4 indexed selector,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorsProposed(
        bytes4[] selectors,
        address indexed facet,
        uint256 executableAt
    );

    event SelectorUpdated(
        bytes4 indexed selector,
        address indexed facet
    );

    event SelectorProposalCancelled(
        bytes4 indexed selector
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployBareDiamond();
    }

    function _deployBareDiamond()
        internal
        returns (WiseSovrenNodesDiamond)
    {
        return new WiseSovrenNodesDiamond(
            WiseSovrenNodesInitParams({
                usdAddress: address(usd),
                thirdPartyAddress: thirdPty,
                workerAddress: worker,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: 1_000_000_000 * 1e6,
                interestRate: 2000,
                decimalsValue: 6,
                tokenName: "Wise Sovren Nodes",
                tokenSymbol: "WTN"
            })
        );
    }

    // ---- finalizeSetup ----

    function test_finalizeSetup_writesFlagAndEmits()
        public
    {
        assertFalse(
            diamond.initialized()
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SetupFinalized();

        diamond.finalizeSetup();

        assertTrue(
            diamond.initialized()
        );
    }

    function test_finalizeSetup_twice_reverts()
        public
    {
        diamond.finalizeSetup();

        vm.expectRevert(
            AlreadyInitialized.selector
        );

        diamond.finalizeSetup();
    }

    function test_finalizeSetup_nonMaster_reverts()
        public
    {
        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        diamond.finalizeSetup();
    }

    // ---- proposeSelector ----

    function test_proposeSelector_writesStorageAndEmits()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorProposed(
            SEL_ALLOW,
            address(admin),
            block.timestamp + DELAY
        );

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_ALLOW),
            address(admin)
        );

        assertEq(
            diamond.selectorChangeQueuedAt(SEL_ALLOW),
            block.timestamp
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(0)
        );
    }

    function test_proposeSelector_nonMaster_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );
    }

    function test_proposeSelector_overwritesPriorProposal()
        public
    {
        AdminFacet v1 = new AdminFacet();
        AdminFacet v2 = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(v1)
        );

        uint256 t1 = diamond.selectorChangeQueuedAt(
            SEL_ALLOW
        );

        vm.warp(
            block.timestamp + 100
        );

        diamond.proposeSelector(
            SEL_ALLOW,
            address(v2)
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_ALLOW),
            address(v2)
        );

        assertEq(
            diamond.selectorChangeQueuedAt(SEL_ALLOW),
            t1 + 100
        );
    }

    // ---- proposeSelectors (batch) ----

    function test_proposeSelectors_batchWritesAndEmits()
        public
    {
        AdminFacet admin = new AdminFacet();
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = SEL_ALLOW;
        sels[1] = SEL_DISALLOW;
        sels[2] = SEL_PAUSE;

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorsProposed(
            sels,
            address(admin),
            block.timestamp + DELAY
        );

        diamond.proposeSelectors(
            sels,
            address(admin)
        );

        for (uint256 i = 0; i < sels.length; ++i) {
            assertEq(
                diamond.proposedSelectorFacet(sels[i]),
                address(admin)
            );

            assertEq(
                diamond.selectorChangeQueuedAt(sels[i]),
                block.timestamp
            );
        }
    }

    function test_proposeSelectors_nonMaster_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL_ALLOW;

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        diamond.proposeSelectors(
            sels,
            address(admin)
        );
    }

    // ---- executeSelectorChange ----

    function test_executeSelectorChange_preFinalize_appliesImmediatelyAndClears()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorUpdated(
            SEL_ALLOW,
            address(admin)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_ALLOW),
            address(0)
        );

        assertEq(
            diamond.selectorChangeQueuedAt(SEL_ALLOW),
            0
        );
    }

    function test_executeSelectorChange_postFinalize_revertsJustBeforeDelay()
        public
    {
        diamond.finalizeSetup();

        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.warp(
            block.timestamp + DELAY - 1
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );
    }

    function test_executeSelectorChange_postFinalize_succeedsAtExactDelay()
        public
    {
        diamond.finalizeSetup();

        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.warp(
            block.timestamp + DELAY
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );
    }

    function test_executeSelectorChange_postFinalize_succeedsAfterDelay()
        public
    {
        diamond.finalizeSetup();

        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.warp(
            block.timestamp + DELAY + 1
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );
    }

    function test_executeSelectorChange_proposedPreFinalize_executedPostFinalize_timelocked()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.finalizeSetup();

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        vm.warp(
            block.timestamp + DELAY
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );
    }

    function test_executeSelectorChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );
    }

    function test_executeSelectorChange_codelessTarget_reverts()
        public
    {
        diamond.proposeSelector(
            SEL_ALLOW,
            address(0xDEAD01)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );
    }

    function test_executeSelectorChange_nonMaster_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );
    }

    function test_executeSelectorChanges_batchAllPostDelay()
        public
    {
        AdminFacet admin = new AdminFacet();
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = SEL_ALLOW;
        sels[1] = SEL_DISALLOW;
        sels[2] = SEL_PAUSE;

        diamond.proposeSelectors(
            sels,
            address(admin)
        );

        diamond.finalizeSetup();

        vm.warp(
            block.timestamp + DELAY
        );

        diamond.executeSelectorChanges(
            sels
        );

        for (uint256 i = 0; i < sels.length; ++i) {
            assertEq(
                diamond.selectorToFacet(sels[i]),
                address(admin)
            );

            assertEq(
                diamond.proposedSelectorFacet(sels[i]),
                address(0)
            );

            assertEq(
                diamond.selectorChangeQueuedAt(sels[i]),
                0
            );
        }
    }

    function test_executeSelectorChanges_partialNoProposal_revertsEntireBatch()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.proposeSelector(
            SEL_DISALLOW,
            address(admin)
        );

        bytes4[] memory sels = new bytes4[](3);
        sels[0] = SEL_ALLOW;
        sels[1] = SEL_DISALLOW;
        sels[2] = SEL_PAUSE;

        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        diamond.executeSelectorChanges(
            sels
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(0)
        );

        assertEq(
            diamond.selectorToFacet(SEL_DISALLOW),
            address(0)
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_ALLOW),
            address(admin)
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_DISALLOW),
            address(admin)
        );
    }

    // ---- cancelSelectorProposal ----

    function test_cancelSelectorProposal_clearsAndEmits()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SelectorProposalCancelled(
            SEL_ALLOW
        );

        diamond.cancelSelectorProposal(
            SEL_ALLOW
        );

        assertEq(
            diamond.proposedSelectorFacet(SEL_ALLOW),
            address(0)
        );

        assertEq(
            diamond.selectorChangeQueuedAt(SEL_ALLOW),
            0
        );
    }

    function test_cancelSelectorProposal_nonMaster_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        diamond.cancelSelectorProposal(
            SEL_ALLOW
        );
    }

    function test_cancelSelectorProposal_thenExecute_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.cancelSelectorProposal(
            SEL_ALLOW
        );

        vm.expectRevert(
            NoSelectorChangeQueued.selector
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );
    }

    function test_cancelSelectorProposal_thenRepropose_executes()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.cancelSelectorProposal(
            SEL_ALLOW
        );

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );
    }

    // ---- fallback dispatcher ----

    function test_fallback_facetNotFound_revertsWithError()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSignature(
                "doesNotExist()"
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );
    }

    function test_fallback_routesAndDelegateCallsWritesDiamondStorage()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertFalse(
            diamond.supplyChangeByOwnerNotAllowed()
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        assertTrue(
            diamond.supplyChangeByOwnerNotAllowed()
        );
    }

    function test_fallback_bubblesFacetRevert()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        vm.prank(
            nonMaster
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();
    }

    function test_fallback_unrouteByExecutingZeroFacet()
        public
    {
        AdminFacet admin = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(admin)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(admin)
        );

        diamond.proposeSelector(
            SEL_ALLOW,
            address(0)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(0)
        );

        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                SEL_ALLOW
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );
    }

    function test_changeRouting_lifecycle_postFinalize()
        public
    {
        AdminFacet v1 = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(v1)
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        diamond.finalizeSetup();

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(v1)
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        assertTrue(
            diamond.supplyChangeByOwnerNotAllowed()
        );

        AdminFacet v2 = new AdminFacet();

        diamond.proposeSelector(
            SEL_ALLOW,
            address(v2)
        );

        vm.warp(
            block.timestamp + DELAY
        );

        diamond.executeSelectorChange(
            SEL_ALLOW
        );

        assertEq(
            diamond.selectorToFacet(SEL_ALLOW),
            address(v2)
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        assertTrue(
            diamond.supplyChangeByOwnerNotAllowed()
        );
    }

    // ---- onlyDelegateCall ----

    function test_onlyDelegateCall_directFacetCall_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        admin.disAllowSupplyChangeByOwner();
    }
}
