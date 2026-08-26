// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";

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
 * @dev Force-sync griefing regression for the `interestRemainder`
 * carry (slot 63). Interest floors to zero over a single short
 * interval for a small balance, and any party can force a sync on an
 * arbitrary victim — by sending 1 wei of shares (`transfer` /
 * `transferFrom` run `assignInterest(to)`) or, before the fix, by any
 * path that touches the victim. Without the remainder carry, syncing
 * the victim every block reset `lastSyncTimeStamp` before a whole unit
 * ever accrued, so the victim earned nothing. With the carry the
 * dropped sub-unit fraction accumulates, so frequent forced syncs bank
 * essentially the same total as one long sync and the grief is dead.
 */
contract WiseSovrenNodesInterestRemainderGriefTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address victim = address(0xACC1);
    address control = address(0xC0FFEE);
    address attacker = address(0xBAD);

    uint256 constant PRINCIPAL = 5 * 1e6;
    uint256 constant BLOCK_TIME = 12;
    uint256 constant BLOCKS = 500;

    uint256 constant PRECISION_FACTOR_E18 = 1e18;

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

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );
    }

    function _fundAndDeposit(
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.startPrank(
            _user
        );

        usd.approve(
            address(diamond),
            type(uint256).max
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );

        vm.stopPrank();
    }

    function _trigger(
        address _user
    )
        internal
    {
        vm.prank(
            address(diamond)
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            _user
        );
    }

    function _earned(
        address _user
    )
        internal
        view
        returns (uint256)
    {
        return diamond.cashedInterest(_user)
            + diamond.getPendingInterest(_user);
    }

    // ---- 1. proxy-poke force-sync every block stays lossless ----

    function test_grief_frequentForceSync_isLosslessAndNotZeroed()
        public
    {
        _fundAndDeposit(
            victim,
            PRINCIPAL
        );

        _fundAndDeposit(
            control,
            PRINCIPAL
        );

        for (uint256 i = 0; i < BLOCKS; i++) {
            vm.warp(
                block.timestamp + BLOCK_TIME
            );

            if (i == 0) {
                assertEq(
                    diamond.getPendingInterest(victim),
                    0,
                    "grief precondition: a single block of interest must floor to zero"
                );
            }

            _trigger(
                victim
            );
        }

        _trigger(
            control
        );

        uint256 victimEarned = _earned(
            victim
        );

        uint256 controlEarned = _earned(
            control
        );

        assertGt(
            victimEarned,
            0,
            "grief defeated: force-synced victim still earns interest"
        );

        assertApproxEqAbs(
            victimEarned,
            controlEarned,
            2,
            "frequent forced syncs bank the same as one long sync"
        );

        assertLt(
            diamond.interestRemainder(victim),
            PRECISION_FACTOR_E18,
            "carried remainder stays below one base unit of interest"
        );
    }

    // ---- 2. real 1-wei transfer spam vector is defeated ----

    function test_grief_oneWeiTransferSpam_doesNotZeroInterest()
        public
    {
        _fundAndDeposit(
            attacker,
            1_000 * 1e6
        );

        _fundAndDeposit(
            victim,
            PRINCIPAL
        );

        _fundAndDeposit(
            control,
            PRINCIPAL
        );

        for (uint256 i = 0; i < BLOCKS; i++) {
            vm.warp(
                block.timestamp + BLOCK_TIME
            );

            vm.prank(
                attacker
            );

            diamond.transfer(
                victim,
                1
            );
        }

        _trigger(
            control
        );

        uint256 victimEarned = _earned(
            victim
        );

        uint256 controlEarned = _earned(
            control
        );

        assertGt(
            victimEarned,
            0,
            "grief defeated: 1-wei-spammed victim still earns interest"
        );

        assertApproxEqAbs(
            victimEarned,
            controlEarned,
            5,
            "1-wei force-syncs bank essentially the same as one long sync"
        );
    }

    // ---- 3. exactly-zero transfers cannot be used to force a sync ----

    function test_zeroValueTransfer_reverts()
        public
    {
        _fundAndDeposit(
            attacker,
            1_000 * 1e6
        );

        vm.prank(
            attacker
        );

        vm.expectRevert();

        diamond.transfer(
            victim,
            0
        );
    }
}
