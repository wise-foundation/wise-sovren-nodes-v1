// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";

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
 * @dev Exercises the bulk interest-admin primitives. The load-bearing
 * properties: a bulk set is indistinguishable from the equivalent
 * run of single sets, the accumulator stays in lockstep with the sum
 * of the buckets across every path including repeated addresses in
 * one call, the sync restamps without discarding accrual in either
 * rate regime, and the whole launch runbook (bulk set, sync every
 * holder, flip the rate) executes atomically through the multicall
 * facet so no holder accrues the new rate retroactively.
 */
contract WiseSovrenNodesInterestAdminBulkTest is DiamondTestHarness {

    event CashedInterestSet(
        address indexed user,
        uint256 previousAmount,
        uint256 newAmount
    );

    event TotalCashedInterestChanged(
        uint256 totalCashedInterest
    );

    event InterestSynced(
        address indexed user,
        uint256 syncedAt
    );

    uint256 internal constant PRINCIPAL = 10_000 * 1e6;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant FLIP_RATE = 2000;

    address internal alice = address(0xA1);
    address internal bob = address(0xA2);
    address internal carol = address(0xA3);
    address internal stranger = address(0xBEEF);

    WiseSovrenNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            1_700_000_000
        );

        usd = new MockUSD();

        diamond = _deployDiamondAtRate(
            address(usd),
            0
        );

        AdminFacet(address(diamond)).mintSupply(
            alice,
            PRINCIPAL
        );

        AdminFacet(address(diamond)).mintSupply(
            bob,
            PRINCIPAL
        );

        AdminFacet(address(diamond)).mintSupply(
            carol,
            PRINCIPAL
        );

        usd.mint(
            address(diamond),
            1_000_000 * 1e6
        );
    }

    function _three(
        address _a,
        address _b,
        address _c
    )
        internal
        pure
        returns (address[] memory users)
    {
        users = new address[](3);
        users[0] = _a;
        users[1] = _b;
        users[2] = _c;
    }

    function _amounts(
        uint256 _a,
        uint256 _b,
        uint256 _c
    )
        internal
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](3);
        amounts[0] = _a;
        amounts[1] = _b;
        amounts[2] = _c;
    }

    function _one(
        address _a
    )
        internal
        pure
        returns (address[] memory users)
    {
        users = new address[](1);
        users[0] = _a;
    }

    // ---- setCashedInterestBulk ----

    function test_setCashedInterestBulk_setsEveryBucket()
        public
    {
        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(1e6, 2e6, 3e6)
        );

        assertEq(diamond.cashedInterest(alice), 1e6);
        assertEq(diamond.cashedInterest(bob), 2e6);
        assertEq(diamond.cashedInterest(carol), 3e6);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 6e6);
    }

    function test_setCashedInterestBulk_emitsPerEntryAndOneTotal()
        public
    {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit CashedInterestSet(alice, 0, 1e6);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit CashedInterestSet(bob, 0, 2e6);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit CashedInterestSet(carol, 0, 3e6);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit TotalCashedInterestChanged(6e6);

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(1e6, 2e6, 3e6)
        );
    }

    function test_setCashedInterestBulk_matchesRepeatedSingleSets()
        public
    {
        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(1e6, 2e6, 3e6)
        );

        uint256 bulkTotal = CashedInterestFacet(address(diamond)).getTotalCashedInterest();

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(0, 0, 0)
        );

        InterestAdminFacet(address(diamond)).setCashedInterest(alice, 1e6);
        InterestAdminFacet(address(diamond)).setCashedInterest(bob, 2e6);
        InterestAdminFacet(address(diamond)).setCashedInterest(carol, 3e6);

        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), bulkTotal);
        assertEq(diamond.cashedInterest(alice), 1e6);
        assertEq(diamond.cashedInterest(bob), 2e6);
        assertEq(diamond.cashedInterest(carol), 3e6);
    }

    function test_setCashedInterestBulk_duplicateAddress_lastWriteWins()
        public
    {
        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, alice, bob),
            _amounts(1e6, 7e6, 2e6)
        );

        assertEq(diamond.cashedInterest(alice), 7e6);
        assertEq(diamond.cashedInterest(bob), 2e6);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 9e6);
    }

    function test_setCashedInterestBulk_zeroAmount_clearsBucket()
        public
    {
        InterestAdminFacet(address(diamond)).setCashedInterest(alice, 5e6);

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _one(alice),
            _amountsOne(0)
        );

        assertEq(diamond.cashedInterest(alice), 0);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 0);
    }

    function test_setCashedInterestBulk_doesNotStampLastSync()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        uint256 stampBefore = diamond.lastSyncTimeStamp(alice);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _one(alice),
            _amountsOne(1e6)
        );

        assertEq(diamond.lastSyncTimeStamp(alice), stampBefore);
        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_setCashedInterestBulk_lengthMismatch_reverts()
        public
    {
        address[] memory users = _three(alice, bob, carol);
        uint256[] memory amounts = new uint256[](2);

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            users,
            amounts
        );
    }

    function test_setCashedInterestBulk_emptyArrays_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            new address[](0),
            new uint256[](0)
        );
    }

    function test_setCashedInterestBulk_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _one(address(0)),
            _amountsOne(1e6)
        );
    }

    function test_setCashedInterestBulk_diamondAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _one(address(diamond)),
            _amountsOne(1e6)
        );
    }

    function test_setCashedInterestBulk_nonMaster_reverts()
        public
    {
        address[] memory users = _one(alice);
        uint256[] memory amounts = _amountsOne(1e6);

        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(stranger);
        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            users,
            amounts
        );
    }

    function test_setCashedInterestBulk_latchThrown_reverts()
        public
    {
        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SupplyChangeNotAllowed.selector
        );

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _one(alice),
            _amountsOne(1e6)
        );
    }

    function test_setCashedInterestBulk_directFacetCall_reverts()
        public
    {
        InterestAdminFacet facet = new InterestAdminFacet();

        address[] memory users = _one(alice);
        uint256[] memory amounts = _amountsOne(1e6);

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.setCashedInterestBulk(
            users,
            amounts
        );
    }

    // ---- syncInterestBulk ----

    function test_syncInterestBulk_zeroRate_restampsWithoutBanking()
        public
    {
        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _three(alice, bob, carol)
        );

        assertEq(diamond.lastSyncTimeStamp(alice), block.timestamp);
        assertEq(diamond.lastSyncTimeStamp(bob), block.timestamp);
        assertEq(diamond.cashedInterest(alice), 0);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 0);
    }

    function test_syncInterestBulk_liveRate_banksThenRestamps()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        uint256 expected = PRINCIPAL * FLIP_RATE / 10_000;

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _one(alice)
        );

        assertEq(diamond.cashedInterest(alice), expected);
        assertEq(diamond.getPendingInterest(alice), 0);
        assertEq(diamond.lastSyncTimeStamp(alice), block.timestamp);
    }

    function test_syncInterestBulk_emitsPerUser()
        public
    {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit InterestSynced(alice, block.timestamp);

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _one(alice)
        );
    }

    function test_syncInterestBulk_duplicateAddress_isIdempotent()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _three(alice, alice, alice)
        );

        assertEq(
            diamond.cashedInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_syncInterestBulk_latchThrown_stillWorks()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            FLIP_RATE
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _one(alice)
        );

        assertEq(
            diamond.cashedInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_syncInterestBulk_emptyArray_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            new address[](0)
        );
    }

    function test_syncInterestBulk_zeroAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _one(address(0))
        );
    }

    function test_syncInterestBulk_diamondAddress_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        InterestAdminFacet(address(diamond)).syncInterestBulk(
            _one(address(diamond))
        );
    }

    function test_syncInterestBulk_nonMaster_reverts()
        public
    {
        address[] memory users = _one(alice);

        vm.expectRevert(
            NotMaster.selector
        );

        vm.prank(stranger);
        InterestAdminFacet(address(diamond)).syncInterestBulk(
            users
        );
    }

    function test_syncInterestBulk_directFacetCall_reverts()
        public
    {
        InterestAdminFacet facet = new InterestAdminFacet();

        address[] memory users = _one(alice);

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.syncInterestBulk(
            users
        );
    }

    // ---- the launch runbook, atomically ----

    function test_kickoffRunbook_viaMulticall_accrualStartsAtFlip()
        public
    {
        vm.warp(
            block.timestamp + 3 * SECONDS_IN_YEAR
        );

        address[] memory holders = _three(alice, bob, carol);

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(
            InterestAdminFacet.setCashedInterestBulk.selector,
            holders,
            _amounts(1e6, 2e6, 3e6)
        );

        calls[1] = abi.encodeWithSelector(
            InterestAdminFacet.syncInterestBulk.selector,
            holders
        );

        calls[2] = abi.encodeWithSelector(
            AdminFacet.setInterestRate.selector,
            FLIP_RATE
        );

        MulticallFacet(address(diamond)).multicall(
            calls
        );

        uint256 flipAt = block.timestamp;

        assertEq(diamond.interestRate(), FLIP_RATE);
        assertEq(diamond.getPendingInterest(alice), 0);
        assertEq(diamond.getPendingInterest(bob), 0);
        assertEq(diamond.getPendingInterest(carol), 0);
        assertEq(diamond.lastSyncTimeStamp(alice), flipAt);
        assertEq(diamond.cashedInterest(alice), 1e6);

        vm.warp(
            block.timestamp + SECONDS_IN_YEAR
        );

        assertEq(
            diamond.getPendingInterest(alice),
            PRINCIPAL * FLIP_RATE / 10_000
        );
    }

    function test_kickoffRunbook_grantedBucketIsClaimable()
        public
    {
        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(1e6, 2e6, 3e6)
        );

        vm.prank(alice);
        UserFacet(address(diamond)).claimInterest();

        assertEq(usd.balanceOf(alice), 1e6);
        assertEq(CashedInterestFacet(address(diamond)).getTotalCashedInterest(), 5e6);
    }

    function testFuzz_setCashedInterestBulk_totalMatchesSumOfBuckets(
        uint256 _a,
        uint256 _b,
        uint256 _c
    )
        public
    {
        uint256 a = bound(_a, 0, 1_000_000 * 1e6);
        uint256 b = bound(_b, 0, 1_000_000 * 1e6);
        uint256 c = bound(_c, 0, 1_000_000 * 1e6);

        InterestAdminFacet(address(diamond)).setCashedInterestBulk(
            _three(alice, bob, carol),
            _amounts(a, b, c)
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            diamond.cashedInterest(alice)
                + diamond.cashedInterest(bob)
                + diamond.cashedInterest(carol)
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            a + b + c
        );
    }

    function _amountsOne(
        uint256 _a
    )
        internal
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](1);
        amounts[0] = _a;
    }
}
