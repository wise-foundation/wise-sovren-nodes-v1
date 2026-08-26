// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DiamondTestHarness} from "../utils/DiamondTestHarness.sol";

import {WiseSovrenNodesDiamond} from "../../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../../src/diamond/vault/facets/ProxyFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../../src/diamond/vault/facets/CashedInterestFacet.sol";

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
 * @dev Stateful-invariant driver for the WiseSovrenNodes diamond. Every
 * action routes through the real facets (fallback + DELEGATECALL) so the
 * production dispatch path is exercised, not a shortcut. The handler
 * deliberately includes the moves most likely to leak interest onto the
 * contract itself - transferring vault tokens to it, minting supply to
 * it, attributing proxy balance to it, naming it as its own benefactor
 * and then triggering assignment - so the fuzzer actively tries to break
 * the {InterestInvariantTest} invariant.
 */
contract InterestInvariantHandler is Test {

    WiseSovrenNodesDiamond internal immutable diamond;
    MockUSD internal immutable usd;
    address internal immutable master;
    address internal immutable contractAddr;

    address[3] internal actors;

    uint256 public moveSumDrift;

    uint256 public sweepReserveViolations;

    uint256 internal constant MAX_AMOUNT = 1_000_000 * 1e6;
    uint256 internal constant MAX_WARP = 400 days;
    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant SECONDS_IN_TWO_WEEKS = 14 days;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant PRECISION_FACTOR_E18 = 1e18;

    constructor(
        WiseSovrenNodesDiamond _diamond,
        MockUSD _usd,
        address _master,
        address[3] memory _actors
    ) {
        diamond = _diamond;
        usd = _usd;
        master = _master;
        contractAddr = address(_diamond);
        actors = _actors;
    }

    function _actor(
        uint256 _seed
    )
        internal
        view
        returns (address)
    {
        return actors[_seed % actors.length];
    }

    function depositFor(
        uint256 _seed,
        uint256 _amount
    )
        public
    {
        address actor = _actor(
            _seed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            actor
        );

        try UserFacet(address(diamond)).deposit(_amount) {} catch {}
    }

    function claimFor(
        uint256 _seed
    )
        public
    {
        address actor = _actor(
            _seed
        );

        vm.prank(
            actor
        );

        try UserFacet(address(diamond)).claimInterest() {} catch {}
    }

    function claimExactFor(
        uint256 _seed,
        uint256 _amount
    )
        public
    {
        address actor = _actor(
            _seed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            actor
        );

        try UserFacet(address(diamond)).claimInterestExactAmount(_amount) {} catch {}
    }

    function compoundFor(
        uint256 _seed
    )
        public
    {
        address actor = _actor(
            _seed
        );

        vm.prank(
            actor
        );

        try UserFacet(address(diamond)).compoundInterest() {} catch {}
    }

    function claimPartialAndCompoundFor(
        uint256 _seed,
        uint256 _amount
    )
        public
    {
        address actor = _actor(
            _seed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            actor
        );

        try UserFacet(address(diamond)).claimInterestPartiallyAndCompound(_amount) {} catch {}
    }

    /**
     * @dev BUF-3 probe: top the vault up (the worker refill a
     * sweeper races against), sweep as the granted sweeper, and
     * verify a successful sweep leaves the balance at exactly the
     * needed reserve - the two-week forward buffer plus the settled
     * `totalCashedInterest` liability. Deviations accumulate in a
     * ghost because handler reverts are swallowed by the runner.
     */
    function sweep(
        uint256 _topUp
    )
        public
    {
        _topUp = bound(
            _topUp,
            0,
            MAX_AMOUNT
        );

        usd.mint(
            contractAddr,
            _topUp
        );

        try SweepFacet(address(diamond)).sweepOverhang() {

            uint256 reserve = _neededReserve();

            if (usd.balanceOf(contractAddr) != reserve) {
                sweepReserveViolations += 1;
            }
        } catch {}
    }

    function _neededReserve()
        internal
        view
        returns (uint256)
    {
        uint256 liability = CashedInterestFacet(address(diamond)).getTotalCashedInterest();

        uint256 principal = diamond.totalSupply();

        if (principal == 0) {
            return liability;
        }

        uint256 yearFactor = SECONDS_IN_TWO_WEEKS
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        uint256 forwardInterest = principal
            * diamond.bufferInterestRate()
            * yearFactor
            / PRECISION_RATE
            / PRECISION_FACTOR_E18;

        return forwardInterest
            + liability;
    }

    function transferBetween(
        uint256 _fromSeed,
        uint256 _toSeed,
        uint256 _amount
    )
        public
    {
        address from = _actor(
            _fromSeed
        );

        address to = _actor(
            _toSeed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            from
        );

        try diamond.transfer(to, _amount) {} catch {}
    }

    /**
     * @dev Adversarial: push vault tokens onto the contract address.
     */
    function transferToContract(
        uint256 _seed,
        uint256 _amount
    )
        public
    {
        address actor = _actor(
            _seed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            actor
        );

        try diamond.transfer(contractAddr, _amount) {} catch {}
    }

    /**
     * @dev Adversarial: mint vault supply directly onto the contract.
     */
    function mintSupplyToContract(
        uint256 _amount
    )
        public
    {
        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            master
        );

        try AdminFacet(address(diamond)).mintSupply(contractAddr, _amount) {} catch {}
    }

    /**
     * @dev Adversarial: attribute proxy balance to the contract.
     */
    function increaseProxyBalanceOfContract(
        uint256 _amount
    )
        public
    {
        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        vm.prank(
            contractAddr
        );

        try ProxyFacet(address(diamond)).increaseProxyBalance(contractAddr, _amount) {} catch {}
    }

    /**
     * @dev Adversarial: name the contract its own benefactor, then run
     * the proxy assignment path against it.
     */
    function makeContractItsOwnBenefactorAndAssign()
        public
    {
        vm.prank(
            contractAddr
        );

        try AdminFacet(address(diamond)).setProxyBenefactor(contractAddr) {} catch {}

        vm.prank(
            contractAddr
        );

        try ProxyFacet(address(diamond)).triggerAssignInterest(contractAddr) {} catch {}
    }

    function setBenefactor(
        uint256 _seed
    )
        public
    {
        address actor = _actor(
            _seed
        );

        vm.prank(
            contractAddr
        );

        try AdminFacet(address(diamond)).setProxyBenefactor(actor) {} catch {}
    }

    /**
     * @dev INT-1 probe: route `moveMyInterestTo` through the real
     * facet and accumulate any deviation of the total cashed-interest
     * ledger from its expected value. The `assignInterest` modifiers
     * legitimately bank the pending interest of sender and target, so
     * the expectation nets that accrual out; the move itself must be
     * exactly conservative. Deviations are accumulated in a ghost
     * (`moveSumDrift`) instead of asserted here because handler
     * reverts are swallowed by the invariant runner.
     */
    function moveInterestFor(
        uint256 _fromSeed,
        uint256 _toSeed,
        uint256 _amount,
        bool _all
    )
        public
    {
        address from = _actor(
            _fromSeed
        );

        address to = _actor(
            _toSeed
        );

        _amount = bound(
            _amount,
            1,
            MAX_AMOUNT
        );

        uint256 sumBefore = _sumCashed();

        uint256 pendingAdd = from == to
            ? diamond.getPendingInterest(from)
            : diamond.getPendingInterest(from) + diamond.getPendingInterest(to);

        uint256 expected = sumBefore;

        vm.prank(
            from
        );

        try UserFacet(address(diamond)).moveMyInterestTo(_amount, to, _all) {
            expected = sumBefore + pendingAdd;
        } catch {}

        uint256 sumAfter = _sumCashed();

        moveSumDrift += sumAfter > expected
            ? sumAfter - expected
            : expected - sumAfter;
    }

    function _sumCashed()
        internal
        view
        returns (uint256 sum)
    {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += diamond.cashedInterest(
                actors[i]
            );
        }

        sum += diamond.cashedInterest(
            contractAddr
        );
    }

    function sumCashed()
        public
        view
        returns (uint256)
    {
        return _sumCashed();
    }

    function setRate(
        uint256 _rate
    )
        public
    {
        _rate = bound(
            _rate,
            1,
            5_000
        );

        vm.prank(
            master
        );

        try AdminFacet(address(diamond)).setInterestRate(_rate) {} catch {}
    }

    function warp(
        uint256 _seconds
    )
        public
    {
        _seconds = bound(
            _seconds,
            1,
            MAX_WARP
        );

        vm.warp(
            block.timestamp + _seconds
        );
    }
}

/**
 * @title InterestInvariantTest
 * @dev Foundry stateful-invariant complement to the Kontrol proofs. It
 * fuzzes long random sequences of real diamond operations and asserts,
 * after every call, that the contract (== InterestRateProxy) holds zero
 * cashed interest and zero pending interest.
 */
contract InterestInvariantTest is DiamondTestHarness {

    MockUSD internal usd;
    WiseSovrenNodesDiamond internal diamond;
    InterestInvariantHandler internal handler;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal user3 = address(0xA3);

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

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );


        address[3] memory actors = [
            user1,
            user2,
            user3
        ];

        for (uint256 i = 0; i < actors.length; i++) {
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

        handler = new InterestInvariantHandler(
            diamond,
            usd,
            address(this),
            actors
        );

        AdminFacet(address(diamond)).setSweeper(
            address(handler),
            true
        );

        targetContract(
            address(handler)
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    function invariant_ContractNeverAccruesCashedInterest()
        public
        view
    {
        assertEq(
            diamond.cashedInterest(address(diamond)),
            0,
            "contract accrued cashed interest"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    function invariant_ContractNeverHasPendingInterest()
        public
        view
    {
        assertEq(
            diamond.getPendingInterest(address(diamond)),
            0,
            "contract has pending interest"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    function invariant_INT1_moveNeverChangesCashedSum()
        public
        view
    {
        assertEq(
            handler.moveSumDrift(),
            0,
            "moveMyInterestTo changed the total cashed-interest ledger"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    function invariant_INT7_totalCashedEqualsLedgerSum()
        public
        view
    {
        assertEq(
            CashedInterestFacet(address(diamond)).getTotalCashedInterest(),
            handler.sumCashed(),
            "totalCashedInterest drifted from the sum of cashedInterest"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    function invariant_BUF3_sweepNeverTakesReservedLiability()
        public
        view
    {
        assertEq(
            handler.sweepReserveViolations(),
            0,
            "sweepOverhang left less than the reserved liability"
        );
    }
}
