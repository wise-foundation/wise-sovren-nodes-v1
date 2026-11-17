// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test, Vm} from "forge-std/Test.sol";

import {IReferralHub} from "../../referral/hub/IReferralHub.sol";
import {CohortFlushCodec} from "../../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortFlushFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {WiseSovrenNodesDiamondErrors} from "../../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";
import {SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";

import {UpgradeCohortFlushCourier} from "../../../script/diamond/UpgradeCohortFlushCourier.s.sol";
import {WiseSovrenNodesDiamondSelectors} from "../../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

/**
 * @dev Minimal local surface of the LIVE Sovren diamond used by the
 * courier open rehearsal, driven through the diamond's own dispatcher.
 */
interface ISovrenCourierVault {

    function master()
        external
        view
        returns (address);

    function proposeOwner(
        address proposedOwner
    )
        external;

    function claimOwnership()
        external;

    function selectorToFacet(
        bytes4 selector
    )
        external
        view
        returns (address);

    function selectorChangeQueuedAt(
        bytes4 selector
    )
        external
        view
        returns (uint256);

    function executeSelectorChanges(
        bytes4[] memory selectors
    )
        external;

    function paused()
        external
        view
        returns (bool);

    function depositsDisabled()
        external
        view
        returns (bool);

    function unpauseDeposits()
        external;

    function setDepositsDisabled(
        bool disabled
    )
        external;

    function totalSupply()
        external
        view
        returns (uint256);

    function setTotalDepositCap(
        uint256 cap
    )
        external;

    function USD_TOKEN()
        external
        view
        returns (address);

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

    function advanceBook(
        address referrer,
        uint256 maxBoundaries
    )
        external;

    function getAllowedFlushBot(
        address bot
    )
        external
        view
        returns (bool);

    function setAllowedFlushBot(
        address bot,
        bool allowed
    )
        external;

    function getFlushedThroughWeek(
        address referrer
    )
        external
        view
        returns (uint256);

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        );

    function flushReferrals(
        address[] calldata referrers
    )
        external
        payable;

    function quoteFlushFee(
        address[] calldata referrers
    )
        external
        view
        returns (uint256);

    function previewFlushEnvelope(
        address[] calldata referrers
    )
        external
        view
        returns (bytes memory);
}

interface IUsdDecimals {

    function decimals()
        external
        view
        returns (uint8);
}

/**
 * @dev Rehearses the courier flush facet upgrade on a fork of the live
 * Sovren vault by driving the broadcast script itself: on the fork the live
 * master hands the master role to the test key (`proposeOwner` and
 * `claimOwnership`, the diamond's own two step handover), the key goes
 * into PRIVATE_KEY, and `UpgradeCohortFlushCourier.propose()` deploys the
 * new {CohortFlushFacet} and proposes the cohortFlush selector batch, a
 * premature execute reverts on the real 3-day timelock, `execute()` flips
 * the four selectors after it and post asserts the routing, and `abort()`
 * cancels a pending proposal while the live facet stays. Around the flip
 * the scenario pins the rule the build changes against the live state:
 * before it the live facet refuses a courier batch over a never flushed
 * book with its retired error; after it the allowed courier's batch opens
 * that book at the week before the current one, emitting the cursor event
 * exactly as the referrer's own batch would, a stranger stays refused, and
 * the courier's next batch a week later plans only the week closed since
 * the open and writes nothing. The vault delivers locally to the LIVE hub
 * on its own chain, whose bucket for the referrer fills. Were the vault
 * paused at rehearsal time it is unpaused on the fork and the courier
 * waits out the outage grace the reopen starts, as it would on the chain.
 * Run alone: the script reads VAULT_PRODUCT and PRIVATE_KEY from the
 * process environment.
 */
contract WiseSovrenNodesCourierOpenForkTest is Test {

    event CohortReferrerFlushed(
        address indexed referrer,
        uint256 flushedThroughWeek,
        uint256 flushedGapIndex,
        uint256 gapResumeWeek
    );

    address internal constant LIVE_COURIER = 0xB5395cBf6B41bc9606aee98A0eBC37145729085a;

    bytes4 internal constant RETIRED_VIRGIN_ERROR = bytes4(
        keccak256(
            "FlushCursorVirgin()"
        )
    );

    uint256 internal constant DEPOSIT_UNITS = 100_000;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant MAX_GRACE_WEEKS = 12;

    ISovrenCourierVault internal v;

    address internal diamond;

    address internal usd;

    address internal liveMaster;

    uint256 internal one;

    address internal operator;

    uint256 internal operatorPk;

    address internal user;

    address internal referrer;

    address internal stranger;

    UpgradeCohortFlushCourier internal script;

    function setUp()
        public
    {
        diamond = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdc.mainnet.json"
            ),
            ".diamond"
        );

        vm.createSelectFork(
            "mainnet"
        );

        require(
            diamond.code.length > 0,
            "diamond not deployed on this fork"
        );

        v = ISovrenCourierVault(
            diamond
        );

        usd = v.USD_TOKEN();

        liveMaster = v.master();

        one = 10 ** IUsdDecimals(usd).decimals();

        (
            operator,
            operatorPk
        ) = makeAddrAndKey(
            "courierOpenOperator"
        );

        user = makeAddr(
            "courierOpenUser"
        );

        referrer = makeAddr(
            "courierOpenReferrer"
        );

        stranger = makeAddr(
            "courierOpenStranger"
        );

        script = new UpgradeCohortFlushCourier();

        vm.setEnv(
            "VAULT_PRODUCT",
            "usdc"
        );
    }

    function test_courierOpen_scriptUpgradeThenCourierOpensAndCarries()
        public
    {
        address liveFacet = v.selectorToFacet(
            CohortFlushFacet.flushReferrals.selector
        );

        assertTrue(
            liveFacet != address(0),
            "the flush round must be routed on the live vault"
        );

        _handOverMaster();

        _allowCourier();

        _referredDeposit();

        address[] memory refs = _oneRef(
            referrer
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            0,
            "a fresh book must start with no send cursor"
        );

        _waitOutGraceAndPinLiveRefusal(
            refs
        );

        _upgradeThroughScript(
            liveFacet
        );

        uint256 openWeek = block.timestamp / CohortWeeks.WEEK
            - 1;

        _courierFlush(
            refs,
            openWeek
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            openWeek,
            "the courier batch must open the book at the week before the current one"
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotFlushBot.selector
        );

        v.flushReferrals(
            refs
        );

        vm.warp(
            block.timestamp + CohortWeeks.WEEK + 1 days
        );

        v.advanceBook(
            referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        bytes memory preview = v.previewFlushEnvelope(
            refs
        );

        uint256 entryWord = _envWord(
            preview,
            1
        );

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                entryWord
            ),
            1,
            "the next batch must plan exactly the one week closed since the open"
        );

        assertEq(
            _envWord(
                preview,
                _firstCrumbIndex(
                    entryWord
                )
            ),
            openWeek + 1,
            "the next batch must start right above the stored cursor"
        );

        vm.recordLogs();

        _courierFlush(
            refs,
            0
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0,
            "a courier batch over a stored cursor must write nothing"
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            openWeek,
            "the stored cursor must stay where the open left it"
        );

        _assertLiveHubFilled(
            openWeek + 1
        );
    }

    function test_courierOpen_abortCancelsTheProposalAndKeepsTheLiveFacet()
        public
    {
        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        address liveFacet = v.selectorToFacet(
            sels[0]
        );

        _handOverMaster();

        script.propose();

        assertTrue(
            v.selectorChangeQueuedAt(sels[0]) > 0,
            "propose must queue the cohortFlush batch"
        );

        script.abort();

        for (uint256 i; i < sels.length; ++i) {

            assertEq(
                v.selectorChangeQueuedAt(
                    sels[i]
                ),
                0,
                "abort must cancel every selector of the batch"
            );

            assertEq(
                v.selectorToFacet(
                    sels[i]
                ),
                liveFacet,
                "abort must leave the live facet routed"
            );
        }
    }

    // ---- the script driven upgrade ----

    function _handOverMaster()
        internal
    {
        vm.prank(
            liveMaster
        );

        v.proposeOwner(
            operator
        );

        vm.prank(
            operator
        );

        v.claimOwnership();

        assertEq(
            v.master(),
            operator,
            "the fork handover must make the test key the master"
        );

        vm.setEnv(
            "PRIVATE_KEY",
            vm.toString(
                operatorPk
            )
        );
    }

    function _upgradeThroughScript(
        address _liveFacet
    )
        internal
    {
        bytes4[] memory sels = WiseSovrenNodesDiamondSelectors._cohortFlushSelectors();

        script.status();

        script.propose();

        uint256 proposedAt = block.timestamp;

        assertTrue(
            v.selectorChangeQueuedAt(sels[0]) > 0,
            "propose must queue the cohortFlush batch"
        );

        vm.prank(
            operator
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            sels
        );

        vm.warp(
            proposedAt + SELECTOR_DELAY + 1
        );

        script.execute();

        vm.warp(
            proposedAt + 2
        );

        address routed = v.selectorToFacet(
            sels[0]
        );

        assertTrue(
            routed != _liveFacet
                && routed.code.length > 0,
            "execute must route the group to the new facet"
        );

        for (uint256 i; i < sels.length; ++i) {

            assertEq(
                v.selectorToFacet(
                    sels[i]
                ),
                routed,
                "every selector of the group must route to the new facet"
            );

            assertEq(
                v.selectorChangeQueuedAt(
                    sels[i]
                ),
                0,
                "nothing may stay queued after execute"
            );
        }

        script.status();
    }

    // ---- the scenario helpers ----

    function _allowCourier()
        internal
    {
        if (v.getAllowedFlushBot(LIVE_COURIER)) {
            return;
        }

        vm.prank(
            operator
        );

        v.setAllowedFlushBot(
            LIVE_COURIER,
            true
        );
    }

    function _referredDeposit()
        internal
    {
        uint256 amount = DEPOSIT_UNITS * one;

        if (v.paused()) {

            vm.prank(
                operator
            );

            v.unpauseDeposits();
        }

        if (v.depositsDisabled()) {

            vm.prank(
                operator
            );

            v.setDepositsDisabled(
                false
            );
        }

        uint256 liftedCap = v.totalSupply()
            + 100 * amount;

        vm.prank(
            operator
        );

        v.setTotalDepositCap(
            liftedCap
        );

        deal(
            usd,
            user,
            amount
        );

        vm.prank(
            user
        );

        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                diamond,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            amount,
            referrer
        );
    }

    /// @dev The live facet refuses a courier batch over a never flushed book
    /// with the error the new build retires; a vault unpaused on the fork
    /// first refuses every third party inside the outage grace its reopen
    /// started, so the courier waits week by week until the gate opens, as
    /// it would on the chain.
    function _waitOutGraceAndPinLiveRefusal(
        address[] memory _refs
    )
        internal
    {
        for (uint256 i; i < MAX_GRACE_WEEKS; ++i) {

            vm.prank(
                LIVE_COURIER
            );

            try v.flushReferrals(
                _refs
            ) {
                revert(
                    "the live facet accepted a courier batch over a never flushed book"
                );
            } catch (bytes memory reason) {

                if (keccak256(reason) == keccak256(abi.encodeWithSelector(RETIRED_VIRGIN_ERROR))) {
                    return;
                }

                require(
                    keccak256(reason) == keccak256(
                        abi.encodeWithSelector(
                            WiseSovrenNodesDiamondErrors.FlushOutageGraceActive.selector
                        )
                    ),
                    "the live facet refused the courier probe with an unexpected error"
                );

                vm.warp(
                    block.timestamp + CohortWeeks.WEEK
                );
            }
        }

        revert(
            "the outage grace did not end within the rehearsal horizon"
        );
    }

    function _courierFlush(
        address[] memory _refs,
        uint256 _expectedOpenWeek
    )
        internal
    {
        uint256 fee = v.quoteFlushFee(
            _refs
        );

        assertEq(
            fee,
            0,
            "a local flush charges no fee"
        );

        if (_expectedOpenWeek != 0) {

            vm.expectEmit(
                true,
                false,
                false,
                true,
                diamond
            );

            emit CohortReferrerFlushed(
                referrer,
                _expectedOpenWeek,
                0,
                0
            );
        }

        vm.prank(
            LIVE_COURIER
        );

        v.flushReferrals(
            _refs
        );
    }

    function _assertLiveHubFilled(
        uint256 _carriedWeek
    )
        internal
        view
    {
        (
            address hub,
            uint64 selector
        ) = v.getFlushHub();

        assertEq(
            selector,
            0,
            "the Sovren vault must deliver locally to the hub on its own chain"
        );

        (
            uint256 referredInput,
        ) = IReferralHub(hub).ladderInputsAt(
            referrer,
            _carriedWeek
        );

        assertGt(
            referredInput,
            0,
            "the courier batch must land the carried week's referred average on the live hub"
        );

        assertGt(
            IReferralHub(hub).claimable(
                block.chainid,
                referrer
            ),
            0,
            "the local courier batches must fill the referrer's bucket on the live hub"
        );
    }

    function _firstCrumbIndex(
        uint256 _entryWord
    )
        internal
        pure
        returns (uint256 index)
    {
        index = 2
            + CohortFlushCodec._flushEntrySelfRunCount(
                _entryWord
            );

        if (CohortFlushCodec._flushEntryFlags(_entryWord) & CohortFlushCodec.FLUSH_FLAG_DESIGNATION != 0) {
            ++index;
        }
    }

    function _envWord(
        bytes memory _data,
        uint256 _index
    )
        internal
        pure
        returns (uint256 w)
    {
        assembly {
            w := mload(
                add(
                    _data,
                    add(
                        0x20,
                        mul(
                            _index,
                            0x20
                        )
                    )
                )
            )
        }
    }

    function _countReferrerFlushedLogs()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CohortReferrerFlushed(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].emitter == diamond && logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _oneRef(
        address _referrer
    )
        internal
        pure
        returns (address[] memory refs)
    {
        refs = new address[](1);

        refs[0] = _referrer;
    }
}
