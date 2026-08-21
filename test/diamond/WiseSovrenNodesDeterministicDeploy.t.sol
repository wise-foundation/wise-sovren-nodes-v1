// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueViewFacet} from "../../src/diamond/vault/facets/QueueViewFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {RescueFacet} from "../../src/diamond/vault/facets/RescueFacet.sol";
import {GraceFreezeHookFacet} from "../../src/diamond/vault/facets/GraceFreezeHookFacet.sol";
import {GraceAccumHookFacet} from "../../src/diamond/vault/facets/GraceAccumHookFacet.sol";

import {DeployWiseSovrenNodesDiamond} from "../../script/diamond/DeployWiseSovrenNodesDiamond.s.sol";
import {WiseSovrenNodesBootstrap, BootstrapFacets} from "../../script/diamond/WiseSovrenNodesBootstrap.sol";

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
 * @dev Tests for the deterministic deploy machinery: the
 * {WiseSovrenNodesBootstrap} shim must deploy the diamond as its
 * nonce-1 creation, wire every selector, configure router / WISE /
 * deposit gate and hand ownership to the pending master; and the
 * pure CREATE3 address prediction must match an on-chain replay of
 * the exact CreateX proxy bytecode. Inherits the deploy script so
 * the tests exercise the very constants and helpers the production
 * scripts use.
 */
contract WiseSovrenNodesDeterministicDeployTest is Test, DeployWiseSovrenNodesDiamond {

    bytes internal constant CREATE3_PROXY_INITCODE = hex"67363d3d37363d34f03d5260086018f3";

    address internal constant CANONICAL_PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal pendingMaster = address(0xA11CE);
    address internal ccipRouterStub = address(0x9042);
    address internal wiseStub = address(0x715E);

    MockUSD internal usd;

    function setUp()
        public
    {
        usd = new MockUSD();

        if (CANONICAL_PERMIT2_ADDR.code.length == 0) {
            vm.etch(
                CANONICAL_PERMIT2_ADDR,
                hex"00"
            );
        }
    }

    function _buildParams()
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: address(0xCAFE),
            workerAddress: address(0xD00D),
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: 1_000_000 * 1e6,
            interestRate: 2000,
            decimalsValue: 6,
            tokenName: "Wise Sovren Nodes USDC",
            tokenSymbol: "wsnUSDC"
        });
    }

    function _buildFacets()
        internal
        returns (BootstrapFacets memory)
    {
        return BootstrapFacets({
            admin: address(new AdminFacet()),
            proxy: address(new ProxyFacet()),
            user: address(new UserFacet()),
            sweep: address(new SweepFacet()),
            cashedInterest: address(new CashedInterestFacet()),
            burnWise: address(new BurnWiseFacet()),
            move: address(new MoveFacet()),
            bridge: address(new BridgeFacet()),
            permit2: address(new Permit2UserFacet()),
            multicall: address(new MulticallFacet()),
            queueAdmin: address(new QueueAdminFacet()),
            queueJoinLeave: address(new QueueJoinLeaveFacet()),
            queueFulfill: address(new QueueFulfillFacet()),
            queueView: address(new QueueViewFacet()),
            queueForecast: address(new QueueForecastFacet()),
            interestAdmin: address(new InterestAdminFacet()),
            rescue: address(new RescueFacet()),
            graceFreezeHook: address(new GraceFreezeHookFacet()),
            graceAccumHook: address(new GraceAccumHookFacet())
        });
    }

    // ---- 1. shim deploys the diamond at its nonce-1 address ----

    function test_bootstrap_diamondIsNonceOneCreation()
        public
    {
        WiseSovrenNodesBootstrap shim = new WiseSovrenNodesBootstrap(
            _buildParams(),
            _buildFacets(),
            ccipRouterStub,
            wiseStub,
            true,
            pendingMaster
        );

        assertEq(
            address(shim.diamond()),
            vm.computeCreateAddress(
                address(shim),
                1
            )
        );
    }

    // ---- 2. shim wires, configures and hands off ownership ----

    function test_bootstrap_wiresConfiguresAndProposesOwner()
        public
    {
        WiseSovrenNodesBootstrap shim = new WiseSovrenNodesBootstrap(
            _buildParams(),
            _buildFacets(),
            ccipRouterStub,
            wiseStub,
            true,
            pendingMaster
        );

        WiseSovrenNodesDiamond diamond = shim.diamond();

        assertEq(
            diamond.master(),
            address(shim)
        );

        assertEq(
            diamond.proposedMaster(),
            pendingMaster
        );

        assertEq(
            diamond.ccipRouter(),
            ccipRouterStub
        );

        assertEq(
            diamond.WISE_TOKEN(),
            wiseStub
        );

        assertEq(
            diamond.depositsDisabled(),
            true
        );

        assertEq(
            diamond.initialized(),
            false
        );

        assertTrue(
            diamond.transferHookFacet() != address(0)
        );

        assertTrue(
            diamond.depositHookFacet() != address(0)
        );

        assertEq(
            diamond.depositAccumWindow(),
            0
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            0
        );

        assertEq(
            diamond.isSweeper(pendingMaster),
            true
        );

        assertEq(
            diamond.isSweeper(address(shim)),
            false
        );

        assertEq(
            diamond.isSweeper(address(0xD00D)),
            true
        );

        assertEq(
            diamond.isSweeper(address(0xCAFE)),
            true
        );

        vm.prank(
            pendingMaster
        );

        diamond.claimOwnership();

        assertEq(
            diamond.master(),
            pendingMaster
        );

        vm.prank(
            pendingMaster
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            777 * 1e6
        );

        assertEq(
            diamond.totalDepositCap(),
            777 * 1e6
        );
    }

    // ---- 3. zero WISE is skipped, non-dormant stays open ----

    function test_bootstrap_skipsWiseAndStaysOpenWhenConfigured()
        public
    {
        WiseSovrenNodesBootstrap shim = new WiseSovrenNodesBootstrap(
            _buildParams(),
            _buildFacets(),
            ccipRouterStub,
            address(0),
            false,
            pendingMaster
        );

        WiseSovrenNodesDiamond diamond = shim.diamond();

        assertEq(
            diamond.WISE_TOKEN(),
            address(0)
        );

        assertEq(
            diamond.depositsDisabled(),
            false
        );
    }

    // ---- 4. the pinned proxy hash matches the canonical bytecode ----

    function test_create3ProxyInitcodeHash_matchesConstant()
        public
        pure
    {
        assertEq(
            keccak256(CREATE3_PROXY_INITCODE),
            CREATE3_PROXY_INITCODE_HASH
        );
    }

    // ---- 5. full CREATE3 chain replay matches the pure prediction ----

    function test_create3Chain_matchesNonceMath()
        public
    {
        bytes32 salt = keccak256(
            "replay-salt"
        );

        bytes memory proxyInitcode = CREATE3_PROXY_INITCODE;

        address proxy;

        assembly {
            proxy := create2(
                0,
                add(proxyInitcode, 0x20),
                mload(proxyInitcode),
                salt
            )
        }

        assertEq(
            proxy,
            _create2Address(
                address(this),
                salt,
                CREATE3_PROXY_INITCODE_HASH
            )
        );

        bytes memory shimInitcode = abi.encodePacked(
            type(WiseSovrenNodesBootstrap).creationCode,
            abi.encode(
                _buildParams(),
                _buildFacets(),
                ccipRouterStub,
                address(0),
                false,
                pendingMaster
            )
        );

        (
            bool ok,
        ) = proxy.call(
            shimInitcode
        );

        assertTrue(
            ok
        );

        address shim = _nonceOneAddress(
            proxy
        );

        assertGt(
            shim.code.length,
            0
        );

        assertEq(
            address(WiseSovrenNodesBootstrap(shim).diamond()),
            _nonceOneAddress(
                shim
            )
        );
    }

    // ---- 6. salt construction and guarding ----

    function test_makeSalt_laysOutDeployerFlagAndTag()
        public
        view
    {
        address deployer = address(0x1234567890AbcdEF1234567890aBcdef12345678);

        bytes32 salt = makeSalt(
            deployer,
            bytes11("WTN-USDC-01")
        );

        assertEq(
            address(bytes20(salt)),
            deployer
        );

        assertEq(
            salt[20],
            bytes1(0x00)
        );

        assertEq(
            bytes11(salt << 168),
            bytes11("WTN-USDC-01")
        );

        guardedSalt(
            deployer,
            salt
        );
    }

    function test_guardedSalt_rejectsForeignOrProtectedSalt()
        public
    {
        address deployer = address(0xDE7108E4);

        bytes32 foreign = makeSalt(
            address(0xBAD),
            bytes11("WTN-USDC-01")
        );

        vm.expectRevert(
            bytes("DeployWiseSovrenNodesDiamond: salt not guarded by deployer")
        );

        this.guardedSaltExternal(
            deployer,
            foreign
        );

        bytes32 protected = makeSalt(
            deployer,
            bytes11("WTN-USDC-01")
        ) | bytes32(
            uint256(0xFF) << 88
        );

        vm.expectRevert(
            bytes("DeployWiseSovrenNodesDiamond: cross-chain protection byte must be 0x00")
        );

        this.guardedSaltExternal(
            deployer,
            protected
        );
    }

    function guardedSaltExternal(
        address _deployer,
        bytes32 _salt
    )
        external
        pure
        returns (bytes32)
    {
        return guardedSalt(
            _deployer,
            _salt
        );
    }
}
