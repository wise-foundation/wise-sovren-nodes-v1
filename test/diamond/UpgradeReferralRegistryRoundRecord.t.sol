// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {UpgradeReferralRegistry} from "../../script/diamond/UpgradeReferralRegistry.s.sol";

/**
 * @dev Pins the round facet record that splits the registry round into
 * `deployFacets()` and `propose()`: the record round trips all fourteen
 * addresses through its JSON file, `_resolveRoundFacets` prefers the set
 * deployed in the same process, reads the record otherwise, refuses to run
 * without a record and refuses a record whose facets carry no code, and the
 * deploy guard refuses a record whose facets are already deployed while it
 * lets a codeless record (a deploy run that stopped before its transactions
 * were sent) through. Inherits the upgrade script so the tests exercise the
 * helpers the production script uses. The record path is redirected to a
 * test file in the config folder, one file per test because the tests run
 * in parallel, so no real record is touched; each test removes its file.
 * The Permit2 facet constructors require code at the canonical Permit2
 * address, so the setup etches a byte there as the diamond test harness does.
 */
contract UpgradeReferralRegistryRoundRecordTest is Test, UpgradeReferralRegistry {

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    string internal constant NO_RECORD = "UpgradeReferralRegistry: no round facets recorded for this product and network (config/referral-round.<product>.<network>.json), run deployFacets() first";

    string internal constant NO_CODE = "UpgradeReferralRegistry: a recorded round facet has no code (finish the deployFacets() run with --resume)";

    string internal constant ALREADY_DEPLOYED = "UpgradeReferralRegistry: round facets already deployed and recorded (config/referral-round.<product>.<network>.json), propose() reads them";

    string internal recordPath;

    function setUp()
        public
    {
        vm.etch(
            CANONICAL_PERMIT2,
            hex"00"
        );
    }

    function _useRecord(
        string memory _name
    )
        internal
    {
        recordPath = string.concat(
            "config/referral-round.test.",
            _name,
            ".json"
        );

        _removeRecord();
    }

    function _removeRecord()
        internal
    {
        if (vm.exists(recordPath)) {
            vm.removeFile(
                recordPath
            );
        }
    }

    function _roundFacetsPath(
        string memory,
        string memory
    )
        internal
        view
        override
        returns (string memory)
    {
        return recordPath;
    }

    function exposedResolveRoundFacets()
        external
        view
        returns (RoundFacets memory)
    {
        return _resolveRoundFacets();
    }

    function exposedRequireRoundFacetsNotDeployed()
        external
        view
    {
        _requireRoundFacetsNotDeployed(
            "usdc",
            "mainnet"
        );
    }

    function test_saveRoundFacets_roundTripsAllFourteen()
        public
    {
        _useRecord(
            "roundtrip"
        );

        RoundFacets memory deployed = _deployRoundFacets();

        _saveRoundFacets(
            "usdc",
            "mainnet",
            deployed
        );

        assertTrue(
            _roundFacetsRecorded(
                "usdc",
                "mainnet"
            )
        );

        RoundFacets memory loaded = _loadRoundFacets(
            "usdc",
            "mainnet"
        );

        address[] memory expected = _roundFacetArray(
            deployed
        );

        address[] memory actual = _roundFacetArray(
            loaded
        );

        assertEq(expected.length, 14);

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(actual[i], expected[i]);
            assertGt(expected[i].code.length, 0);
        }

        assertEq(
            _roundFacetsCodeCount(
                loaded
            ),
            14
        );

        _removeRecord();
    }

    function test_resolveRoundFacets_prefersFacetsDeployedHere()
        public
    {
        _useRecord(
            "deployedhere"
        );

        RoundFacets memory deployed = _deployRoundFacets();

        deployedRoundFacets = deployed;
        roundFacetsDeployedHere = true;

        RoundFacets memory resolved = _resolveRoundFacets();

        assertEq(resolved.adminFacet, deployed.adminFacet);
        assertEq(resolved.cohortMoveHookFacet, deployed.cohortMoveHookFacet);

        assertFalse(
            _roundFacetsRecorded(
                "usdc",
                "mainnet"
            )
        );
    }

    function test_resolveRoundFacets_readsRecord()
        public
    {
        _useRecord(
            "readsrecord"
        );

        RoundFacets memory deployed = _deployRoundFacets();

        _saveRoundFacets(
            "usdc",
            "mainnet",
            deployed
        );

        RoundFacets memory resolved = this.exposedResolveRoundFacets();

        assertEq(resolved.userFacet, deployed.userFacet);
        assertEq(resolved.autoCompoundFacet, deployed.autoCompoundFacet);

        _removeRecord();
    }

    function test_resolveRoundFacets_revertsWithoutRecord()
        public
    {
        _useRecord(
            "norecord"
        );

        vm.expectRevert(
            bytes(NO_RECORD)
        );

        this.exposedResolveRoundFacets();
    }

    function test_resolveRoundFacets_revertsWhenRecordedFacetHasNoCode()
        public
    {
        _useRecord(
            "nocode"
        );

        RoundFacets memory deployed = _deployRoundFacets();

        deployed.referralFacet = address(0xBEEF);

        _saveRoundFacets(
            "usdc",
            "mainnet",
            deployed
        );

        vm.expectRevert(
            bytes(NO_CODE)
        );

        this.exposedResolveRoundFacets();

        _removeRecord();
    }

    function test_requireRoundFacetsNotDeployed_passesWithoutRecord()
        public
    {
        _useRecord(
            "guardnorecord"
        );

        _requireRoundFacetsNotDeployed(
            "usdc",
            "mainnet"
        );
    }

    function test_requireRoundFacetsNotDeployed_passesOnCodelessRecord()
        public
    {
        _useRecord(
            "guardcodeless"
        );

        RoundFacets memory phantom;

        _saveRoundFacets(
            "usdc",
            "mainnet",
            phantom
        );

        _requireRoundFacetsNotDeployed(
            "usdc",
            "mainnet"
        );

        _removeRecord();
    }

    function test_requireRoundFacetsNotDeployed_revertsOnDeployedRecord()
        public
    {
        _useRecord(
            "guarddeployed"
        );

        RoundFacets memory deployed = _deployRoundFacets();

        _saveRoundFacets(
            "usdc",
            "mainnet",
            deployed
        );

        vm.expectRevert(
            bytes(ALREADY_DEPLOYED)
        );

        this.exposedRequireRoundFacetsNotDeployed();

        _removeRecord();
    }

    function test_roundFacetsCodeCount_countsDeployedOnly()
        public
    {
        RoundFacets memory mixed = _deployRoundFacets();

        mixed.adminFacet = address(0xA1);
        mixed.cohortHookFacet = address(0);

        assertEq(
            _roundFacetsCodeCount(
                mixed
            ),
            12
        );
    }
}
