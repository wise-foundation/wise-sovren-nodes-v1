// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {OwnableMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {NoValue} from "../../src/diamond/shared/OwnableMaster.sol";
import {NotProposed} from "../../src/diamond/shared/OwnableMaster.sol";

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
        public
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Mirrors the legacy blueprint's old-vault stub: exposes
 * `getTotalInterestUser(address)` so the diamond constructor's
 * interest-migration branch can `staticcall` it successfully.
 */
contract MockOldVault {

    mapping(address => uint256) public interestByUser;

    function setInterest(
        address _user,
        uint256 _amount
    )
        external
    {
        interestByUser[_user] = _amount;
    }

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return interestByUser[_user];
    }
}

/**
 * @dev Old-vault stub whose `getTotalInterestUser` always reverts so
 * the constructor migration branch hits the `require(ok)` failure.
 */
contract BadOldVault {

    function getTotalInterestUser(
        address
    )
        external
        pure
        returns (uint256)
    {
        revert(
            "bad"
        );
    }
}

/**
 * @dev Old-vault stub whose `getTotalInterestUser` succeeds but
 * returns no data so the constructor migration branch hits the
 * 32-byte response length check.
 */
contract EmptyReturnOldVault {

    function getTotalInterestUser(
        address
    )
        external
        pure
    {}
}

/**
 * @dev Coverage suite driving the WiseSovrenNodes diamond admin / config
 * surface: {AdminFacet}, {WiseSovrenNodesBaseHelper},
 * {WiseSovrenNodesAdminHelper}, {WiseSovrenNodesDeclarations} and the
 * shared {OwnableMaster}. Ported from the legacy {ForwardVaultERC20}
 * blueprint but routed through the facet casts on the deployed
 * diamond, with the test contract as master. {OwnableMaster} is
 * additionally exercised standalone for a clean 100%.
 */
contract WiseSovrenNodesAdminCoverageTest is DiamondTestHarness {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address attacker = address(0xBEEF);
    address proxy = address(0xC0DE);
    address benefactor = address(0xB1);

    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant PRECISION = 10_000;

    event ProxyBenefactorSet(
        address proxyBeneFactor
    );

    event SupplyChangeByOwnerNotAllowedSet(
        bool supplyChangeByOwnerNotAllowed
    );

    event MintSupply(
        address indexed to,
        uint256 amount
    );

    event BurnSupply(
        address indexed from,
        uint256 amount
    );

    event ThirdPartyAddressSet(
        address thirdPartyAddress
    );

    event InterestRateSet(
        uint256 interestRate
    );

    event BufferInterestRateRaised(
        uint256 newBufferInterestRate
    );

    event TotalDepositCapSet(
        uint256 totalDepositCap
    );

    event MasterProposed(
        address indexed proposer,
        address indexed proposedMaster
    );

    event RenouncedOwnership(
        address indexed previousMaster
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployDiamond(
            address(usd)
        );

        proxy = address(diamond);

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );
    }

    // ---- helpers ----

    function _buildParams(
        address _usd,
        address _thirdParty,
        address _oldVault,
        address[] memory _addrs,
        uint256[] memory _amts,
        uint256 _cap,
        uint256 _rate
    )
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: _usd,
            thirdPartyAddress: _thirdParty,
            workerAddress: worker,
            oldVault: _oldVault,
            initialDistributionAddresses: _addrs,
            initialDistributionAmounts: _amts,
            totalDepositCap: _cap,
            interestRate: _rate,
            decimalsValue: DEFAULT_DECIMALS,
            tokenName: "Wise Sovren Nodes",
            tokenSymbol: "WTN"
        });
    }

    function _emptyAddrs()
        internal
        pure
        returns (address[] memory)
    {
        return new address[](0);
    }

    function _emptyAmts()
        internal
        pure
        returns (uint256[] memory)
    {
        return new uint256[](0);
    }

    // ---- WiseSovrenNodesDeclarations — constructor ----

    function test_constructor_storesConfig()
        public
        view
    {
        assertEq(
            address(diamond.USD_TOKEN()),
            address(usd)
        );

        assertEq(
            diamond.interestRate(),
            INTEREST_RATE
        );

        assertEq(
            diamond.IERC20Decimals(),
            bytes4(keccak256("decimals()"))
        );

        assertEq(
            diamond.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            diamond.thirdPartyAddress(),
            thirdPty
        );

        assertEq(
            diamond.master(),
            master
        );

        assertEq(
            diamond.decimals(),
            DEFAULT_DECIMALS
        );

        assertEq(
            diamond.name(),
            "Wise Sovren Nodes"
        );

        assertEq(
            diamond.symbol(),
            "WTN"
        );
    }

    function test_constructor_initialDistribution()
        public
    {
        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user2;

        uint256[] memory amts = new uint256[](2);
        amts[0] = 100 * 1e6;
        amts[1] = 250 * 1e6;

        WiseSovrenNodesDiamond d = new WiseSovrenNodesDiamond(
            _buildParams(
                address(usd),
                thirdPty,
                address(0),
                addrs,
                amts,
                TOTAL_DEPOSIT_CAP,
                INTEREST_RATE
            )
        );

        assertEq(
            d.balanceOf(user1),
            100 * 1e6
        );

        assertEq(
            d.balanceOf(user2),
            250 * 1e6
        );

        assertEq(
            d.lastSyncTimeStamp(user1),
            block.timestamp
        );

        assertEq(
            d.lastSyncTimeStamp(user2),
            block.timestamp
        );

        assertEq(
            d.totalSupply(),
            350 * 1e6
        );
    }

    function test_constructor_migratesInterestFromOldVault()
        public
    {
        MockOldVault old = new MockOldVault();

        old.setInterest(
            user1,
            12_345
        );

        old.setInterest(
            user2,
            67_890
        );

        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user2;

        uint256[] memory amts = new uint256[](2);
        amts[0] = 100 * 1e6;
        amts[1] = 200 * 1e6;

        WiseSovrenNodesDiamond d = new WiseSovrenNodesDiamond(
            _buildParams(
                address(usd),
                thirdPty,
                address(old),
                addrs,
                amts,
                TOTAL_DEPOSIT_CAP,
                INTEREST_RATE
            )
        );

        assertEq(
            d.cashedInterest(user1),
            12_345
        );

        assertEq(
            d.cashedInterest(user2),
            67_890
        );

        _wireOne(
            d,
            address(new CashedInterestFacet()),
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        assertEq(
            CashedInterestFacet(address(d)).getTotalCashedInterest(),
            12_345 + 67_890
        );
    }

    function test_constructor_migratesInterest_duplicateAddress_totalEqualsLedger()
        public
    {
        MockOldVault old = new MockOldVault();

        old.setInterest(
            user1,
            12_345
        );

        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user1;

        uint256[] memory amts = new uint256[](2);
        amts[0] = 100 * 1e6;
        amts[1] = 100 * 1e6;

        WiseSovrenNodesDiamond d = new WiseSovrenNodesDiamond(
            _buildParams(
                address(usd),
                thirdPty,
                address(old),
                addrs,
                amts,
                TOTAL_DEPOSIT_CAP,
                INTEREST_RATE
            )
        );

        assertEq(
            d.cashedInterest(user1),
            12_345
        );

        _wireOne(
            d,
            address(new CashedInterestFacet()),
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        assertEq(
            CashedInterestFacet(address(d)).getTotalCashedInterest(),
            12_345
        );
    }

    function test_constructor_noOldVault_totalCashedZero()
        public
    {
        WiseSovrenNodesDiamond d = new WiseSovrenNodesDiamond(
            _buildParams(
                address(usd),
                thirdPty,
                address(0),
                _emptyAddrs(),
                _emptyAmts(),
                TOTAL_DEPOSIT_CAP,
                INTEREST_RATE
            )
        );

        _wireOne(
            d,
            address(new CashedInterestFacet()),
            WiseSovrenNodesDiamondSelectors.cashedInterestSelectors()
        );

        assertEq(
            CashedInterestFacet(address(d)).getTotalCashedInterest(),
            0
        );
    }

    function test_constructor_migrationRevertsOnBadOldVault()
        public
    {
        BadOldVault bad = new BadOldVault();

        address[] memory addrs = new address[](1);
        addrs[0] = user1;

        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(bad),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert();

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_migrationRevertsOnNoCodeOldVault()
        public
    {
        address[] memory addrs = new address[](1);
        addrs[0] = user1;

        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0xDEAD),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.OldVaultNoCode.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_migrationRevertsOnNoCodeOldVault_emptyDistribution()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0xDEAD),
            _emptyAddrs(),
            _emptyAmts(),
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.OldVaultNoCode.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_migrationRevertsOnEmptyReturnOldVault()
        public
    {
        EmptyReturnOldVault empty = new EmptyReturnOldVault();

        address[] memory addrs = new address[](1);
        addrs[0] = user1;

        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(empty),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.OldVaultBadResponse.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnZeroInterestRate()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0),
            _emptyAddrs(),
            _emptyAmts(),
            TOTAL_DEPOSIT_CAP,
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnZeroCap()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0),
            _emptyAddrs(),
            _emptyAmts(),
            0,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnExcessiveInterestRate()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0),
            _emptyAddrs(),
            _emptyAmts(),
            TOTAL_DEPOSIT_CAP,
            20_001
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InterestRateTooHigh.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnInitialMintOverCap()
        public
    {
        address[] memory addrs = new address[](1);
        addrs[0] = user1;

        uint256[] memory amts = new uint256[](1);
        amts[0] = 150 * 1e6;

        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            100 * 1e6,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnZeroUsdAddress()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(0),
            thirdPty,
            address(0),
            _emptyAddrs(),
            _emptyAmts(),
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    function test_constructor_revertsOnZeroThirdParty()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildParams(
            address(usd),
            address(0),
            address(0),
            _emptyAddrs(),
            _emptyAmts(),
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    // ---- Admin: supply-change flag ----

    function test_disAllowSupplyChangeByOwner_setsFlag()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit SupplyChangeByOwnerNotAllowedSet(
            true
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        assertTrue(
            diamond.supplyChangeByOwnerNotAllowed()
        );
    }

    function test_disAllowSupplyChangeByOwner_blocksMint()
        public
    {
        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SupplyChangeNotAllowed.selector
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            100
        );
    }

    function test_disAllowSupplyChangeByOwner_blocksBurn()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            100 * 1e6
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.SupplyChangeNotAllowed.selector
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            1
        );
    }

    function test_disAllowSupplyChangeByOwner_nonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).disAllowSupplyChangeByOwner();
    }

    // ---- Admin: mint / burn supply ----

    function test_mintSupply_master_emits()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit MintSupply(
            user1,
            500 * 1e6
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            500 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            500 * 1e6
        );

        assertEq(
            diamond.lastSyncTimeStamp(user1),
            block.timestamp
        );
    }

    function test_burnSupply_master_emits()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            500 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit BurnSupply(
            user1,
            100 * 1e6
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            100 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            400 * 1e6
        );
    }

    function test_mintSupply_nonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            1
        );
    }

    function test_burnSupply_nonMasterReverts()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            1
        );

        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            1
        );
    }

    // ---- Admin: pause / unpause ----

    function test_pauseDeposits_setsPaused()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        assertTrue(
            diamond.paused()
        );
    }

    function test_unpauseDeposits_clearsPaused()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        AdminFacet(address(diamond)).unpauseDeposits();

        assertFalse(
            diamond.paused()
        );
    }

    function test_pauseDeposits_nonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).pauseDeposits();
    }

    function test_unpauseDeposits_nonMasterReverts()
        public
    {
        AdminFacet(address(diamond)).pauseDeposits();

        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).unpauseDeposits();
    }

    // ---- Admin: third-party address ----

    function test_thirdPartyAddress_proposeStagesWithoutChanging()
        public
    {
        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            user1
        );

        assertEq(
            diamond.proposedThirdPartyAddress(),
            user1
        );

        assertEq(
            diamond.thirdPartyChangeQueuedAt(),
            block.timestamp
        );

        assertEq(
            diamond.thirdPartyAddress(),
            thirdPty
        );
    }

    function test_thirdPartyAddress_executeAfterDelay_setsAndEmits()
        public
    {
        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            user1
        );

        vm.warp(
            block.timestamp + 3 days
        );

        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit ThirdPartyAddressSet(
            user1
        );

        AdminFacet(address(diamond)).executeThirdPartyAddressChange();

        assertEq(
            diamond.thirdPartyAddress(),
            user1
        );

        assertEq(
            diamond.proposedThirdPartyAddress(),
            address(0)
        );

        assertEq(
            diamond.thirdPartyChangeQueuedAt(),
            0
        );
    }

    function test_thirdPartyAddress_executeBeforeDelayReverts()
        public
    {
        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.ThirdPartyTimelockNotElapsed.selector
        );

        AdminFacet(address(diamond)).executeThirdPartyAddressChange();
    }

    function test_thirdPartyAddress_executeWithoutProposalReverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoThirdPartyChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeThirdPartyAddressChange();
    }

    function test_thirdPartyAddress_cancelClearsProposal()
        public
    {
        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            user1
        );

        AdminFacet(address(diamond)).cancelThirdPartyAddressChange();

        assertEq(
            diamond.proposedThirdPartyAddress(),
            address(0)
        );

        assertEq(
            diamond.thirdPartyChangeQueuedAt(),
            0
        );

        assertEq(
            diamond.thirdPartyAddress(),
            thirdPty
        );
    }

    function test_thirdPartyAddress_proposeZeroReverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            address(0)
        );
    }

    function test_thirdPartyAddress_proposeNonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).proposeThirdPartyAddress(
            user1
        );
    }

    // ---- Admin: interest rate (+ buffer ratchet branch) ----

    function test_setInterestRate_lower_emitsOnlyRateSet()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit InterestRateSet(
            INTEREST_RATE / 2
        );

        AdminFacet(address(diamond)).setInterestRate(
            INTEREST_RATE / 2
        );

        assertEq(
            diamond.interestRate(),
            INTEREST_RATE / 2
        );

        assertEq(
            diamond.bufferInterestRate(),
            INTEREST_RATE
        );
    }

    function test_setInterestRate_higher_raisesBuffer()
        public
    {
        uint256 newRate = INTEREST_RATE * 2;

        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit InterestRateSet(
            newRate
        );

        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit BufferInterestRateRaised(
            newRate
        );

        AdminFacet(address(diamond)).setInterestRate(
            newRate
        );

        assertEq(
            diamond.interestRate(),
            newRate
        );

        assertEq(
            diamond.bufferInterestRate(),
            newRate
        );
    }

    function test_setInterestRate_nonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setInterestRate(
            1
        );
    }

    function test_setInterestRate_atMaxSucceeds()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            20_000
        );

        assertEq(
            diamond.interestRate(),
            20_000
        );

        assertEq(
            diamond.bufferInterestRate(),
            20_000
        );
    }

    function test_setInterestRate_aboveMaxReverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InterestRateTooHigh.selector
        );

        AdminFacet(address(diamond)).setInterestRate(
            20_001
        );
    }

    function test_mintSupply_atCapSucceeds()
        public
    {
        AdminFacet(address(diamond)).mintSupply(
            user1,
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            diamond.balanceOf(user1),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            diamond.totalSupply(),
            TOTAL_DEPOSIT_CAP
        );
    }

    function test_mintSupply_aboveCapReverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        AdminFacet(address(diamond)).mintSupply(
            user1,
            TOTAL_DEPOSIT_CAP + 1
        );
    }

    // ---- Admin: total deposit cap ----

    function test_setTotalDepositCap_master_emits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit TotalDepositCapSet(
            9999
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            9999
        );

        assertEq(
            diamond.totalDepositCap(),
            9999
        );
    }

    function test_setTotalDepositCap_belowSupply_reverts()
        public
    {
        uint256 supply = 500 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            supply
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositCapBelowSupply.selector
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            supply - 1
        );
    }

    function test_setTotalDepositCap_equalSupply_succeeds()
        public
    {
        uint256 supply = 500 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            supply
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            supply
        );

        assertEq(
            diamond.totalDepositCap(),
            supply
        );

        assertEq(
            diamond.totalDepositCap() - diamond.totalSupply(),
            0
        );
    }

    function test_burnSupply_freesDepositRoom()
        public
    {
        uint256 freed = 100 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            TOTAL_DEPOSIT_CAP
        );

        usd.mint(
            user1,
            freed
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            freed
        );

        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.DepositExceedCap.selector
        );

        UserFacet(address(diamond)).deposit(
            freed
        );

        AdminFacet(address(diamond)).burnSupply(
            user1,
            freed
        );

        assertEq(
            diamond.totalDepositCap(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            diamond.totalDepositCap() - diamond.totalSupply(),
            freed
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            freed
        );

        assertEq(
            diamond.totalSupply(),
            TOTAL_DEPOSIT_CAP
        );

        assertEq(
            diamond.totalDepositCap() - diamond.totalSupply(),
            0
        );
    }

    function test_setTotalDepositCap_nonMasterReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setTotalDepositCap(
            1
        );
    }

    // ---- Admin: proxy benefactor (proxy-gated) ----

    function test_setProxyBenefactor_proxy_emits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit ProxyBenefactorSet(
            benefactor
        );

        vm.prank(
            proxy
        );

        AdminFacet(address(diamond)).setProxyBenefactor(
            benefactor
        );

        assertEq(
            diamond.currentProxyBenefactor(),
            benefactor
        );
    }

    function test_setProxyBenefactor_nonProxyReverts()
        public
    {
        vm.prank(
            attacker
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotInterestRateProxy.selector
        );

        AdminFacet(address(diamond)).setProxyBenefactor(
            benefactor
        );
    }

    // ---- OwnableMaster (standalone) ----

    function test_ownable_constructor_storesMaster()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        assertEq(
            om.master(),
            address(this)
        );

        assertEq(
            om.proposedMaster(),
            address(0)
        );
    }

    function test_ownable_constructor_zeroReverts()
        public
    {
        vm.expectRevert(
            NoValue.selector
        );

        new OwnableMaster(
            address(0)
        );
    }

    function test_ownable_proposeOwner_master_emits()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        vm.expectEmit(
            true,
            true,
            false,
            true
        );

        emit MasterProposed(
            address(this),
            user1
        );

        om.proposeOwner(
            user1
        );

        assertEq(
            om.proposedMaster(),
            user1
        );
    }

    function test_ownable_proposeOwner_zeroReverts()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        vm.expectRevert(
            NoValue.selector
        );

        om.proposeOwner(
            address(0)
        );
    }

    function test_ownable_proposeOwner_nonMasterReverts()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        om.proposeOwner(
            user1
        );
    }

    function test_ownable_claimOwnership_proposedClaims()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        om.proposeOwner(
            user1
        );

        vm.prank(
            user1
        );

        om.claimOwnership();

        assertEq(
            om.master(),
            user1
        );
    }

    function test_ownable_claimOwnership_nonProposedReverts()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        om.proposeOwner(
            user1
        );

        vm.prank(
            user2
        );

        vm.expectRevert(
            NotProposed.selector
        );

        om.claimOwnership();
    }

    function test_ownable_renounceOwnership_master_clearsAll()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        om.proposeOwner(
            user1
        );

        vm.expectEmit(
            true,
            false,
            false,
            true
        );

        emit RenouncedOwnership(
            address(this)
        );

        om.renounceOwnership();

        assertEq(
            om.master(),
            address(0)
        );

        assertEq(
            om.proposedMaster(),
            address(0)
        );
    }

    function test_ownable_renounceOwnership_nonMasterReverts()
        public
    {
        OwnableMaster om = new OwnableMaster(
            address(this)
        );

        vm.prank(
            attacker
        );

        vm.expectRevert(
            NotMaster.selector
        );

        om.renounceOwnership();
    }
}
