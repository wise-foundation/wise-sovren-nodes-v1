// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {InterestProofHarness} from "./InterestProofHarness.sol";
import {WiseSovrenNodesInitParams} from "../../../src/diamond/vault/WiseSovrenNodesDiamondStructs.sol";

/**
 * @title InterestPropertiesTest
 * @dev Dual-engine property suite for the WiseSovrenNodes interest math.
 *
 * Every `testFuzz_*` here is written so it can be (a) fuzzed by Foundry
 * (`forge test`) and (b) symbolically proven by Kontrol
 * (`kontrol prove --match-test 'InterestPropertiesTest.<fn>'`). Inputs
 * are plain function parameters — concrete random samples under Foundry,
 * fully symbolic variables under Kontrol — and postconditions use raw
 * Solidity `assert` (Panic 0x01) so Kontrol detects any violating branch
 * unambiguously.
 *
 * Two headline guarantees are targeted:
 *
 *   1. The contract itself (== InterestRateProxy == address(this)) never
 *      accumulates interest, in any storage state.
 *
 *   2. With the rate configured to 20% (2000 / 10000), no single user
 *      accrues more than 20% of their interest base within a one-year
 *      accrual window.
 *
 * The `*_Boundary*` tests are the adversarial half: they pin down the
 * exact conditions under which a naively-stated version of the 20% claim
 * is false (more than one year elapsed; ignoring proxyBalance), proving
 * the guarantee is per-annum and computed on balanceOf + proxyBalance.
 */
contract InterestPropertiesTest is Test {

    InterestProofHarness internal vault;

    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;
    uint256 internal constant PRECISION_RATE = 10_000;
    uint256 internal constant RATE_20_PCT = 2_000;

    uint256 internal constant MAX_BASE = 1e40;

    address internal constant USER = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);

    uint256 internal constant T0 = 1_700_000_000;

    address internal contractAddr;

    function setUp()
        public
    {
        vm.warp(
            T0
        );

        vault = new InterestProofHarness(
            _params()
        );

        contractAddr = address(vault);
    }

    function _params()
        internal
        pure
        returns (WiseSovrenNodesInitParams memory params)
    {
        params.usdAddress = address(0xD15C);
        params.thirdPartyAddress = address(0x7777);
        params.workerAddress = address(0xD00D);
        params.oldVault = address(0);
        params.initialDistributionAddresses = new address[](0);
        params.initialDistributionAmounts = new uint256[](0);
        params.totalDepositCap = 1e30;
        params.interestRate = RATE_20_PCT;
        params.decimalsValue = 6;
        params.tokenName = "Wise Sovren Nodes";
        params.tokenSymbol = "WTN";
    }

    // ---- PROPERTY 1: the contract never accumulates interest ----

    /**
     * @dev No matter how many vault tokens the contract holds, how much
     * proxy balance is attributed to it, how long since its last sync,
     * or what the configured rate is, the contract's pending interest is
     * always exactly zero. This is the `_user == InterestRateProxy` guard
     * in {getPendingInterestByTimeStamp}, proven over all of that state.
     */
    function testFuzz_ContractPendingInterestAlwaysZero(
        uint256 _balance,
        uint256 _proxyBal,
        uint256 _lastSync,
        uint256 _timestamp,
        uint256 _rate
    )
        public
    {
        vault.harnessMint(
            contractAddr,
            _balance
        );

        vault.harnessSetProxyBalance(
            contractAddr,
            _proxyBal
        );

        vault.harnessSetLastSync(
            contractAddr,
            _lastSync
        );

        vault.harnessSetInterestRate(
            _rate
        );

        assert(
            vault.getPendingInterestByTimeStamp(contractAddr, _timestamp) == 0
        );

        assert(
            vault.getPendingInterest(contractAddr) == 0
        );
    }

    /**
     * @dev Running the production proxy accrual path
     * (`_assignInterest(InterestRateProxy)`, reached on every deposit /
     * transfer / claim and from `triggerAssignInterest`) never increases
     * the contract's cashed interest. This pins the most dangerous
     * configuration — the contract named as its OWN benefactor, so the
     * redirect points straight back at it — and proves cashed interest is
     * untouched for any balance, proxy balance, rate and pre-existing
     * cashed amount. (A benefactor other than the contract writes to that
     * other account's cashed slot, never the contract's, by construction;
     * the {InterestInvariantTest} handler fuzzes those benefactors live.)
     */
    function testFuzz_AssignInterestToContractKeepsCashedConstant(
        uint256 _balance,
        uint256 _proxyBal,
        uint256 _rate,
        uint256 _cashed
    )
        public
    {
        vault.harnessSetProxyBenefactor(
            contractAddr
        );

        vault.harnessMint(
            contractAddr,
            _balance
        );

        vault.harnessSetProxyBalance(
            contractAddr,
            _proxyBal
        );

        vault.harnessSetInterestRate(
            _rate
        );

        vault.harnessSetCashedInterest(
            contractAddr,
            _cashed
        );

        vault.exposedAssignInterest(
            contractAddr
        );

        assert(
            vault.cashedInterest(contractAddr) == _cashed
        );
    }

    /**
     * @dev End-to-end through the real ERC20 `transfer` override: a user
     * sends vault tokens to the contract, so the contract genuinely holds
     * a token balance; after an arbitrary amount of time the contract
     * still owes zero pending and zero cashed interest.
     */
    function testFuzz_TransferTokensToContractAccruesNoInterest(
        uint256 _mintAmount,
        uint256 _xfer,
        uint256 _delta
    )
        public
    {
        vm.assume(
            _mintAmount <= MAX_BASE
        );

        vm.assume(
            _xfer > 0 && _xfer <= _mintAmount
        );

        vm.assume(
            _delta <= 50 * SECONDS_IN_YEAR
        );

        vault.harnessMint(
            USER,
            _mintAmount
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        vm.prank(
            USER
        );

        vault.transfer(
            contractAddr,
            _xfer
        );

        vm.warp(
            T0 + _delta
        );

        assert(
            vault.getPendingInterest(contractAddr) == 0
        );

        assert(
            vault.cashedInterest(contractAddr) == 0
        );
    }

    // ---- PROPERTY 2: at 20%, no user accrues more than 20% in a year ----

    /**
     * @dev With the rate at 20%, pending interest for any user over any
     * window of at most one year is at most 20% of their interest base
     * (balanceOf + proxyBalance). This is the headline cap.
     */
    function testFuzz_PendingNeverExceeds20PercentWithinOneYear(
        uint256 _balance,
        uint256 _proxyBal,
        uint256 _delta
    )
        public
    {
        vm.assume(
            _balance <= MAX_BASE
        );

        vm.assume(
            _proxyBal <= MAX_BASE
        );

        vm.assume(
            _delta <= SECONDS_IN_YEAR
        );

        vault.harnessMint(
            USER,
            _balance
        );

        vault.harnessSetProxyBalance(
            USER,
            _proxyBal
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        uint256 base = _balance
            + _proxyBal;

        uint256 pending = vault.getPendingInterestByTimeStamp(
            USER,
            T0 + _delta
        );

        assert(
            pending <= base / 5
        );
    }

    /**
     * @dev At exactly one year the cap is tight: pending equals precisely
     * 20% of the base (floored). Proves the rate delivers exactly 20% per
     * annum — never silently less due to intermediate rounding, never
     * more.
     */
    function testFuzz_PendingExactlyTwentyPercentAtOneYear(
        uint256 _balance,
        uint256 _proxyBal
    )
        public
    {
        vm.assume(
            _balance <= MAX_BASE
        );

        vm.assume(
            _proxyBal <= MAX_BASE
        );

        vault.harnessMint(
            USER,
            _balance
        );

        vault.harnessSetProxyBalance(
            USER,
            _proxyBal
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        uint256 base = _balance
            + _proxyBal;

        uint256 pending = vault.getPendingInterestByTimeStamp(
            USER,
            T0 + SECONDS_IN_YEAR
        );

        assert(
            pending == base / 5
        );
    }

    /**
     * @dev Long-horizon no-overpay law at 20%: for ANY duration (up to
     * 100 years), the credited interest never exceeds the exact linear
     * entitlement `base * rate * dt / (year * 10000)`. Stated in
     * cross-multiplied integer form to avoid division rounding in the
     * assertion, this proves the integer flooring always rounds in the
     * protocol's favour — a user can never be over-credited, even after
     * decades of accrual.
     */
    function testFuzz_InterestNeverExceedsNominalLinear(
        uint256 _base,
        uint256 _delta
    )
        public
    {
        vm.assume(
            _base <= 1e30
        );

        vm.assume(
            _delta <= 100 * SECONDS_IN_YEAR
        );

        vault.harnessSetInterestRate(
            RATE_20_PCT
        );

        uint256 interest = vault.exposedCalculateInterest(
            _base,
            _delta
        );

        assert(
            interest * PRECISION_RATE * SECONDS_IN_YEAR <= _base * RATE_20_PCT * _delta
        );
    }

    // ---- ADVERSARIAL: pinning down where a naive 20% claim breaks ----

    /**
     * @dev The 20% guarantee is PER ANNUM, not absolute. Over two years
     * the same user is owed ~40% of base, strictly above 20%. This is the
     * counterexample Kontrol returns for an unbounded-time version of the
     * cap, and it documents that the one-year bound in
     * {testFuzz_PendingNeverExceeds20PercentWithinOneYear} is necessary.
     */
    function testFuzz_BoundaryTwoYearsExceedsTwentyPercent(
        uint256 _balance
    )
        public
    {
        vm.assume(
            _balance >= 10 && _balance <= MAX_BASE
        );

        vault.harnessMint(
            USER,
            _balance
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        uint256 pending = vault.getPendingInterestByTimeStamp(
            USER,
            T0 + 2 * SECONDS_IN_YEAR
        );

        assert(
            pending > _balance / 5
        );
    }

    /**
     * @dev The cap is on balanceOf + proxyBalance, not balanceOf alone.
     * With proxy balance present, one-year interest legitimately exceeds
     * 20% of the plain token balance, while still respecting 20% of the
     * full base. Shows the interest base must include proxyBalance.
     */
    function testFuzz_BoundaryProxyBalanceBeatsBalanceOfBound(
        uint256 _balance,
        uint256 _proxyBal
    )
        public
    {
        vm.assume(
            _balance <= MAX_BASE
        );

        vm.assume(
            _proxyBal >= 5 && _proxyBal <= MAX_BASE
        );

        vault.harnessMint(
            USER,
            _balance
        );

        vault.harnessSetProxyBalance(
            USER,
            _proxyBal
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        uint256 base = _balance
            + _proxyBal;

        uint256 pending = vault.getPendingInterestByTimeStamp(
            USER,
            T0 + SECONDS_IN_YEAR
        );

        assert(
            pending > _balance / 5
        );

        assert(
            pending <= base / 5
        );
    }

    // ---- PROPERTY 3 (INT-1): moveMyInterestTo conserves cashed interest ----

    /**
     * @dev The banked-interest ledger transfer is exactly conservative:
     * moving interest debits the sender by precisely the moved amount,
     * credits the target by precisely the same amount, and therefore
     * never changes the total cashed interest in existence — for any
     * pre-existing ledger balances, any amount and both move modes
     * (exact-amount and move-all).
     */
    function testFuzz_INT1_moveConservesCashedSum(
        uint256 _cashedFrom,
        uint256 _cashedTarget,
        uint256 _amount,
        bool _all
    )
        public
    {
        vm.assume(
            _cashedFrom <= MAX_BASE
        );

        vm.assume(
            _cashedTarget <= MAX_BASE
        );

        uint256 moveAmount = _all
            ? _cashedFrom
            : _amount;

        vm.assume(
            moveAmount > 0 && moveAmount <= _cashedFrom
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashedFrom
        );

        vault.harnessSetCashedInterest(
            OTHER,
            _cashedTarget
        );

        uint256 totalBefore = vault.harnessTotalCashedInterest();

        vault.exposedMoveInterestTo(
            USER,
            OTHER,
            _amount,
            _all
        );

        assert(
            vault.cashedInterest(USER) == _cashedFrom - moveAmount
        );

        assert(
            vault.cashedInterest(OTHER) == _cashedTarget + moveAmount
        );

        assert(
            vault.cashedInterest(USER) + vault.cashedInterest(OTHER)
                == _cashedFrom + _cashedTarget
        );

        assert(
            vault.harnessTotalCashedInterest() == totalBefore
        );
    }

    /**
     * @dev A self-move is a complete no-op: the ledger is untouched
     * for any amount and both move modes, including amounts larger
     * than the available balance (the self-guard short-circuits before
     * any validation).
     */
    function testFuzz_INT1_moveSelfIsNoOp(
        uint256 _cashed,
        uint256 _amount,
        bool _all
    )
        public
    {
        vm.assume(
            _cashed <= MAX_BASE
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashed
        );

        vault.exposedMoveInterestTo(
            USER,
            USER,
            _amount,
            _all
        );

        assert(
            vault.cashedInterest(USER) == _cashed
        );
    }

    /**
     * @dev The ledger can never be moved into the two forbidden sinks:
     * the zero address and the InterestRateProxy (== the contract).
     * Every such attempt reverts and leaves both ledgers untouched —
     * for any balances, any amount and both move modes.
     */
    function testFuzz_INT1_moveToForbiddenTargetReverts(
        uint256 _cashed,
        uint256 _amount,
        bool _all,
        bool _toZero
    )
        public
    {
        vm.assume(
            _cashed <= MAX_BASE
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashed
        );

        address target = _toZero
            ? address(0)
            : contractAddr;

        try vault.exposedMoveInterestTo(USER, target, _amount, _all) {
            assert(
                false
            );
        } catch {}

        assert(
            vault.cashedInterest(USER) == _cashed
        );

        assert(
            vault.cashedInterest(target) == 0
        );
    }

    /**
     * @dev Overdraw is impossible: an exact-amount move of more than
     * the available cashed interest (and any move of zero) reverts and
     * leaves both ledgers untouched — the sender can never go negative
     * and the target can never be credited out of thin air.
     */
    function testFuzz_INT1_moveOverdrawReverts(
        uint256 _cashedFrom,
        uint256 _cashedTarget,
        uint256 _amount
    )
        public
    {
        vm.assume(
            _cashedFrom <= MAX_BASE
        );

        vm.assume(
            _cashedTarget <= MAX_BASE
        );

        vm.assume(
            _amount == 0 || _amount > _cashedFrom
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashedFrom
        );

        vault.harnessSetCashedInterest(
            OTHER,
            _cashedTarget
        );

        try vault.exposedMoveInterestTo(USER, OTHER, _amount, false) {
            assert(
                false
            );
        } catch {}

        assert(
            vault.cashedInterest(USER) == _cashedFrom
        );

        assert(
            vault.cashedInterest(OTHER) == _cashedTarget
        );
    }

    // ---- PROPERTY 4 (INT-7): the global accumulator moves in lockstep ----

    /**
     * @dev Accrual lockstep: banking a user's pending interest adds
     * exactly that pending amount to both the user's ledger and the
     * global `totalCashedInterest` accumulator — for any balance and
     * any accrual window up to a year.
     */
    function testFuzz_INT7_assignAddsPendingToTotal(
        uint256 _balance,
        uint256 _delta
    )
        public
    {
        vm.assume(
            _balance <= MAX_BASE
        );

        vm.assume(
            _delta <= SECONDS_IN_YEAR
        );

        vault.harnessMint(
            USER,
            _balance
        );

        vault.harnessSetLastSync(
            USER,
            T0
        );

        vm.warp(
            T0 + _delta
        );

        uint256 pending = vault.getPendingInterest(
            USER
        );

        uint256 cashedBefore = vault.cashedInterest(
            USER
        );

        uint256 totalBefore = vault.harnessTotalCashedInterest();

        vault.exposedAssignInterest(
            USER
        );

        assert(
            vault.cashedInterest(USER) == cashedBefore + pending
        );

        assert(
            vault.harnessTotalCashedInterest() == totalBefore + pending
        );
    }

    /**
     * @dev Full-claim lockstep: zeroing a user's ledger debits the
     * global accumulator by exactly the zeroed amount and leaves every
     * other ledger untouched — for any consistent pre-state.
     */
    function testFuzz_INT7_prepareClaimSubtractsExactly(
        uint256 _cashedUser,
        uint256 _cashedOther
    )
        public
    {
        vm.assume(
            _cashedUser > 0 && _cashedUser <= MAX_BASE
        );

        vm.assume(
            _cashedOther <= MAX_BASE
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashedUser
        );

        vault.harnessSetCashedInterest(
            OTHER,
            _cashedOther
        );

        vault.harnessSetTotalCashedInterest(
            _cashedUser + _cashedOther
        );

        uint256 claimed = vault.exposedPrepareClaim(
            USER
        );

        assert(
            claimed == _cashedUser
        );

        assert(
            vault.cashedInterest(USER) == 0
        );

        assert(
            vault.harnessTotalCashedInterest() == _cashedOther
        );
    }

    /**
     * @dev Exact-amount lockstep: debiting a user's ledger by a chosen
     * amount debits the global accumulator by exactly that amount —
     * for any consistent pre-state and any amount within the ledger.
     */
    function testFuzz_INT7_prepareExactAmountSubtractsExactly(
        uint256 _cashed,
        uint256 _amount
    )
        public
    {
        vm.assume(
            _cashed <= MAX_BASE
        );

        vm.assume(
            _amount > 0 && _amount <= _cashed
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashed
        );

        vault.harnessSetTotalCashedInterest(
            _cashed
        );

        vault.exposedPrepareExactAmountClaim(
            USER,
            _amount
        );

        assert(
            vault.cashedInterest(USER) == _cashed - _amount
        );

        assert(
            vault.harnessTotalCashedInterest() == _cashed - _amount
        );
    }

    /**
     * @dev Overdraw / zero-amount claims revert and leave both the
     * user's ledger and the global accumulator untouched — the
     * accumulator can never be debited past the ledger it mirrors.
     */
    function testFuzz_INT7_prepareExactAmountOverdrawRevertsNoChange(
        uint256 _cashed,
        uint256 _amount
    )
        public
    {
        vm.assume(
            _cashed <= MAX_BASE
        );

        vm.assume(
            _amount == 0 || _amount > _cashed
        );

        vault.harnessSetCashedInterest(
            USER,
            _cashed
        );

        vault.harnessSetTotalCashedInterest(
            _cashed
        );

        try vault.exposedPrepareExactAmountClaim(USER, _amount) {
            assert(
                false
            );
        } catch {}

        assert(
            vault.cashedInterest(USER) == _cashed
        );

        assert(
            vault.harnessTotalCashedInterest() == _cashed
        );
    }
}
