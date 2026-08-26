// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {RescueFacet} from "../../src/diamond/vault/facets/RescueFacet.sol";

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

contract MockStray is ERC20 {

    constructor()
        ERC20("Mock Stray", "STRAY")
    {}

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

contract MockNoReturnToken {

    mapping(address => uint256) public balanceOf;

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        balanceOf[_to] += _amount;
    }

    function transfer(
        address _to,
        uint256 _amount
    )
        external
    {
        require(
            balanceOf[msg.sender] >= _amount,
            "MockNoReturnToken: balance"
        );

        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;
    }
}

/**
 * @dev Exercises {RescueFacet}. The load-bearing properties: a
 * stranded token leaves in full or in part exactly to the chosen
 * recipient with the event emitted, non-returning USDT-style tokens
 * work through SafeERC20, the underlying `USD_TOKEN` and the
 * vault's own share token are unreachable, vault accounting is
 * untouched by a rescue, and the master/recipient/delegatecall
 * gates reject.
 */
contract WiseSovrenNodesRescueFacetTest is DiamondTestHarness {

    event TokenRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    uint256 internal constant STRAY_AMOUNT = 100_224_341;

    address internal recipient = address(0xA1);
    address internal stranger = address(0xBEEF);

    WiseSovrenNodesDiamond internal diamond;
    RescueFacet internal rescueFacetInstance;
    MockUSD internal usd;
    MockStray internal stray;
    MockNoReturnToken internal noReturnToken;

    function setUp()
        public
    {
        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        rescueFacetInstance = new RescueFacet();

        diamond.finalizeSetup();

        stray = new MockStray();

        stray.mint(
            address(diamond),
            STRAY_AMOUNT
        );

        noReturnToken = new MockNoReturnToken();

        noReturnToken.mint(
            address(diamond),
            STRAY_AMOUNT
        );
    }

    function _rescue(
        address _token,
        address _to,
        uint256 _amount
    )
        internal
    {
        RescueFacet(address(diamond)).rescueToken(
            _token,
            _to,
            _amount
        );
    }

    function test_masterRescuesFullStrayBalance()
        public
    {
        uint256 supplyBefore = diamond.totalSupply();

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit TokenRescued(
            address(stray),
            recipient,
            STRAY_AMOUNT
        );

        _rescue(
            address(stray),
            recipient,
            STRAY_AMOUNT
        );

        assertEq(
            stray.balanceOf(recipient),
            STRAY_AMOUNT
        );

        assertEq(
            stray.balanceOf(address(diamond)),
            0
        );

        assertEq(
            diamond.totalSupply(),
            supplyBefore
        );
    }

    function test_partialRescueLeavesRemainder()
        public
    {
        uint256 half = STRAY_AMOUNT / 2;

        _rescue(
            address(stray),
            recipient,
            half
        );

        assertEq(
            stray.balanceOf(recipient),
            half
        );

        assertEq(
            stray.balanceOf(address(diamond)),
            STRAY_AMOUNT - half
        );
    }

    function test_rescuesNonReturningToken()
        public
    {
        _rescue(
            address(noReturnToken),
            recipient,
            STRAY_AMOUNT
        );

        assertEq(
            noReturnToken.balanceOf(recipient),
            STRAY_AMOUNT
        );

        assertEq(
            noReturnToken.balanceOf(address(diamond)),
            0
        );
    }

    function test_revertsForUnderlyingToken()
        public
    {
        usd.mint(
            address(diamond),
            STRAY_AMOUNT
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ProtectedToken.selector
        );

        _rescue(
            address(usd),
            recipient,
            STRAY_AMOUNT
        );
    }

    function test_revertsForVaultShareToken()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ProtectedToken.selector
        );

        _rescue(
            address(diamond),
            recipient,
            1
        );
    }

    function test_revertsForZeroRecipient()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        _rescue(
            address(stray),
            address(0),
            STRAY_AMOUNT
        );
    }

    function test_revertsForStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        RescueFacet(address(diamond)).rescueToken(
            address(stray),
            stranger,
            STRAY_AMOUNT
        );
    }

    function test_revertsOnDirectFacetCall()
        public
    {
        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        rescueFacetInstance.rescueToken(
            address(stray),
            recipient,
            STRAY_AMOUNT
        );
    }

    function test_revertsWhenAmountExceedsBalance()
        public
    {
        vm.expectRevert(
            bytes("ERC20: transfer amount exceeds balance")
        );

        _rescue(
            address(stray),
            recipient,
            STRAY_AMOUNT + 1
        );
    }
}
