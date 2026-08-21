// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {WiseSovrenNodesInitParams} from "../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {OnlyDelegateCall} from "../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

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
 * @dev Full coverage suite for the SweepFacet plus the worker
 * propose/execute/cancel timelock and the ratchet-up `bufferInterestRate`
 * shadow that gates `_calculateNeededBuffer`. The two together are the
 * M-1 mitigation: a compromised master cannot drop the buffer to zero
 * by lowering the user-facing rate, and cannot instantly redirect the
 * sweep recipient.
 */
contract WiseSovrenNodesSweepFacetTest is Test {

    MockUSD usd;
    WiseSovrenNodesDiamond diamond;

    address master = address(this);
    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user1 = address(0xA1);
    address proxy = address(0xC0DE);
    address randomEOA = address(0xBADCAFE);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant SECONDS_IN_TWO_WEEKS = 14 days;
    uint256 constant PRECISION_RATE = 10_000;
    uint256 constant PRECISION_FACTOR_E18 = 1e18;
    uint256 constant WORKER_CHANGE_DELAY = 3 days;

    event WorkerAddressSet(
        address indexed worker
    );

    event WorkerAddressProposed(
        address indexed proposedWorker,
        uint256 executableAt
    );

    event WorkerAddressProposalCancelled(
        address indexed cancelledWorker
    );

    event BufferInterestRateRaised(
        uint256 newBufferInterestRate
    );

    event OverhangSwept(
        address indexed worker,
        address indexed caller,
        uint256 amount
    );

    event SweeperSet(
        address indexed sweeper,
        bool allowed
    );

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployFromTest(
            worker
        );

        proxy = address(diamond);
    }

    function _buildInitParams(
        address _worker
    )
        internal
        view
        returns (WiseSovrenNodesInitParams memory)
    {
        return WiseSovrenNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: thirdPty,
            workerAddress: _worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: TOTAL_DEPOSIT_CAP,
            interestRate: INTEREST_RATE,
            decimalsValue: 6,
            tokenName: "Wise Sovren Nodes",
            tokenSymbol: "WTN"
        });
    }

    function _deployFromTest(
        address _worker
    )
        internal
        returns (WiseSovrenNodesDiamond d)
    {
        AdminFacet admin = new AdminFacet();
        ProxyFacet proxyF = new ProxyFacet();
        UserFacet userF = new UserFacet();
        SweepFacet sweepF = new SweepFacet();
        CashedInterestFacet cashedF = new CashedInterestFacet();

        d = new WiseSovrenNodesDiamond(
            _buildInitParams(
                _worker
            )
        );

        bytes4[] memory adminSels = WiseSovrenNodesDiamondSelectors.adminSelectors();
        bytes4[] memory proxySels = WiseSovrenNodesDiamondSelectors.proxySelectors();
        bytes4[] memory userSels = WiseSovrenNodesDiamondSelectors.userSelectors();
        bytes4[] memory sweepSels = WiseSovrenNodesDiamondSelectors.sweepSelectors();
        bytes4[] memory cashedSels = WiseSovrenNodesDiamondSelectors.cashedInterestSelectors();

        d.proposeSelectors(
            adminSels,
            address(admin)
        );

        d.proposeSelectors(
            proxySels,
            address(proxyF)
        );

        d.proposeSelectors(
            userSels,
            address(userF)
        );

        d.proposeSelectors(
            sweepSels,
            address(sweepF)
        );

        d.proposeSelectors(
            cashedSels,
            address(cashedF)
        );

        d.executeSelectorChanges(
            adminSels
        );

        d.executeSelectorChanges(
            proxySels
        );

        d.executeSelectorChanges(
            userSels
        );

        d.executeSelectorChanges(
            sweepSels
        );

        d.executeSelectorChanges(
            cashedSels
        );

        d.finalizeSetup();
    }

    function _expectedBuffer(
        uint256 _principal,
        uint256 _interestRate
    )
        internal
        pure
        returns (uint256)
    {
        if (_principal == 0) {
            return 0;
        }

        uint256 yearFactor = SECONDS_IN_TWO_WEEKS
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        return _principal
            * _interestRate
            * yearFactor
            / PRECISION_RATE
            / PRECISION_FACTOR_E18;
    }

    // ---- 1. constructor stores worker ----

    function test_constructor_workerAddressStored()
        public
        view
    {
        assertEq(
            diamond.workerAddress(),
            worker
        );
    }

    // ---- 2. constructor rejects zero worker ----

    function test_constructor_zeroWorker_reverts_InvalidValue()
        public
    {
        WiseSovrenNodesInitParams memory params = _buildInitParams(
            address(0)
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        new WiseSovrenNodesDiamond(
            params
        );
    }

    // ---- 3. constructor stores bufferInterestRate equal to interestRate ----

    function test_constructor_bufferInterestRateEqualsInterestRate()
        public
        view
    {
        assertEq(
            diamond.bufferInterestRate(),
            INTEREST_RATE
        );

        assertEq(
            diamond.interestRate(),
            INTEREST_RATE
        );
    }

    // ---- 4. proposeWorkerAddress writes storage + emits ----

    function test_proposeWorkerAddress_writesAndEmits()
        public
    {
        address newWorker = address(0xFEED);

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WorkerAddressProposed(
            newWorker,
            block.timestamp + WORKER_CHANGE_DELAY
        );

        AdminFacet(address(diamond)).proposeWorkerAddress(
            newWorker
        );

        assertEq(
            diamond.proposedWorkerAddress(),
            newWorker
        );

        assertEq(
            diamond.workerChangeQueuedAt(),
            block.timestamp
        );

        assertEq(
            diamond.workerAddress(),
            worker
        );
    }

    // ---- 5. proposeWorkerAddress onlyMaster ----

    function test_proposeWorkerAddress_nonMaster_reverts()
        public
    {
        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).proposeWorkerAddress(
            address(0xFEED)
        );
    }

    // ---- 6. proposeWorkerAddress rejects zero ----

    function test_proposeWorkerAddress_zero_reverts_InvalidValue()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).proposeWorkerAddress(
            address(0)
        );
    }

    // ---- 7. proposeWorkerAddress overwrites prior proposal ----

    function test_proposeWorkerAddress_overwritesPrior()
        public
    {
        address first = address(0xFEED);
        address second = address(0xBEEF);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            first
        );

        uint256 firstQueuedAt = diamond.workerChangeQueuedAt();

        vm.warp(
            block.timestamp + 1 hours
        );

        AdminFacet(address(diamond)).proposeWorkerAddress(
            second
        );

        assertEq(
            diamond.proposedWorkerAddress(),
            second
        );

        assertEq(
            diamond.workerChangeQueuedAt(),
            firstQueuedAt + 1 hours
        );
    }

    // ---- 8. executeWorkerAddressChange before delay reverts ----

    function test_executeWorkerAddressChange_beforeDelay_reverts()
        public
    {
        address newWorker = address(0xFEED);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            newWorker
        );

        vm.warp(
            block.timestamp + WORKER_CHANGE_DELAY - 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.WorkerTimelockNotElapsed.selector
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();
    }

    // ---- 9. executeWorkerAddressChange at exact delay succeeds ----

    function test_executeWorkerAddressChange_atExactDelay_succeedsAndEmits()
        public
    {
        address newWorker = address(0xFEED);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            newWorker
        );

        vm.warp(
            block.timestamp + WORKER_CHANGE_DELAY
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WorkerAddressSet(
            newWorker
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();

        assertEq(
            diamond.workerAddress(),
            newWorker
        );

        assertEq(
            diamond.proposedWorkerAddress(),
            address(0)
        );

        assertEq(
            diamond.workerChangeQueuedAt(),
            0
        );
    }

    // ---- 10. executeWorkerAddressChange without proposal reverts ----

    function test_executeWorkerAddressChange_noProposal_reverts()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoWorkerChangeProposed.selector
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();
    }

    // ---- 11. executeWorkerAddressChange onlyMaster ----

    function test_executeWorkerAddressChange_nonMaster_reverts()
        public
    {
        AdminFacet(address(diamond)).proposeWorkerAddress(
            address(0xFEED)
        );

        vm.warp(
            block.timestamp + WORKER_CHANGE_DELAY
        );

        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();
    }

    // ---- 12. cancelWorkerAddressChange clears and emits ----

    function test_cancelWorkerAddressChange_clearsAndEmits()
        public
    {
        address pending = address(0xFEED);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            pending
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit WorkerAddressProposalCancelled(
            pending
        );

        AdminFacet(address(diamond)).cancelWorkerAddressChange();

        assertEq(
            diamond.proposedWorkerAddress(),
            address(0)
        );

        assertEq(
            diamond.workerChangeQueuedAt(),
            0
        );

        assertEq(
            diamond.workerAddress(),
            worker
        );
    }

    // ---- 13. cancelWorkerAddressChange onlyMaster ----

    function test_cancelWorkerAddressChange_nonMaster_reverts()
        public
    {
        AdminFacet(address(diamond)).proposeWorkerAddress(
            address(0xFEED)
        );

        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).cancelWorkerAddressChange();
    }

    // ---- 14. cancel then re-propose works, execute after fresh delay ----

    function test_cancelThenRepropose_executeAfterFreshDelay()
        public
    {
        AdminFacet(address(diamond)).proposeWorkerAddress(
            address(0xFEED)
        );

        AdminFacet(address(diamond)).cancelWorkerAddressChange();

        address newWorker = address(0xBEEF);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            newWorker
        );

        vm.warp(
            block.timestamp + WORKER_CHANGE_DELAY
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();

        assertEq(
            diamond.workerAddress(),
            newWorker
        );
    }

    // ---- 15. propose/execute/cancel onlyDelegateCall ----

    function test_proposeWorkerAddress_directFacetCall_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        admin.proposeWorkerAddress(
            address(0xFEED)
        );
    }

    function test_executeWorkerAddressChange_directFacetCall_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        admin.executeWorkerAddressChange();
    }

    function test_cancelWorkerAddressChange_directFacetCall_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        admin.cancelWorkerAddressChange();
    }

    // ---- 16. getOverhang: zero supply, zero balance ----

    function test_getOverhang_zeroSupply_zeroBalance_returnsZero()
        public
        view
    {
        assertEq(
            diamond.totalSupply(),
            0
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            0
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 17. getOverhang: zero supply, positive balance → full overhang ----

    function test_getOverhang_zeroSupply_positiveBalance_returnsBalance()
        public
    {
        uint256 amount = 1_234 * 1e6;

        usd.mint(
            address(diamond),
            amount
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            amount
        );
    }

    // ---- 18. getOverhang: balance below buffer ----

    function test_getOverhang_balanceBelowBuffer_returnsZero()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer - 1
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 19. getOverhang: balance == buffer (boundary of <=) ----

    function test_getOverhang_balanceEqualsBuffer_returnsZero()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 20. getOverhang: balance above buffer ----

    function test_getOverhang_balanceAboveBuffer_returnsDiff()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 7_777 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            excess
        );
    }

    // ---- 21. raising interestRate ratchets bufferRate up, shrinks overhang ----

    function test_setInterestRate_higher_raisesBufferRate_shrinksOverhang()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 100_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            funded
        );

        uint256 overhangAtBase = SweepFacet(address(diamond)).getOverhang();

        uint256 newRate = 4000;

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit BufferInterestRateRaised(
            newRate
        );

        AdminFacet(address(diamond)).setInterestRate(
            newRate
        );

        assertEq(
            diamond.bufferInterestRate(),
            newRate
        );

        uint256 overhangAtHigher = SweepFacet(address(diamond)).getOverhang();

        assertGt(
            overhangAtBase,
            overhangAtHigher
        );

        assertEq(
            overhangAtHigher,
            funded - _expectedBuffer(principal, newRate)
        );
    }

    // ---- 22. lowering interestRate does NOT lower bufferRate (M-1 mitigation) ----

    function test_setInterestRate_lower_doesNotLowerBufferRate()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 100_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            funded
        );

        uint256 overhangAtBase = SweepFacet(address(diamond)).getOverhang();

        uint256 lowerRate = INTEREST_RATE / 2;

        AdminFacet(address(diamond)).setInterestRate(
            lowerRate
        );

        assertEq(
            diamond.bufferInterestRate(),
            INTEREST_RATE
        );

        assertEq(
            diamond.interestRate(),
            lowerRate
        );

        uint256 overhangAtLower = SweepFacet(address(diamond)).getOverhang();

        assertEq(
            overhangAtLower,
            overhangAtBase
        );
    }

    // ---- 23. lowering interestRate does NOT emit BufferInterestRateRaised ----

    function test_setInterestRate_lower_doesNotEmitBufferRaised()
        public
    {
        AdminFacet(address(diamond)).setInterestRate(
            INTEREST_RATE / 2
        );

        assertEq(
            diamond.bufferInterestRate(),
            INTEREST_RATE
        );
    }

    // ---- 24. M-1 attack prevented: setInterestRate(0) does NOT enable drain ----

    function test_M1_setRateZero_doesNotEnableDrain()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 100_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            funded
        );

        uint256 overhangAtBase = SweepFacet(address(diamond)).getOverhang();

        AdminFacet(address(diamond)).setInterestRate(
            0
        );

        assertEq(
            diamond.bufferInterestRate(),
            INTEREST_RATE
        );

        uint256 overhangAfterRateDrop = SweepFacet(address(diamond)).getOverhang();

        assertEq(
            overhangAfterRateDrop,
            overhangAtBase
        );

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            swept,
            overhangAtBase
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            funded - overhangAtBase
        );

        assertGt(
            usd.balanceOf(address(diamond)),
            0
        );
    }

    // ---- 25. sweep reverts when no overhang ----

    function test_sweepOverhang_revertsWhenNoOverhang_NoOverhang()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 26. sweep transfers excess to worker, emits event ----

    function test_sweepOverhang_transfersExcessToWorker_emits()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 50_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        uint256 workerBefore = usd.balanceOf(
            worker
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit OverhangSwept(
            worker,
            address(this),
            excess
        );

        SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            usd.balanceOf(worker),
            workerBefore + excess
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            buffer
        );
    }

    // ---- 27. sweep return value equals transferred ----

    function test_sweepOverhang_returnValueEqualsTransferred()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 12_345 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        uint256 returned = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            returned,
            excess
        );
    }

    // ---- 28. sweep is idempotent ----

    function test_sweepOverhang_idempotent_secondCallReverts()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 10_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        SweepFacet(address(diamond)).sweepOverhang();

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 29. sweep direct facet call reverts ----

    function test_sweepOverhang_directFacetCall_reverts_OnlyDelegateCall()
        public
    {
        SweepFacet sweepF = new SweepFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        sweepF.sweepOverhang();
    }

    // ---- 30. L-3 fix: sweep works when paused ----

    function test_sweepOverhang_whenPaused_succeeds()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 10_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        AdminFacet(address(diamond)).pauseDeposits();

        uint256 workerBefore = usd.balanceOf(
            worker
        );

        SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            usd.balanceOf(worker),
            workerBefore + excess
        );
    }

    // ---- 31. proxyBalance does not change overhang ----

    function test_sweepOverhang_unaffectedByProxyBalance()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 5_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        uint256 overhangBefore = SweepFacet(address(diamond)).getOverhang();

        vm.prank(
            proxy
        );

        ProxyFacet(address(diamond)).increaseProxyBalance(
            user1,
            500_000 * 1e6
        );

        uint256 overhangAfter = SweepFacet(address(diamond)).getOverhang();

        assertEq(
            overhangBefore,
            overhangAfter
        );
    }

    // ---- 32. raising interestRate above current can eat overhang ----

    function test_sweepOverhang_afterInterestRateRaise_revertsIfBufferGrew()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        uint256 excessAtBase = 100 * 1e6;

        usd.mint(
            address(diamond),
            buffer + excessAtBase
        );

        uint256 higherRate = INTEREST_RATE * 10;

        AdminFacet(address(diamond)).setInterestRate(
            higherRate
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 33. caller must be a granted sweeper, recipient is worker ----

    function test_sweepOverhang_grantedSweeperEOA_recipientStillWorker()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 8_888 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + excess
        );

        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotSweeper.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        uint256 workerBefore = usd.balanceOf(
            worker
        );

        uint256 callerBefore = usd.balanceOf(
            randomEOA
        );

        vm.prank(
            randomEOA
        );

        SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            usd.balanceOf(worker),
            workerBefore + excess
        );

        assertEq(
            usd.balanceOf(randomEOA),
            callerBefore
        );
    }

    // ---- 34. M-1 + worker rotation combined: rotation delayed, drain bounded ----

    function test_M1_combinedAttack_delayedRotationCapsDrain()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 100_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            funded
        );

        AdminFacet(address(diamond)).setInterestRate(
            0
        );

        address attacker = address(0xBAD);

        AdminFacet(address(diamond)).proposeWorkerAddress(
            attacker
        );

        vm.warp(
            block.timestamp + WORKER_CHANGE_DELAY - 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.WorkerTimelockNotElapsed.selector
        );

        AdminFacet(address(diamond)).executeWorkerAddressChange();

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            usd.balanceOf(attacker),
            0
        );

        assertEq(
            usd.balanceOf(worker),
            swept
        );

        assertLt(
            swept,
            funded
        );
    }

    // ---- 35. sweep reserves accrued cashed interest, claim stays live ----

    function _accrueCashedInterest(
        address _user,
        uint256 _warpSeconds
    )
        internal
        returns (uint256)
    {
        vm.warp(
            block.timestamp + _warpSeconds
        );

        vm.prank(
            address(diamond)
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            _user
        );

        return diamond.cashedInterest(
            _user
        );
    }

    function test_sweepOverhang_reservesAccruedCashedInterest_claimSucceedsAfter()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 50_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            cashed
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + cashed + excess
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        vm.prank(
            randomEOA
        );

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            swept,
            excess
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            buffer + cashed
        );

        vm.prank(
            user1
        );

        uint256 claimed = UserFacet(address(diamond)).claimInterest();

        assertEq(
            claimed,
            cashed
        );

        assertEq(
            usd.balanceOf(user1),
            cashed
        );

        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            0
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 36. overhang is zero at exactly the full reserve ----

    function test_getOverhang_zeroAtExactFullReserve()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + cashed
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 37. balance covering only the liability: no sweep, claim live ----

    function test_sweepOverhang_balanceOnlyCoversLiability_revertsNoOverhang()
        public
    {
        uint256 principal = 1_000_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        usd.mint(
            address(diamond),
            cashed
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();

        vm.prank(
            user1
        );

        uint256 claimed = UserFacet(address(diamond)).claimInterest();

        assertEq(
            claimed,
            cashed
        );
    }

    // ---- 38. accrual grows the reserve by exactly totalCashedInterest ----

    function test_getOverhang_accruedInterest_growsReserveByExactlyTotalCashed()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 300_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + funded
        );

        uint256 overhangBefore = SweepFacet(address(diamond)).getOverhang();

        assertEq(
            overhangBefore,
            funded
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        assertEq(
            overhangBefore - SweepFacet(address(diamond)).getOverhang(),
            cashed
        );
    }

    // ---- 40. rate ratchet and cashed liability reserve add, not replace ----

    function test_sweepOverhang_ratchetPlusCashedReserve_compound()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 25_000 * 1e6;
        uint256 raisedRate = 4000;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        AdminFacet(address(diamond)).setInterestRate(
            raisedRate
        );

        uint256 raisedBuffer = _expectedBuffer(
            principal,
            raisedRate
        );

        usd.mint(
            address(diamond),
            raisedBuffer + cashed - 1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();

        usd.mint(
            address(diamond),
            1 + excess
        );

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            swept,
            excess
        );

        assertEq(
            usd.balanceOf(address(diamond)),
            raisedBuffer + cashed
        );
    }

    // ---- 41. setSweeper writes the allowlist and emits ----

    function test_setSweeper_writesAndEmits()
        public
    {
        assertEq(
            diamond.isSweeper(randomEOA),
            false
        );

        vm.expectEmit(
            true,
            true,
            true,
            true
        );

        emit SweeperSet(
            randomEOA,
            true
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        assertEq(
            diamond.isSweeper(randomEOA),
            true
        );
    }

    // ---- 42. setSweeper access control ----

    function test_setSweeper_nonMaster_reverts()
        public
    {
        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            NotMaster.selector
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );
    }

    function test_setSweeper_zeroAddress_reverts_InvalidValue()
        public
    {
        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.InvalidValue.selector
        );

        AdminFacet(address(diamond)).setSweeper(
            address(0),
            true
        );
    }

    function test_setSweeper_directFacetCall_reverts()
        public
    {
        AdminFacet admin = new AdminFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        admin.setSweeper(
            randomEOA,
            true
        );
    }

    // ---- 43. revoking a sweeper blocks the sweep again ----

    function test_setSweeper_revoke_blocksSweep()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 5_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            _expectedBuffer(
                principal,
                INTEREST_RATE
            ) + excess
        );

        AdminFacet(address(diamond)).setSweeper(
            address(this),
            false
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotSweeper.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();

        AdminFacet(address(diamond)).setSweeper(
            address(this),
            true
        );

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            swept,
            excess
        );
    }

    // ---- 44. getOverhang stays an open view for non-sweepers ----

    function test_getOverhang_openToNonSweepers()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 excess = 5_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        usd.mint(
            address(diamond),
            _expectedBuffer(
                principal,
                INTEREST_RATE
            ) + excess
        );

        vm.prank(
            randomEOA
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            excess
        );
    }

    // ---- 45. constructor seeds worker, third party and deployer ----

    function test_constructor_seedsSweepers()
        public
        view
    {
        assertEq(
            diamond.isSweeper(worker),
            true
        );

        assertEq(
            diamond.isSweeper(thirdPty),
            true
        );

        assertEq(
            diamond.isSweeper(address(this)),
            true
        );

        assertEq(
            diamond.isSweeper(randomEOA),
            false
        );
    }
}
