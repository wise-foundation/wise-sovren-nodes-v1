// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";

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
 * @dev Drives the queue order book with bounded random join / leave /
 * reduce / fulfill actions across the 17 allowed incentive tiers. Every
 * action is wrapped in `try/catch` so invalid attempts (wrong owner,
 * empty bucket, below-minimum amount) don't abort the run.
 */
contract QueueInvariantHandler is Test {

    WiseSovrenNodesDiamond internal immutable diamond;
    MockUSD internal immutable usd;

    address internal immutable a0;
    address internal immutable a1;
    address internal immutable a2;

    constructor(
        WiseSovrenNodesDiamond _diamond,
        MockUSD _usd,
        address[3] memory _actors
    ) {
        diamond = _diamond;
        usd = _usd;
        a0 = _actors[0];
        a1 = _actors[1];
        a2 = _actors[2];
    }

    function _actor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        uint256 i = _seed % 3;

        if (i == 0) {
            return a0;
        }

        if (i == 1) {
            return a1;
        }

        return a2;
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

    function joinQue(
        uint256 _actorSeed,
        uint256 _tierSeed,
        uint256 _amountSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 minDep = diamond.minDepositAmount();
        uint256 bal = diamond.balanceOf(actor);

        if (bal < minDep) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            minDep,
            bal
        );

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).joinQue(amount, incentive) {} catch {}
    }

    function leaveQue(
        uint256 _actorSeed,
        uint256 _tierSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 id = diamond.currentOrderIdByIncentive(incentive);

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).leaveQue(id, incentive) {} catch {}
    }

    function reduceQue(
        uint256 _actorSeed,
        uint256 _tierSeed,
        uint256 _reduceSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 id = diamond.currentOrderIdByIncentive(incentive);

        uint256 reduceBy = bound(
            _reduceSeed,
            1,
            1_000_000 * 1e6
        );

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).reduceQueAmount(id, incentive, reduceBy) {} catch {}
    }

    function fulfill(
        uint256 _actorSeed,
        uint256 _tierSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentive = _tier(_tierSeed);

        uint256 id = diamond.currentOrderIdByIncentive(incentive);

        vm.prank(
            actor
        );

        try QueueFulfillFacet(address(diamond)).fulfillOrder(id, incentive) {} catch {}
    }

    function switchQue(
        uint256 _actorSeed,
        uint256 _tierSeedA,
        uint256 _tierSeedB
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentiveA = _tier(_tierSeedA);
        int256 incentiveB = _tier(_tierSeedB);

        if (incentiveA == incentiveB) {
            return;
        }

        uint256 id = diamond.currentOrderIdByIncentive(incentiveA);

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(id, incentiveA, incentiveB) {} catch {}
    }

    function switchQuePartial(
        uint256 _actorSeed,
        uint256 _tierSeedA,
        uint256 _tierSeedB,
        uint256 _amountSeed
    )
        external
    {
        address actor = _actor(_actorSeed);
        int256 incentiveA = _tier(_tierSeedA);
        int256 incentiveB = _tier(_tierSeedB);

        if (incentiveA == incentiveB) {
            return;
        }

        uint256 id = diamond.currentOrderIdByIncentive(incentiveA);

        uint256 amount = bound(
            _amountSeed,
            1,
            1_000_000 * 1e6
        );

        vm.prank(
            actor
        );

        try QueueJoinLeaveFacet(address(diamond)).switchQueIncentivePartial(id, incentiveA, incentiveB, amount) {} catch {}
    }
}

/**
 * @dev Stateful-fuzz invariant: the global `totalActiveOrders` counter
 * must always equal the sum of the per-incentive counters, and each
 * bucket's current-order pointer must stay within its allocation range —
 * across any sequence of join / leave / reduce / fulfill.
 */
contract QueueConservationInvariantTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;
    QueueInvariantHandler handler;

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployDiamondWithQueue(
            address(usd)
        );

        address[3] memory actors = [
            user1,
            user2,
            user3
        ];

        for (uint256 i = 0; i < actors.length; i++) {
            AdminFacet(address(diamond)).mintSupply(
                actors[i],
                10_000_000 * 1e6
            );

            usd.mint(
                actors[i],
                1_000_000_000 * 1e6
            );

            vm.prank(
                actors[i]
            );

            IERC20(address(usd)).approve(
                address(diamond),
                type(uint256).max
            );
        }

        handler = new QueueInvariantHandler(
            diamond,
            usd,
            actors
        );

        targetContract(
            address(handler)
        );
    }

    function _tiers()
        internal
        pure
        returns (int256[17] memory)
    {
        return [
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
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_totalActiveOrdersEqualsSumPerIncentive()
        public
        view
    {
        int256[17] memory tiers = _tiers();

        uint256 sum;

        for (uint256 i = 0; i < tiers.length; i++) {
            sum += diamond.activeOrderCountByIncentive(
                tiers[i]
            );
        }

        assertEq(
            diamond.totalActiveOrders(),
            sum,
            "totalActiveOrders desynced from per-incentive counts"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_currentOrderWithinAllocation()
        public
        view
    {
        int256[17] memory tiers = _tiers();

        for (uint256 i = 0; i < tiers.length; i++) {
            assertLe(
                diamond.currentOrderIdByIncentive(tiers[i]),
                diamond.earliestValidQueMemberByIncentive(tiers[i]),
                "current order pointer beyond allocation"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_linkedListWalkMatchesCount()
        public
        view
    {
        int256[17] memory tiers = _tiers();

        for (uint256 i = 0; i < tiers.length; i++) {
            int256 incentive = tiers[i];

            uint256 earliest = diamond.earliestValidQueMemberByIncentive(incentive);
            uint256 cur = diamond.currentOrderIdByIncentive(incentive);

            uint256 walked;
            uint256 guard;

            while (cur < earliest && guard < earliest + 5) {
                (
                    ,
                    uint256 amt,
                    ,
                    uint256 headPointer
                ) = diamond.QueMemberByIdAndIncentive(
                    cur,
                    incentive
                );

                if (amt > 0) {
                    walked++;
                }

                cur = headPointer;
                guard++;
            }

            assertEq(
                walked,
                diamond.activeOrderCountByIncentive(incentive),
                "linked-list live-order walk desynced from activeOrderCount"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_switch_conservesEscrowedShares()
        public
        view
    {
        uint256 sumProxy = diamond.proxyBalance(user1)
            + diamond.proxyBalance(user2)
            + diamond.proxyBalance(user3);

        assertEq(
            diamond.balanceOf(address(diamond)),
            sumProxy,
            "escrowed vault shares desynced from sum of proxy balances"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_switch_contractAccruesNothing()
        public
        view
    {
        assertEq(
            diamond.getPendingInterest(address(diamond)),
            0,
            "contract accrued pending interest"
        );

        assertEq(
            diamond.cashedInterest(address(diamond)),
            0,
            "contract accrued cashed interest"
        );

        assertEq(
            diamond.proxyBalance(address(diamond)),
            0,
            "contract holds a proxy balance"
        );

        assertEq(
            diamond.currentProxyBenefactor(),
            address(0),
            "proxy benefactor not reset"
        );
    }
}
