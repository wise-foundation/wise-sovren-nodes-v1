// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";

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
 * @dev Differential storage-equivalence suite. Proves the fused
 * `switchQueIncentive` lands in byte-identical state to `leaveQue` +
 * `joinQue`, and `switchQueIncentivePartial` to `reduceQueAmount` +
 * `joinQue`, using `vm.snapshotState` / `vm.revertToState` to run both
 * paths from the exact same start (same block, no `vm.warp` between the
 * two-call baseline's sub-calls). The equivalence envelope requires the
 * shipped default `transferHookFacet == address(0)`, asserted up front.
 */
contract WiseSovrenNodesSwitchQueIncentiveEquivalenceTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond vault;

    address user1 = address(0xA1);
    address user2 = address(0xA2);

    struct QueueSnap {
        uint256 total;
        uint256 countA;
        uint256 curA;
        uint256 earlA;
        uint256 countB;
        uint256 curB;
        uint256 earlB;
        address[8] mA;
        uint256[8] amtA;
        uint256[8] tailA;
        uint256[8] headA;
        address[8] mB;
        uint256[8] amtB;
        uint256[8] tailB;
        uint256[8] headB;
        uint256 proxyUser;
        uint256 cashedUser;
        uint256 syncUser;
        uint256 sharesUser;
        uint256 sharesVault;
        uint256 supply;
        uint256 usdUser;
        uint256 usdVault;
        uint256 usdTp;
        address benefactor;
    }

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        vault = _deployDiamondWithQueue(
            address(usd)
        );

        AdminFacet(address(vault)).mintSupply(
            user1,
            1_000_000 * 1e6
        );

        AdminFacet(address(vault)).mintSupply(
            user2,
            1_000_000 * 1e6
        );
    }

    // ---- capture / assert ----

    function _capture(
        int256 _a,
        int256 _b,
        address _user
    )
        internal
        view
        returns (QueueSnap memory s)
    {
        s.total = vault.totalActiveOrders();

        s.countA = vault.activeOrderCountByIncentive(_a);
        s.curA = vault.currentOrderIdByIncentive(_a);
        s.earlA = vault.earliestValidQueMemberByIncentive(_a);

        s.countB = vault.activeOrderCountByIncentive(_b);
        s.curB = vault.currentOrderIdByIncentive(_b);
        s.earlB = vault.earliestValidQueMemberByIncentive(_b);

        for (uint256 i; i < 8; i++) {
            (
                s.mA[i],
                s.amtA[i],
                s.tailA[i],
                s.headA[i]
            ) = vault.QueMemberByIdAndIncentive(
                i,
                _a
            );

            (
                s.mB[i],
                s.amtB[i],
                s.tailB[i],
                s.headB[i]
            ) = vault.QueMemberByIdAndIncentive(
                i,
                _b
            );
        }

        s.proxyUser = vault.proxyBalance(_user);
        s.cashedUser = vault.cashedInterest(_user);
        s.syncUser = vault.lastSyncTimeStamp(_user);
        s.sharesUser = vault.balanceOf(_user);
        s.sharesVault = vault.balanceOf(address(vault));
        s.supply = vault.totalSupply();
        s.usdUser = usd.balanceOf(_user);
        s.usdVault = usd.balanceOf(address(vault));
        s.usdTp = usd.balanceOf(thirdPty);
        s.benefactor = vault.currentProxyBenefactor();
    }

    function _assertSnapEq(
        QueueSnap memory _x,
        QueueSnap memory _y
    )
        internal
        pure
    {
        assertEq(
            _x.total,
            _y.total,
            "totalActiveOrders"
        );

        assertEq(
            _x.countA,
            _y.countA,
            "countA"
        );

        assertEq(
            _x.curA,
            _y.curA,
            "curA"
        );

        assertEq(
            _x.earlA,
            _y.earlA,
            "earlA"
        );

        assertEq(
            _x.countB,
            _y.countB,
            "countB"
        );

        assertEq(
            _x.curB,
            _y.curB,
            "curB"
        );

        assertEq(
            _x.earlB,
            _y.earlB,
            "earlB"
        );

        for (uint256 i; i < 8; i++) {
            assertEq(
                _x.mA[i],
                _y.mA[i],
                "memberA"
            );

            assertEq(
                _x.amtA[i],
                _y.amtA[i],
                "amountA"
            );

            assertEq(
                _x.tailA[i],
                _y.tailA[i],
                "tailA"
            );

            assertEq(
                _x.headA[i],
                _y.headA[i],
                "headA"
            );

            assertEq(
                _x.mB[i],
                _y.mB[i],
                "memberB"
            );

            assertEq(
                _x.amtB[i],
                _y.amtB[i],
                "amountB"
            );

            assertEq(
                _x.tailB[i],
                _y.tailB[i],
                "tailB"
            );

            assertEq(
                _x.headB[i],
                _y.headB[i],
                "headB"
            );
        }

        assertEq(
            _x.proxyUser,
            _y.proxyUser,
            "proxyBalance"
        );

        assertEq(
            _x.cashedUser,
            _y.cashedUser,
            "cashedInterest"
        );

        assertEq(
            _x.syncUser,
            _y.syncUser,
            "lastSyncTimeStamp"
        );

        assertEq(
            _x.sharesUser,
            _y.sharesUser,
            "user shares"
        );

        assertEq(
            _x.sharesVault,
            _y.sharesVault,
            "vault shares"
        );

        assertEq(
            _x.supply,
            _y.supply,
            "totalSupply"
        );

        assertEq(
            _x.usdUser,
            _y.usdUser,
            "user usd"
        );

        assertEq(
            _x.usdVault,
            _y.usdVault,
            "vault usd"
        );

        assertEq(
            _x.usdTp,
            _y.usdTp,
            "third party usd"
        );

        assertEq(
            _x.benefactor,
            _y.benefactor,
            "currentProxyBenefactor"
        );

        assertEq(
            _x.benefactor,
            address(0),
            "benefactor reset to zero"
        );
    }

    // ---- helpers ----

    function _join(
        address _user,
        uint256 _amount,
        int256 _incentive
    )
        internal
        returns (uint256 id)
    {
        vm.prank(
            _user
        );

        (, id) = QueueJoinLeaveFacet(address(vault)).joinQue(
            _amount,
            _incentive
        );
    }

    /**
     * @dev Full-switch equivalence driver. Runs `leaveQue`+`joinQue`
     * from a snapshot, then the fused `switchQueIncentive` from the same
     * snapshot, and asserts identical resulting state.
     */
    function _assertFullEquivalence(
        uint256 _id,
        int256 _a,
        int256 _b,
        uint256 _amount
    )
        internal
    {
        assertEq(
            vault.transferHookFacet(),
            address(0),
            "envelope requires default hook"
        );

        uint256 snap = vm.snapshotState();

        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).leaveQue(
            _id,
            _a
        );

        (
            ,
            uint256 baseNewId
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            _amount,
            _b
        );

        vm.stopPrank();

        QueueSnap memory baseline = _capture(
            _a,
            _b,
            user1
        );

        vm.revertToState(
            snap
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 fusedNewId
        ) = QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            _id,
            _a,
            _b
        );

        QueueSnap memory fused = _capture(
            _a,
            _b,
            user1
        );

        assertEq(
            fusedNewId,
            baseNewId,
            "fused new id == baseline new id"
        );

        _assertSnapEq(
            baseline,
            fused
        );
    }

    // ---- full-switch equivalence cases ----

    function test_switchQueIncentive_equivalence_soleOrder()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        _assertFullEquivalence(
            id,
            0,
            100,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_equivalence_headOrder()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _assertFullEquivalence(
            id,
            0,
            100,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_equivalence_middleOrder()
        public
    {
        _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 idMid = _join(
            user1,
            100 * 1e6,
            0
        );

        _join(
            user1,
            100 * 1e6,
            0
        );

        _assertFullEquivalence(
            idMid,
            0,
            100,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_equivalence_destinationNonEmpty()
        public
    {
        _join(
            user2,
            100 * 1e6,
            100
        );

        _join(
            user2,
            100 * 1e6,
            100
        );

        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        _assertFullEquivalence(
            id,
            0,
            100,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_equivalence_negativeDestination()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        _assertFullEquivalence(
            id,
            0,
            -10_000,
            100 * 1e6
        );
    }

    function test_switchQueIncentive_equivalence_withPendingInterest()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        vm.warp(
            block.timestamp + 365 days
        );

        assertGt(
            vault.getPendingInterest(user1),
            0,
            "pending interest should exist"
        );

        _assertFullEquivalence(
            id,
            0,
            100,
            100 * 1e6
        );
    }

    function testFuzz_switchQueIncentive_equivalence(
        uint256 _amountSeed,
        uint256 _tierSeedA,
        uint256 _tierSeedB
    )
        public
    {
        int256 a = _tier(_tierSeedA);
        int256 b = _tier(_tierSeedB);

        if (a == b) {
            unchecked {
                b = _tier(_tierSeedB + 1);
            }
        }

        if (a == b) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            50 * 1e6,
            500_000 * 1e6
        );

        uint256 id = _join(
            user1,
            amount,
            a
        );

        _assertFullEquivalence(
            id,
            a,
            b,
            amount
        );
    }

    // ---- partial-switch equivalence vs reduceQueAmount + joinQue ----

    function _assertPartialEquivalence(
        uint256 _id,
        int256 _a,
        int256 _b,
        uint256 _amount
    )
        internal
    {
        assertEq(
            vault.transferHookFacet(),
            address(0),
            "envelope requires default hook"
        );

        uint256 snap = vm.snapshotState();

        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).reduceQueAmount(
            _id,
            _a,
            _amount
        );

        (
            ,
            uint256 baseNewId
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            _amount,
            _b
        );

        vm.stopPrank();

        QueueSnap memory baseline = _capture(
            _a,
            _b,
            user1
        );

        vm.revertToState(
            snap
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 fusedNewId
        ) = QueueJoinLeaveFacet(address(vault)).switchQueIncentivePartial(
            _id,
            _a,
            _b,
            _amount
        );

        QueueSnap memory fused = _capture(
            _a,
            _b,
            user1
        );

        assertEq(
            fusedNewId,
            baseNewId,
            "fused new id == baseline new id"
        );

        _assertSnapEq(
            baseline,
            fused
        );
    }

    function test_switchQueIncentivePartial_equivalence_basic()
        public
    {
        uint256 id = _join(
            user1,
            200 * 1e6,
            0
        );

        _assertPartialEquivalence(
            id,
            0,
            100,
            80 * 1e6
        );
    }

    function test_switchQueIncentivePartial_equivalence_destinationNonEmpty()
        public
    {
        _join(
            user2,
            100 * 1e6,
            100
        );

        uint256 id = _join(
            user1,
            300 * 1e6,
            0
        );

        _assertPartialEquivalence(
            id,
            0,
            100,
            120 * 1e6
        );
    }

    function test_switchQueIncentivePartial_equivalence_withPendingInterest()
        public
    {
        uint256 id = _join(
            user1,
            300 * 1e6,
            0
        );

        vm.warp(
            block.timestamp + 200 days
        );

        _assertPartialEquivalence(
            id,
            0,
            100,
            100 * 1e6
        );
    }

    // ---- raw vm.load slot-level equivalence (defense in depth) ----

    /**
     * @dev Locates the moved order's raw struct slots by matching a
     * known order's `member` word against the mapping-slot derivation
     * (base slot discovered dynamically, never hardcoded), then asserts
     * the 4 words of both the vacated source slot and the created
     * destination slot are identical across the fused path and the
     * two-call baseline.
     */
    function test_switchQueIncentive_equivalence_rawStorageDiff()
        public
    {
        uint256 id = _join(
            user1,
            100 * 1e6,
            0
        );

        uint256 base = _findBaseSlot(
            id,
            0,
            user1
        );

        uint256 oldSlot = _memberSlot(
            id,
            0,
            base
        );

        uint256 snap = vm.snapshotState();

        vm.startPrank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).leaveQue(
            id,
            0
        );

        (
            ,
            uint256 baseNewId
        ) = QueueJoinLeaveFacet(address(vault)).joinQue(
            100 * 1e6,
            100
        );

        vm.stopPrank();

        uint256 newSlot = _memberSlot(
            baseNewId,
            100,
            base
        );

        bytes32[4] memory oldWordsBase = _load4(oldSlot);
        bytes32[4] memory newWordsBase = _load4(newSlot);

        vm.revertToState(
            snap
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(vault)).switchQueIncentive(
            id,
            0,
            100
        );

        bytes32[4] memory oldWordsFused = _load4(oldSlot);
        bytes32[4] memory newWordsFused = _load4(newSlot);

        for (uint256 i; i < 4; i++) {
            assertEq(
                oldWordsBase[i],
                oldWordsFused[i],
                "vacated slot word mismatch"
            );

            assertEq(
                newWordsBase[i],
                newWordsFused[i],
                "created slot word mismatch"
            );

            assertEq(
                oldWordsFused[i],
                bytes32(0),
                "vacated slot must be cleared"
            );
        }
    }

    function _memberSlot(
        uint256 _id,
        int256 _incentive,
        uint256 _base
    )
        internal
        pure
        returns (uint256)
    {
        bytes32 inner = keccak256(
            abi.encode(_id, _base)
        );

        return uint256(
            keccak256(
                abi.encode(_incentive, inner)
            )
        );
    }

    function _findBaseSlot(
        uint256 _id,
        int256 _incentive,
        address _knownMember
    )
        internal
        view
        returns (uint256 base)
    {
        for (base = 0; base < 128; base++) {
            uint256 slot = _memberSlot(
                _id,
                _incentive,
                base
            );

            address stored = address(
                uint160(
                    uint256(
                        vm.load(address(vault), bytes32(slot))
                    )
                )
            );

            if (stored == _knownMember) {
                return base;
            }
        }

        revert(
            "QueMemberByIdAndIncentive base slot not found"
        );
    }

    function _load4(
        uint256 _slot
    )
        internal
        view
        returns (bytes32[4] memory words)
    {
        for (uint256 i; i < 4; i++) {
            words[i] = vm.load(
                address(vault),
                bytes32(_slot + i)
            );
        }
    }

    function _tier(
        uint256 _seed
    )
        internal
        pure
        returns (int256)
    {
        int256[17] memory tiers = [
            int256(0),
            int256(100),
            int256(200),
            int256(300),
            int256(500),
            int256(1000),
            int256(1500),
            int256(2500),
            int256(5000),
            int256(-2_000),
            int256(-4_000),
            int256(-6_000),
            int256(-10_000),
            int256(-20_000),
            int256(-50_000),
            int256(-100_000),
            int256(-490_000)
        ];

        return tiers[_seed % 17];
    }
}
