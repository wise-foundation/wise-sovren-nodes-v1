// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract MockUSDNoPermit is ERC20 {

    constructor()
        ERC20("Mock USD No Permit", "MUSDNP")
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
 * The signature is intentionally ignored - we only validate the
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
 * @dev Smoke + parity tests for {Permit2UserFacet}. Uses a
 * mock Permit2 etched at the canonical
 * `0x000000000022D473030F116dDEE9F6B43aC78BA3` address. Real
 * signature verification is covered by the fork tests.
 */
contract WiseSovrenNodesPermit2FacetTest is DiamondTestHarness {

    MockUSDNoPermit usd;
    WiseSovrenNodesDiamond diamond;

    address user = address(0xA1);
    address user2 = address(0xA2);

    function setUp()
        public
    {
        usd = new MockUSDNoPermit();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
        );

        diamond = _deployDiamond(
            address(usd)
        );

        usd.mint(
            user,
            1_000_000 * 1e6
        );

        usd.mint(
            user2,
            1_000_000 * 1e6
        );

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        vm.prank(
            user
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

    // ---- core paths ----

    function test_smoke_depositWithPermit2()
        public
    {
        uint256 amount = 500 * 1e6;

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            1,
            block.timestamp + 1 hours,
            hex"00"
        );

        assertEq(
            diamond.balanceOf(user),
            amount,
            "shares minted"
        );

        assertEq(
            usd.balanceOf(thirdPty),
            amount,
            "tokens routed through Permit2 to thirdPartyAddress"
        );
    }

    function test_smoke_depositAndClaimInterestWithPermit2()
        public
    {
        _seedFirstDeposit();

        vm.warp(
            block.timestamp + 31_540_000
        );

        uint256 amount = 500 * 1e6;
        uint256 usdBefore = usd.balanceOf(user);

        vm.prank(
            user
        );

        uint256 claimed = Permit2UserFacet(address(diamond)).depositAndClaimInterestWithPermit2(
            amount,
            2,
            block.timestamp + 1 hours,
            hex"00"
        );

        assertGt(
            claimed,
            0,
            "interest accrued"
        );

        assertEq(
            usd.balanceOf(user),
            usdBefore - amount + claimed,
            "user nets the interest payout"
        );
    }

    function test_smoke_depositAndCompoundInterestWithPermit2()
        public
    {
        _seedFirstDeposit();

        vm.warp(
            block.timestamp + 31_540_000
        );

        uint256 amount = 500 * 1e6;
        uint256 sharesBefore = diamond.balanceOf(user);

        vm.prank(
            user
        );

        uint256 compounded = Permit2UserFacet(address(diamond)).depositAndCompoundInterestWithPermit2(
            amount,
            2,
            block.timestamp + 1 hours,
            hex"00"
        );

        assertGt(
            compounded,
            0
        );

        assertEq(
            diamond.balanceOf(user),
            sharesBefore + amount + compounded
        );
    }

    // ---- parity: depositWithPermit2 ≡ approve + deposit ----

    function test_parity_permit2VsApprove()
        public
    {
        uint256 amount = 500 * 1e6;

        vm.prank(
            user2
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            user2
        );

        UserFacet(address(diamond)).deposit(
            amount
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            1,
            block.timestamp + 1 hours,
            hex"00"
        );

        assertEq(
            diamond.balanceOf(user),
            diamond.balanceOf(user2),
            "share parity"
        );

        assertEq(
            usd.balanceOf(thirdPty),
            amount * 2,
            "both deposits landed at thirdPartyAddress"
        );
    }

    // ---- safety: deadline ----

    function test_permit2_expiredDeadlineReverts()
        public
    {
        uint256 amount = 500 * 1e6;

        vm.warp(
            block.timestamp + 2 hours
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            bytes("deadline")
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            1,
            block.timestamp - 1 hours,
            hex"00"
        );
    }

    // ---- safety: constructor guard ----

    function test_constructor_revertsWhenPermit2Missing()
        public
    {
        vm.etch(
            CANONICAL_PERMIT2,
            ""
        );

        vm.expectRevert(
            bytes4(keccak256("Permit2NotDeployed()"))
        );

        new Permit2UserFacet();
    }

    // ---- safety: cap respected ----

    function test_permit2_capExceededReverts()
        public
    {
        uint256 amount = TOTAL_DEPOSIT_CAP + 1;

        vm.prank(
            user
        );

        vm.expectRevert();

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            1,
            block.timestamp + 1 hours,
            hex"00"
        );
    }

    function _seedFirstDeposit()
        internal
    {
        uint256 amount = 500 * 1e6;

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            1,
            block.timestamp + 1 hours,
            hex"00"
        );
    }
}
