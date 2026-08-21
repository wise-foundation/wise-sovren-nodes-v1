// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../../src/diamond/vault/facets/Permit2UserFacet.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";

/**
 * @dev Minimal slice of the non-standard Tether ABI. `approve`
 * returns no value, so the OZ `IERC20` interface decodes a stray
 * bool that isn't there and reverts; this interface drops the
 * return so the call works against real mainnet USDT.
 */
interface IUSDTLike {

    function approve(
        address _spender,
        uint256 _amount
    )
        external;

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);
}

/**
 * @dev `DOMAIN_SEPARATOR` view on the canonical Permit2 deployment,
 * needed to construct the EIP-712 digest for `permitTransferFrom`.
 */
interface IPermit2Domain {

    function DOMAIN_SEPARATOR()
        external
        view
        returns (bytes32);
}

/**
 * @dev Shared scaffolding for the fork tests: holds the diamond +
 * user state and exposes the Permit2 signing helper. Subclasses
 * select a fork in `setUp` and set `usd` to the real token before
 * invoking `_deployDiamond`.
 */
abstract contract ForkBase is DiamondTestHarness {

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256(
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address internal usd;
    WiseSovrenNodesDiamond internal diamond;

    uint256 internal constant USER_PK = 0xA11CE;
    address internal user;

    function _signPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(
                TOKEN_PERMISSIONS_TYPEHASH,
                usd,
                _amount
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                tokenPermissionsHash,
                address(diamond),
                _nonce,
                _deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2Domain(CANONICAL_PERMIT2).DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (
            uint8 v,
            bytes32 r,
            bytes32 s
        ) = vm.sign(
            USER_PK,
            digest
        );

        return abi.encodePacked(
            r,
            s,
            v
        );
    }
}

/**
 * @dev End-to-end fork test against real mainnet USDT and the real
 * Permit2 deployment at 0x000000000022D473030F116dDEE9F6B43aC78BA3.
 * Validates EIP-712 domain separator, type hash, and signature
 * encoding by submitting actual signatures the real Permit2
 * contract recovers and accepts.
 */
contract ForkMainnetUSDTPermit2Test is ForkBase {

    address internal constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        usd = USDT_MAINNET;
        user = vm.addr(USER_PK);

        diamond = _deployDiamond(
            usd
        );

        deal(
            usd,
            user,
            1_000_000 * 1e6
        );

        deal(
            usd,
            address(diamond),
            100_000_000 * 1e6
        );

        vm.prank(
            user
        );

        IUSDTLike(usd).approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    function test_fork_mainnetUSDT_depositWithPermit2()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertEq(
            diamond.balanceOf(user),
            amount,
            "shares minted from real USDT via real Permit2"
        );

        assertEq(
            IERC20(usd).balanceOf(thirdPty),
            amount,
            "real USDT moved to thirdPartyAddress via Permit2"
        );
    }

    function test_fork_mainnetUSDT_depositAndClaimInterestWithPermit2()
        public
    {
        _seedFirstDeposit();

        vm.warp(
            block.timestamp + 31_540_000
        );

        uint256 amount = 500 * 1e6;
        uint256 nonce = 2;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        uint256 usdBefore = IERC20(usd).balanceOf(user);

        vm.prank(
            user
        );

        uint256 claimed = Permit2UserFacet(address(diamond)).depositAndClaimInterestWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertGt(
            claimed,
            0,
            "real interest accrued and claimed"
        );

        assertEq(
            IERC20(usd).balanceOf(user),
            usdBefore - amount + claimed,
            "user nets the interest payout in real USDT"
        );
    }

    function test_fork_mainnetUSDT_depositAndCompoundInterestWithPermit2()
        public
    {
        _seedFirstDeposit();

        vm.warp(
            block.timestamp + 31_540_000
        );

        uint256 amount = 500 * 1e6;
        uint256 nonce = 2;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        uint256 sharesBefore = diamond.balanceOf(user);

        vm.prank(
            user
        );

        uint256 compounded = Permit2UserFacet(address(diamond)).depositAndCompoundInterestWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertGt(
            compounded,
            0,
            "real interest compounded into shares"
        );

        assertEq(
            diamond.balanceOf(user),
            sharesBefore + amount + compounded,
            "shares = prior + new deposit + compounded interest"
        );
    }

    function test_fork_mainnetUSDT_permit2_expiredDeadline_realRevert()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.warp(
            deadline + 1
        );

        vm.prank(
            user
        );

        vm.expectRevert();

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );
    }

    function test_fork_mainnetUSDT_permit2_nonceReplay_realRevert()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 42;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        vm.prank(
            user
        );

        vm.expectRevert();

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );
    }

    function test_fork_mainnetUSDT_permit2_parityWithApprove()
        public
    {
        uint256 amount = 500 * 1e6;

        address legacyUser = address(0xBEEF);

        deal(
            usd,
            legacyUser,
            1_000_000 * 1e6
        );

        vm.prank(
            legacyUser
        );

        IUSDTLike(usd).approve(
            address(diamond),
            amount
        );

        vm.prank(
            legacyUser
        );

        UserFacet(address(diamond)).deposit(
            amount
        );

        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertEq(
            diamond.balanceOf(user),
            diamond.balanceOf(legacyUser),
            "Permit2 path == approve+deposit path on real USDT"
        );

        assertEq(
            IERC20(usd).balanceOf(thirdPty),
            amount * 2,
            "both flows land at thirdPartyAddress"
        );
    }

    function _seedFirstDeposit()
        internal
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );
    }
}

contract ForkMainnetUSDCPermit2Test is ForkBase {

    address internal constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        usd = USDC_MAINNET;
        user = vm.addr(USER_PK);

        diamond = _deployDiamond(
            usd
        );

        deal(
            usd,
            user,
            1_000_000 * 1e6
        );

        vm.prank(
            user
        );

        IUSDTLike(usd).approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    function test_fork_mainnetUSDC_depositWithPermit2()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertEq(
            diamond.balanceOf(user),
            amount,
            "shares minted from real mainnet USDC via Permit2"
        );

        assertEq(
            IERC20(usd).balanceOf(thirdPty),
            amount,
            "real mainnet USDC moved to thirdPartyAddress via Permit2"
        );
    }
}

contract ForkArbitrumUSDCPermit2Test is ForkBase {

    address internal constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function setUp()
        public
    {
        vm.createSelectFork(
            "arbitrum"
        );

        usd = USDC_ARB;
        user = vm.addr(USER_PK);

        diamond = _deployDiamond(
            usd
        );

        deal(
            usd,
            user,
            1_000_000 * 1e6
        );

        vm.prank(
            user
        );

        IUSDTLike(usd).approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    function test_fork_arbUSDC_depositWithPermit2()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertEq(
            diamond.balanceOf(user),
            amount,
            "shares minted from real arb USDC via Permit2"
        );

        assertEq(
            IERC20(usd).balanceOf(thirdPty),
            amount,
            "real arb USDC moved to thirdPartyAddress via Permit2"
        );
    }
}

contract ForkArbitrumUSDT0Permit2Test is ForkBase {

    address internal constant USDT0_ARB = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    function setUp()
        public
    {
        vm.createSelectFork(
            "arbitrum"
        );

        usd = USDT0_ARB;
        user = vm.addr(USER_PK);

        diamond = _deployDiamond(
            usd
        );

        deal(
            usd,
            user,
            1_000_000 * 1e6
        );

        vm.prank(
            user
        );

        IUSDTLike(usd).approve(
            CANONICAL_PERMIT2,
            type(uint256).max
        );
    }

    function test_fork_arbUSDT0_depositWithPermit2()
        public
    {
        uint256 amount = 500 * 1e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            amount,
            nonce,
            deadline
        );

        vm.prank(
            user
        );

        Permit2UserFacet(address(diamond)).depositWithPermit2(
            amount,
            nonce,
            deadline,
            sig
        );

        assertEq(
            diamond.balanceOf(user),
            amount,
            "shares minted from real USDT0 via Permit2"
        );

        assertEq(
            IERC20(usd).balanceOf(thirdPty),
            amount,
            "real USDT0 moved to thirdPartyAddress via Permit2"
        );
    }
}
