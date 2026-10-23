// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseSovrenNodesDiamond} from "../../src/diamond/vault/WiseSovrenNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortRecorderBase} from "../../src/diamond/vault/facets/pending/CohortRecorderBase.sol";
import {FacetBase} from "../../src/diamond/vault/facets/FacetBase.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {ReferralRegistry} from "../referral/registry/ReferralRegistry.sol";

import {WiseSovrenNodesDiamondErrors} from "../../src/diamond/vault/WiseSovrenNodesDiamondErrors.sol";

import {WiseSovrenNodesDiamondSelectors} from "../../script/diamond/WiseSovrenNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";
import {BridgeCarryTestCodec} from "./utils/BridgeCarryTestCodec.sol";
import {CarryMockUSD, CarryMockRouter} from "./WiseSovrenNodesCohortBridgeCarry.t.sol";

/**
 * @dev A registry stand-in whose `getReferrerPair` answers in exactly
 * one hostile shape per deployed instance, selected by the immutable
 * `MODE` (immutables survive `vm.etch` because they live in the
 * runtime code): 0 returns 32 bytes instead of 96, 1 returns a
 * referrer word with dirt above bit 160, 2 returns an assignedAt word
 * above the uint64 lane, 3 returns a rank word above one byte, and
 * anything else reverts outright. Every other selector (including
 * `effectiveReferrerOf`) hits the missing fallback and reverts, so
 * the guarded staticcall seams see a uniformly broken registry.
 */
contract ShapeShiftPairRegistry {

    uint256 public immutable MODE;

    constructor(
        uint256 _mode
    ) {
        MODE = _mode;
    }

    function getReferrerPair(
        address
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 mode = MODE;

        assembly {
            switch mode
            case 0 {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
            case 1 {
                mstore(0x00, shl(160, 1))
                mstore(0x20, 0)
                mstore(0x40, 0)
                return(0x00, 0x60)
            }
            case 2 {
                mstore(0x00, 0)
                mstore(0x20, shl(64, 1))
                mstore(0x40, 0)
                return(0x00, 0x60)
            }
            case 3 {
                mstore(0x00, 0)
                mstore(0x20, 0)
                mstore(0x40, 0x100)
                return(0x00, 0x60)
            }
            default {
                revert(0x00, 0x00)
            }
        }
    }
}

/**
 * @dev A registry stand-in for the arrival merge seam that answers
 * `effectiveReferrerOf` honestly with a fixed local referrer but
 * reverts every `mergeReferrer`, standing in for a registry that
 * rejects the carried origin key. The guarded merge must swallow the
 * revert and the lanes must land under the local answer. Its
 * `syncPeerQuarantined` answers false for every chain, so the arrival
 * seam's quarantine read passes and the merge is really attempted.
 */
contract MergeRevertRegistry {

    address public immutable LOCAL_ANSWER;

    constructor(
        address _localAnswer
    ) {
        LOCAL_ANSWER = _localAnswer;
    }

    function syncPeerQuarantined(
        uint64
    )
        external
        pure
        returns (bool)
    {
        return false;
    }

    function mergeReferrer(
        address,
        address,
        uint256,
        uint256
    )
        external
        pure
    {
        revert(
            "MergeRevertRegistry: reverts"
        );
    }

    function effectiveReferrerOf(
        address,
        address
    )
        external
        view
        returns (address)
    {
        return LOCAL_ANSWER;
    }
}

/**
 * @dev A registry stand-in whose `mergeReferrer` succeeds (counting
 * calls so the merge attempt is observable) while every post-merge
 * `effectiveReferrerOf` lookup reverts: the shape of a registry that
 * breaks between the merge write and the landing read. The apply path
 * must keep the tracked delta and drop only the book lanes. Its
 * `syncPeerQuarantined` answers false for every chain, so the merge
 * attempt the counter records is never skipped by the quarantine read.
 */
contract LookupRevertRegistry {

    uint256 public mergeCalls;

    function syncPeerQuarantined(
        uint64
    )
        external
        pure
        returns (bool)
    {
        return false;
    }

    function mergeReferrer(
        address,
        address,
        uint256,
        uint256
    )
        external
    {
        mergeCalls += 1;
    }

    function effectiveReferrerOf(
        address,
        address
    )
        external
        pure
        returns (address)
    {
        revert(
            "LookupRevertRegistry: reverts"
        );
    }
}

/**
 * @dev An honest registry stand-in for the arrival quarantine seam:
 * `effectiveReferrerOf` answers a fixed local referrer, `mergeReferrer`
 * counts calls so a merge attempt (or its absence) is observable, and
 * `syncPeerQuarantined` answers a per-chain flag the test raises or
 * lowers through `setQuarantined`, standing in for a registry whose
 * master braked one peer chain with `removeSyncPeer`.
 */
contract QuarantineRegistry {

    address public immutable LOCAL_ANSWER;

    uint256 public mergeCalls;

    mapping(uint64 => bool) public syncPeerQuarantined;

    constructor(
        address _localAnswer
    ) {
        LOCAL_ANSWER = _localAnswer;
    }

    function setQuarantined(
        uint64 _chainSelector,
        bool _quarantined
    )
        external
    {
        syncPeerQuarantined[_chainSelector] = _quarantined;
    }

    function mergeReferrer(
        address,
        address,
        uint256,
        uint256
    )
        external
    {
        mergeCalls += 1;
    }

    function effectiveReferrerOf(
        address,
        address
    )
        external
        view
        returns (address)
    {
        return LOCAL_ANSWER;
    }
}

/**
 * @dev A registry stand-in whose `syncPeerQuarantined` answers in
 * exactly one hostile shape per deployed instance, selected by the
 * immutable `MODE` in the register of {ShapeShiftPairRegistry}: 0
 * returns 64 bytes instead of 32 (a first word of zero that a naive
 * decode would read as not quarantined), 1 returns a dirty word of 2,
 * and anything else reverts outright. `effectiveReferrerOf` answers a
 * fixed local referrer honestly and `mergeReferrer` counts calls, so
 * the pins observe that every hostile quarantine answer reads as a
 * quarantine read failure that skips the merge while the lanes still
 * land under the local answer.
 */
contract ShapeShiftQuarantineRegistry {

    uint256 public immutable MODE;

    address public immutable LOCAL_ANSWER;

    uint256 public mergeCalls;

    constructor(
        uint256 _mode,
        address _localAnswer
    ) {
        MODE = _mode;
        LOCAL_ANSWER = _localAnswer;
    }

    function syncPeerQuarantined(
        uint64
    )
        external
        view
        returns (bool)
    {
        uint256 mode = MODE;

        assembly {
            switch mode
            case 0 {
                mstore(0x00, 0)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
            case 1 {
                mstore(0x00, 2)
                return(0x00, 0x20)
            }
            default {
                revert(0x00, 0x00)
            }
        }
    }

    function mergeReferrer(
        address,
        address,
        uint256,
        uint256
    )
        external
    {
        mergeCalls += 1;
    }

    function effectiveReferrerOf(
        address,
        address
    )
        external
        view
        returns (address)
    {
        return LOCAL_ANSWER;
    }
}

/**
 * @dev Narrow-writer harness over {CohortRecorderBase} for the
 * bridge-carry capture/apply seam, following the
 * {CohortCarryHarness} register: deployed STANDALONE, no diamond and
 * no DELEGATECALL, storage layout identical to the diamond's via
 * {CohortPinnedBase}, every `exposed*` forwarding verbatim
 * into the inherited engine internal and every `harnessSet*` writer
 * touching exactly one declared field. It takes its registry as an
 * address (tests deploy and point it themselves) and embeds no
 * creation code, keeping the contract clear of the EIP-170 limit the
 * full-surface harness split was made for.
 */
contract CohortBridgeSeamHarness is CohortRecorderBase {

    // ---- exposed engine internals (real code under test) ----

    function exposedCaptureBridgeOut(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        returns (bytes memory)
    {
        return _captureBridgeOutCohort(
            _user,
            _dstChainSelector,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }

    function exposedApplyBridgeIn(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes memory _payload
    )
        external
        returns (bool)
    {
        return _applyBridgeInCohort(
            _user,
            _srcChainSelector,
            _mintedAmount,
            _payload
        );
    }

    // ---- narrow storage writers (harness scaffolding only) ----

    function harnessSetRegistry(
        address _registry
    )
        external
    {
        referralRegistry = _registry;
    }

    function harnessSetTracked(
        address _user,
        uint256 _amount
    )
        external
    {
        trackedContribution[_user] = _amount;

        attributedContribution[_user] = _amount;
    }

    function harnessSetAttributed(
        address _user,
        uint256 _amount
    )
        external
    {
        attributedContribution[_user] = _amount;
    }

    function harnessSetBookLanes(
        address _referrer,
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
    {
        cohortBook[_referrer] = CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        );
    }

    function harnessMintBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            + _amount;
    }

    function harnessSetRingYear1(
        address _referrer,
        uint256 _slot,
        uint64 _amount
    )
        external
    {
        cohortRingYear1[_referrer][_slot] = _amount;
    }

    function harnessSetRingYear2(
        address _referrer,
        uint256 _slot,
        uint64 _amount
    )
        external
    {
        cohortRingYear2[_referrer][_slot] = _amount;
    }

    // ---- view helpers ----

    function viewTracked(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return trackedContribution[_user];
    }

    function viewAttributed(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return attributedContribution[_user];
    }

    function viewBookWord(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortBook[_referrer];
    }

    function viewRingYear1(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear1[_referrer][_slot];
    }

    function viewRingYear2(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear2[_referrer][_slot];
    }
}

/**
 * @dev Sibling narrow-writer harness dedicated to the referrer-flip
 * migration internals, a SEPARATE contract from
 * {CohortBridgeSeamHarness} so neither closure approaches the EIP-170
 * runtime limit, mirroring how {CohortLaneHarness} and
 * {CohortCarryHarness} split the same-chain surface. Same standalone
 * rules: layout parity via {CohortPinnedBase}, `exposed*`
 * verbatim into the engine, `harnessSet*` one declared field each.
 */
contract CohortFlipSeamHarness is CohortRecorderBase {

    // ---- exposed engine internals (real code under test) ----

    function exposedMigrateReferrer(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
    {
        _migrateReferrerCohort(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    // ---- narrow storage writers (harness scaffolding only) ----

    function harnessSetTracked(
        address _user,
        uint256 _amount
    )
        external
    {
        trackedContribution[_user] = _amount;

        attributedContribution[_user] = _amount;
    }

    function harnessSetAttributed(
        address _user,
        uint256 _amount
    )
        external
    {
        attributedContribution[_user] = _amount;
    }

    function harnessSetRingYear1(
        address _referrer,
        uint256 _slot,
        uint64 _value
    )
        external
    {
        cohortRingYear1[_referrer][_slot] = _value;
    }

    function harnessSetBookLanes(
        address _referrer,
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        external
    {
        cohortBook[_referrer] = CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        );
    }

    function harnessMintBalance(
        address _user,
        uint256 _amount
    )
        external
    {
        _balances[_user] = _balances[_user]
            + _amount;
    }

    // ---- view helpers ----

    function viewTracked(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return trackedContribution[_user];
    }

    function viewAttributed(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return attributedContribution[_user];
    }

    function viewBookWord(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortBook[_referrer];
    }

    function viewRingYear1(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear1[_referrer][_slot];
    }

    function viewRingYear2(
        address _referrer,
        uint256 _slot
    )
        external
        view
        returns (uint64)
    {
        return cohortRingYear2[_referrer][_slot];
    }
}

/**
 * @dev Negative-space suite for the cross-chain cohort bridge-carry
 * seam, complementing the happy-path
 * {WiseSovrenNodesCohortBridgeCarryTest} the way the move-carry
 * negative suite complements the same-chain fixture. Two real
 * diamonds joined by the same synchronous {CarryMockRouter} pin the
 * trust boundary against hostile registries (etched over the real
 * pointer with every malformed `getReferrerPair` answer shape),
 * etched-dead routed hook facets (bridge apply degrades to
 * {CohortBridgeHookFailed} plus the legacy fallback while the mint
 * stands; the flip route bubbles its revert so the registry defers
 * the migration and restores the marker), an armed destination whose
 * bridge-in selector group was never routed (structural no-op plus
 * fallback), a transfer hook pointer zeroed while the recorder stays
 * armed (written directly, because the AdminFacet refuses to execute
 * a zero hook while armed; every sync poke becomes a silent no-op and
 * funds keep moving), and a lower-decimal peer whose
 * per-component floor scaling is asserted on the source-side wire
 * payload. Direct external calls to the three routed engine
 * entrypoints must revert {NotHookExecution}; the bracket only ever
 * closes around the vault's own internal dispatch.
 *
 * The two in-file harnesses drive the engine internals the
 * full-diamond fixture cannot reach: capture with an unset registry
 * pointer (a failed lookup reported once: clamp deferred, carry
 * skipped, nothing staged), a deficit
 * whose scaled envelope collapses to zero (clamp runs, empty wire),
 * apply with an unset pointer or a post-merge lookup failure (tracked
 * applied, book lanes dropped), a rejected merge (lanes land under
 * the local answer), the flip migration's sale-like deficit clamp and
 * its saturating landing clip at the pair's own slot. A scaled-down
 * capture over a three-lane book
 * floors every lane on its own, so the carried tracked delta stays
 * strictly below the floored burn and a second harness lands each
 * floored lane under the mint without ever rounding up.
 *
 * Every harness apply first gives the user a balance of at least the
 * tracked amount plus the carried delta, because the arrival seam
 * discards a payload wholesale when the carried delta would lift
 * tracked above the balance held after the mint; the headroom pins
 * hold that ceiling on the harness and on a real diamond whose holder
 * already sits above held. {QuarantineRegistry} and
 * {ShapeShiftQuarantineRegistry} pin the quarantine read before the
 * merge: an unquarantined source chain merges, a quarantined one (or a
 * wrong-size, dirty or reverting answer, which reports its own
 * quarantine read failure, never a failed referrer lookup) skips the
 * merge while the lanes land under the local answer.
 * The capture pins read the capture week and codec version 2 off the
 * envelope word, a capture week ahead of the arrival clock lands
 * without drift, and one boundary crossed in flight lands the year-1
 * aggregate on the year-2 ring.
 */
/**
 * @dev Full-chain harness for the helper-chain bridge-out stub alone:
 * deployed STANDALONE over {FacetBase}, so the stub's own disarmed
 * short-circuit (pre-guarded by its only production call site and
 * therefore reachable nowhere else) executes as real code. The stub
 * lives in the helper chain, which the slim engine base does not
 * inherit, so it cannot ride the seam harness.
 */
contract CohortBridgeOutStubHarness is FacetBase {

    function exposedCohortBridgeOut(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        external
        returns (bytes memory)
    {
        return _cohortBridgeOut(
            _user,
            _dstChainSelector,
            _burnedAmount,
            _scaleNumerator,
            _scaleDenominator
        );
    }
}

contract WiseSovrenNodesCohortBridgeCarryNegativeTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DEPOSIT_B = 1_000 * 1e6;

    uint256 internal constant BRIDGE_AMOUNT = 2_000 * 1e6;

    uint256 internal constant SLICE = 100 * 1e6;

    uint256 internal constant FEE = 0.01 ether;

    uint64 internal constant SELECTOR_A = 1111;

    uint64 internal constant SELECTOR_B = 2222;

    uint64 internal constant SELECTOR_LOW = 3333;

    bytes internal constant REVERT_CODE = hex"60006000fd";

    bytes internal constant OOG_CODE = hex"5b600056";

    uint256 internal constant TRANSFER_HOOK_SLOT = 45;

    uint256 internal constant REFERRAL_REGISTRY_SLOT = 77;

    bytes32 internal constant SENT_TOPIC = keccak256(
        "CohortBridgeCarrySent(address,uint64,address,uint256,uint256,uint256,uint256,address)"
    );

    address internal user1 = address(0xA1);
    address internal buyer = address(0xC2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);

    WiseSovrenNodesDiamond internal vaultA;
    WiseSovrenNodesDiamond internal vaultB;

    CarryMockUSD internal usdA;
    CarryMockUSD internal usdB;

    ReferralRegistry internal registryA;
    ReferralRegistry internal registryB;

    CarryMockRouter internal router;

    address internal bridgeHookFacetA;
    address internal bridgeHookFacetB;

    CohortBridgeSeamHarness internal seamHarness;
    CohortFlipSeamHarness internal flipHarness;
    CohortBridgeOutStubHarness internal stubHarness;

    event CohortBridgeCarrySent(
        address indexed user,
        uint64 indexed dstChainSelector,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        address bookReferrer
    );

    event CohortBridgeCarryApplied(
        address indexed user,
        uint64 indexed srcChainSelector,
        address indexed effectiveReferrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeCarrySkipped(
        address indexed user,
        uint64 indexed dstChainSelector
    );

    event CohortBridgeCarryBookDropped(
        address indexed user,
        uint64 indexed srcChainSelector,
        address carriedReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    event CohortBridgeHookFailed(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortReferrerLookupFailed(
        address indexed user
    );

    event CohortQuarantineReadFailed(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event CohortAttributionCharged(
        address indexed user,
        address indexed referrer,
        uint256 charged,
        uint256 uncharged
    );

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    event CohortReferrerFlipApplied(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        uint256 pairCount
    );

    event CohortBridgeCarryDiscarded(
        address indexed user,
        uint64 indexed srcChainSelector
    );

    event BridgeReferral(
        address indexed user,
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        bytes referralData
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdA = new CarryMockUSD();

        usdB = new CarryMockUSD();

        registryA = new ReferralRegistry(
            address(this),
            0
        );

        registryB = new ReferralRegistry(
            address(this),
            1
        );

        router = new CarryMockRouter();

        (
            vaultA,
            bridgeHookFacetA
        ) = _deployCarryVault(
            address(usdA),
            registryA
        );

        (
            vaultB,
            bridgeHookFacetB
        ) = _deployCarryVault(
            address(usdB),
            registryB
        );

        router.setSelector(
            address(vaultA),
            SELECTOR_A
        );

        router.setSelector(
            address(vaultB),
            SELECTOR_B
        );

        _wireBridge(
            vaultA,
            SELECTOR_B,
            address(vaultB)
        );

        _wireBridge(
            vaultB,
            SELECTOR_A,
            address(vaultA)
        );

        vaultA.finalizeSetup();
        vaultB.finalizeSetup();

        seamHarness = new CohortBridgeSeamHarness();

        flipHarness = new CohortFlipSeamHarness();

        stubHarness = new CohortBridgeOutStubHarness();

        vm.deal(
            user1,
            100 ether
        );
    }

    // ---- fixture helpers ----

    function _deployCarryVault(
        address _usd,
        ReferralRegistry _registry
    )
        internal
        returns (
            WiseSovrenNodesDiamond d,
            address bridgeHookFacet
        )
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        bridgeHookFacet = address(
            new CohortBridgeHookFacet()
        );

        _wireOne(
            d,
            bridgeHookFacet,
            WiseSovrenNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _wireOne(
            d,
            address(new CohortMoveHookFacet()),
            WiseSovrenNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            d,
            _registry
        );
    }

    function _wireBridge(
        WiseSovrenNodesDiamond _vault,
        uint64 _peerSelector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _peerSelector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _peerSelector
        );
    }

    function _armBoth()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _armSource()
        internal
    {
        AdminFacet(address(vaultA)).setCohortSyncEnabled(
            true
        );
    }

    function _armDest()
        internal
    {
        AdminFacet(address(vaultB)).setCohortSyncEnabled(
            true
        );
    }

    function _recorderOf(
        WiseSovrenNodesDiamond d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(d)
        );
    }

    function _usdOf(
        WiseSovrenNodesDiamond d
    )
        internal
        view
        returns (CarryMockUSD)
    {
        return d == vaultA
            ? usdA
            : usdB;
    }

    function _depositWithReferralOn(
        WiseSovrenNodesDiamond d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _usdOf(d).mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usdOf(d).approve(
            address(d),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _bridgeAs(
        address _user,
        WiseSovrenNodesDiamond _src,
        uint64 _destChainSelector,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _user
        );

        BridgeFacet(address(_src)).bridgeToVault{value: FEE}(
            _destChainSelector,
            _amount
        );
    }

    function _deliverCarry(
        uint256 _messageId,
        address _user,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(_messageId),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(
                _user,
                _amount,
                _referralData
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultB)).ccipReceive(
            message
        );
    }

    function _packCarry(
        address _referrer,
        uint256 _version,
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        view
        returns (bytes memory)
    {
        return _packCarryFromWeek(
            block.timestamp / 1 weeks,
            _referrer,
            _version,
            _trackedDelta,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );
    }

    function _packCarryFromWeek(
        uint256 _captureWeek,
        address _referrer,
        uint256 _version,
        uint256 _trackedDelta,
        uint256 _assignedAt,
        uint256 _rank,
        uint256 _year1,
        uint256 _year2,
        uint256 _mature
    )
        internal
        pure
        returns (bytes memory)
    {
        return BridgeCarryTestCodec._pack(
            _referrer,
            _version,
            _captureWeek,
            _trackedDelta,
            _assignedAt,
            _rank,
            _year1,
            _year2,
            _mature
        );
    }

    function _applyUnderQuarantineShape(
        uint256 _mode
    )
        internal
    {
        ShapeShiftQuarantineRegistry hostile = new ShapeShiftQuarantineRegistry(
            _mode,
            refB
        );

        seamHarness.harnessSetRegistry(
            address(hostile)
        );

        uint256 amount = 600 * 1e6;

        uint256 slot = _creditSlot();

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortQuarantineReadFailed(
            user1,
            SELECTOR_A
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            amount,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            hostile.mergeCalls(),
            0
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refB,
                slot
            )),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refB
            ),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    function _wireReferralBytes()
        internal
        view
        returns (bytes memory referralData)
    {
        (
            ,
            ,
            referralData
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );
    }

    function _landSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks + 1) % 52;
    }

    function _creditSlot()
        internal
        view
        returns (uint256)
    {
        return (block.timestamp / 1 weeks) % 52;
    }

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    // ---- 1. hostile registry answer shapes skip the carry, mutate
    // nothing, and stay retryable ----

    function test_bridgeToVault_hostileRegistryShapes_skipsCarryNothingMutated()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        bytes memory realRegistryCode = address(registryA).code;

        for (uint256 mode; mode < 5; ++mode) {

            ShapeShiftPairRegistry hostile = new ShapeShiftPairRegistry(
                mode
            );

            vm.etch(
                address(registryA),
                address(hostile).code
            );

            vm.expectEmit(
                true,
                false,
                false,
                true,
                address(vaultA)
            );

            emit CohortReferrerLookupFailed(
                user1
            );

            vm.expectEmit(
                true,
                true,
                false,
                true,
                address(vaultA)
            );

            emit CohortBridgeCarrySkipped(
                user1,
                SELECTOR_B
            );

            _bridgeAs(
                user1,
                vaultA,
                SELECTOR_B,
                SLICE
            );

            assertEq(
                _wireReferralBytes().length,
                0
            );

            assertEq(
                _recorderOf(
                    vaultA
                ).getTrackedContribution(
                    user1
                ),
                DEPOSIT
            );

            assertEq(
                _recorderOf(
                    vaultA
                ).getCohortScore(
                    refA
                ),
                DEPOSIT
            );
        }

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            5 * SLICE
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        vm.etch(
            address(registryA),
            realRegistryCode
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - 5 * SLICE
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - 5 * SLICE
        );
    }

    // ---- 2. year-2 ring lane saturation clips softly on landing ----

    function test_ccipReceive_year2LaneSaturation_clipsRingKeepsBook()
        public
    {
        _armDest();

        address fUser = address(0xF1);
        address fRef = address(0xB3);

        uint256 big = uint256(type(uint64).max) - 5;
        uint256 topUp = 100;

        uint256 slot = _creditSlot();

        bytes memory first = _packCarry(
            fRef,
            3,
            big,
            block.timestamp,
            2,
            0,
            big,
            0
        );

        bytes memory second = _packCarry(
            fRef,
            3,
            topUp,
            block.timestamp,
            2,
            0,
            topUp,
            0
        );

        _deliverCarry(
            0x740,
            fUser,
            big,
            first
        );

        (
            ,
            uint64[52] memory ring2Before
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring2Before[slot]),
            big
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultB)
        );

        emit CohortLaneSaturated(
            fRef,
            1,
            slot,
            95
        );

        _deliverCarry(
            0x741,
            fUser,
            topUp,
            second
        );

        (
            uint64[52] memory ring1After,
            uint64[52] memory ring2After
        ) = _recorderOf(vaultB).getCohortRings(
            fRef
        );

        assertEq(
            uint256(ring2After[slot]),
            uint256(type(uint64).max)
        );

        assertEq(
            uint256(ring1After[slot]),
            0
        );

        (
            ,
            uint256 year2B,
            ,
        ) = _recorderOf(vaultB).getCohortBook(
            fRef
        );

        assertEq(
            year2B,
            big + topUp
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                fUser
            ),
            big + topUp
        );
    }

    // ---- 3. armed destination without the routed bridge-in group
    // degrades to the legacy fallback ----

    function test_ccipReceive_bridgeInGroupUnrouted_fallsBackToBridgeReferral()
        public
    {
        CarryMockUSD usdC = new CarryMockUSD();

        ReferralRegistry registryC = new ReferralRegistry(
            address(this),
            2
        );

        WiseSovrenNodesDiamond vaultC = _newDiamond(
            address(usdC)
        );

        _wireAllFacets(
            vaultC
        );

        _wireOne(
            vaultC,
            address(new BridgeFacet()),
            WiseSovrenNodesDiamondSelectors._bridgeSelectors()
        );

        _wireOne(
            vaultC,
            address(new ReferralFacet()),
            WiseSovrenNodesDiamondSelectors._referralSelectors()
        );

        _wireOne(
            vaultC,
            address(new CohortRecorderFacet()),
            WiseSovrenNodesDiamondSelectors._cohortRecorderSelectors()
        );

        AdminFacet(address(vaultC)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(vaultC)).executeTransferHookFacetChange();

        _wireReferralRegistryShared(
            vaultC,
            registryC
        );

        BridgeFacet(address(vaultC)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(vaultC)).proposeCrossChainPeer(
            SELECTOR_A,
            address(vaultA),
            6
        );

        BridgeFacet(address(vaultC)).executeCrossChainPeerChange(
            SELECTOR_A
        );

        vaultC.finalizeSetup();

        AdminFacet(address(vaultC)).setCohortSyncEnabled(
            true
        );

        BridgeFacet(address(vaultC)).setReferralEnabled(
            true
        );

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp,
            0,
            amount,
            0,
            0
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0x730)),
            sourceChainSelector: SELECTOR_A,
            sender: abi.encode(address(vaultA)),
            data: abi.encode(
                user1,
                amount,
                payload
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultC)
        );

        emit BridgeReferral(
            user1,
            SELECTOR_A,
            bytes32(uint256(0x730)),
            payload
        );

        vm.prank(
            address(router)
        );

        BridgeFacet(address(vaultC)).ccipReceive(
            message
        );

        assertEq(
            vaultC.balanceOf(
                user1
            ),
            amount
        );

        assertEq(
            _recorderOf(
                vaultC
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            registryC.referrerOf(
                user1
            ),
            address(0)
        );
    }

    // ---- 4. routed bridge-in facet etched dead: hook failure event,
    // mint stands, fallback fires ----

    function test_ccipReceive_routedHookFacetReverts_hookFailedMintStands()
        public
    {
        _armDest();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp,
            0,
            amount,
            0,
            0
        );

        vm.etch(
            bridgeHookFacetB,
            REVERT_CODE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeHookFailed(
            user1,
            SELECTOR_A
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit BridgeReferral(
            user1,
            SELECTOR_A,
            bytes32(uint256(0x720)),
            payload
        );

        _deliverCarry(
            0x720,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            amount
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );
    }

    function test_ccipReceive_applyOutOfGas_revertsReceive()
        public
    {
        _armDest();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        uint256 amount = 1_000 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp,
            0,
            amount,
            0,
            0
        );

        bytes memory realCode = bridgeHookFacetB.code;

        vm.etch(
            bridgeHookFacetB,
            OOG_CODE
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                WiseSovrenNodesDiamondErrors.CohortBridgeInOutOfGas.selector,
                user1,
                SELECTOR_A
            )
        );

        _deliverCarry(
            0x729,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            address(0)
        );

        vm.etch(
            bridgeHookFacetB,
            realCode
        );

        _deliverCarry(
            0x729,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            amount
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            amount
        );

        assertEq(
            registryB.referrerOf(
                user1
            ),
            refA
        );
    }

    // ---- 5. routed flip facet etched dead: poke defers, marker
    // restored, retry succeeds after repair ----

    function test_pokeMigration_routedFlipFacetReverts_deferredMarkerRestored()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            BRIDGE_AMOUNT
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            refB
        );

        bytes memory realHookCode = bridgeHookFacetB.code;

        vm.etch(
            bridgeHookFacetB,
            REVERT_CODE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registryB)
        );

        emit FlipMigrationDeferred(
            address(vaultB),
            user1,
            refB,
            refA
        );

        registryB.pokeMigration(
            user1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            refB
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refB
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        vm.etch(
            bridgeHookFacetB,
            realHookCode
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registryB)
        );

        emit FlipMigrated(
            address(vaultB),
            user1,
            refB,
            refA
        );

        registryB.pokeMigration(
            user1
        );

        assertEq(
            registryB.pendingFlip(
                address(vaultB),
                user1
            ),
            address(0)
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            0
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            DEPOSIT_B + BRIDGE_AMOUNT
        );
    }

    // ---- 6. transfer hook uninstalled while armed: sync pokes become
    // silent no-ops, funds keep moving ----

    function test_syncReferee_hookUninstalledWhileArmed_noOpKeepsTracked()
        public
    {
        _armSource();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 3 days + 1
        );

        vm.store(
            address(vaultA),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(0)
        );

        vm.prank(
            user1
        );

        vaultA.transfer(
            buyer,
            1_000 * 1e6
        );

        _recorderOf(vaultA).syncReferee(
            user1
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT - 1_000 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT
        );
    }

    // ---- 7. lower-decimal peer floors every carried component on the
    // source-side wire ----

    function test_bridgeToVault_lowerDecimalPeer_flooredCarryPayload()
        public
    {
        BridgeFacet(address(vaultA)).proposeCrossChainPeer(
            SELECTOR_LOW,
            address(0xFEED),
            4
        );

        vm.warp(
            block.timestamp + 3 days + 1
        );

        BridgeFacet(address(vaultA)).executeCrossChainPeerChange(
            SELECTOR_LOW
        );

        _armSource();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 assignedAt = block.timestamp;

        uint256 burnAmount = 2_000 * 1e6 + 33;

        uint256 scaledDelta = burnAmount / 100;

        router.setRelayEnabled(
            false
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_LOW,
            refA,
            scaledDelta,
            scaledDelta,
            0,
            0,
            refA
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_LOW,
            burnAmount
        );

        (
            address wireUser,
            uint256 wireAmount,
            bytes memory wireRef
        ) = abi.decode(
            router.lastData(),
            (address, uint256, bytes)
        );

        assertEq(
            wireUser,
            user1
        );

        assertEq(
            wireAmount,
            scaledDelta
        );

        assertEq(
            wireRef.length,
            128
        );

        (
            uint256 word0,
            uint256 word1,
            uint256 word2,
            uint256 word3
        ) = abi.decode(
            wireRef,
            (uint256, uint256, uint256, uint256)
        );

        assertEq(
            address(uint160(word0)),
            refA
        );

        assertEq(
            (word0 >> 160) & 0xff,
            3
        );

        assertEq(
            CohortWeeks._bridgeCarryPairCount(
                word0
            ),
            1
        );

        assertEq(
            word1 & ((uint256(1) << 128) - 1),
            scaledDelta
        );

        assertEq(
            (word1 >> 128) & type(uint64).max,
            assignedAt
        );

        assertEq(
            CohortWeeks._carryPairAmount(
                CohortWeeks._carryPairLo(
                    word3
                )
            ),
            scaledDelta
        );

        assertEq(
            CohortWeeks._carryPairHi(
                word3
            ),
            0
        );

        assertEq(
            word2,
            0
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT - burnAmount
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT - burnAmount
        );
    }

    // ---- 8. direct external calls to the routed engine entrypoints
    // always revert ----

    function test_applyCohortFlip_directCall_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortBridgeHookFacet(address(vaultA)).applyCohortFlip(
            user1,
            refA,
            refB
        );
    }

    function test_applyCohortBridgeOut_directCall_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortBridgeHookFacet(address(vaultA)).applyCohortBridgeOut(
            user1,
            SELECTOR_B,
            SLICE,
            1,
            1
        );
    }

    function test_applyCohortBridgeIn_directCall_reverts()
        public
    {
        vm.prank(
            user1
        );

        vm.expectRevert(
            WiseSovrenNodesDiamondErrors.NotHookExecution.selector
        );

        CohortBridgeHookFacet(address(vaultA)).applyCohortBridgeIn(
            user1,
            SELECTOR_A,
            SLICE,
            ""
        );
    }

    // ---- 9. capture with an unset registry pointer: a failed lookup,
    // clamp deferred, carry skipped, nothing staged ----

    function test_captureBridgeOut_registryUnset_defersClampAndSkips()
        public
    {
        seamHarness.harnessMintBalance(
            user1,
            300 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            800 * 1e6
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(seamHarness)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarrySkipped(
            user1,
            SELECTOR_B
        );

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500 * 1e6,
            1,
            1
        );

        assertEq(
            payload.length,
            0
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            800 * 1e6
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            800 * 1e6
        );
    }

    function test_captureBridgeOut_registryUnset_reportsOneLookupFailure()
        public
    {
        seamHarness.harnessMintBalance(
            user1,
            300 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            800 * 1e6
        );

        vm.recordLogs();

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500 * 1e6,
            1,
            1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            payload.length,
            0
        );

        assertEq(
            _countTopic(
                logs,
                keccak256(
                    "CohortReferrerLookupFailed(address)"
                )
            ),
            1
        );

        assertEq(
            _countTopic(
                logs,
                keccak256(
                    "CohortBridgeCarrySkipped(address,uint64)"
                )
            ),
            1
        );
    }

    // ---- 10. a deficit whose scaled envelope collapses to zero
    // suppresses the wire after the clamp ----

    function test_captureBridgeOut_deficitScalesToZero_returnsEmptyAfterClamp()
        public
    {
        ReferralRegistry seamRegistry = new ReferralRegistry(
            address(this),
            0
        );

        seamRegistry.setAllowedVault(
            address(this),
            true
        );

        seamRegistry.assignReferrer(
            user1,
            refA
        );

        seamHarness.harnessSetRegistry(
            address(seamRegistry)
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            1_000 * 1e6 + 500
        );

        seamHarness.harnessSetBookLanes(
            refA,
            0,
            0,
            500
        );

        vm.recordLogs();

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500,
            1,
            1e30
        );

        assertEq(
            payload.length,
            0
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            _countTopic(
                vm.getRecordedLogs(),
                SENT_TOPIC
            ),
            0
        );
    }

    function test_captureBridgeOut_partiallyAttributed_chargesSaleLikeFirstThenCarriesTheRest()
        public
    {
        ReferralRegistry seamRegistry = new ReferralRegistry(
            address(this),
            0
        );

        seamRegistry.setAllowedVault(
            address(this),
            true
        );

        seamRegistry.assignReferrer(
            user1,
            refA
        );

        seamHarness.harnessSetRegistry(
            address(seamRegistry)
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            1_000 * 1e6 + 800
        );

        seamHarness.harnessSetAttributed(
            user1,
            600
        );

        seamHarness.harnessSetBookLanes(
            refA,
            300,
            0,
            500
        );

        seamHarness.harnessSetRingYear1(
            refA,
            (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS,
            300
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortAttributionCharged(
            user1,
            refA,
            600,
            200
        );

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500,
            1,
            1
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            0
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                0,
                0,
                200
            )
        );

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            payload
        );

        uint256 word1 = words[1];

        uint256 word3 = words[2];

        (
            uint256 pairYear1,
            uint256 pairYear2
        ) = CohortWeeks._carryPairSums(
            words,
            3,
            CohortWeeks._bridgeCarryPairCount(
                words[0]
            )
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                word1
            ),
            500
        );

        assertEq(
            pairYear1,
            0
        );

        assertEq(
            pairYear2,
            0
        );

        assertEq(
            word3,
            300
        );

        assertTrue(
            CohortWeeks._bridgeCarryValid(
                payload,
                500
            )
        );
    }

    function test_captureBridgeOut_excessDeficitReducesSaleLikeFirst()
        public
    {
        ReferralRegistry seamRegistry = new ReferralRegistry(
            address(this),
            0
        );

        seamRegistry.setAllowedVault(
            address(this),
            true
        );

        seamRegistry.assignReferrer(
            user1,
            refA
        );

        seamHarness.harnessSetRegistry(
            address(seamRegistry)
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            1_000 * 1e6 + 800
        );

        seamHarness.harnessSetBookLanes(
            refA,
            300,
            0,
            500
        );

        seamHarness.harnessSetRingYear1(
            refA,
            (block.timestamp / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS,
            300
        );

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500,
            1,
            1
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            payload.length,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES
        );

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            payload
        );

        uint256 word1 = words[1];

        uint256 word3 = words[2];

        (
            uint256 pairYear1,
            uint256 pairYear2
        ) = CohortWeeks._carryPairSums(
            words,
            3,
            CohortWeeks._bridgeCarryPairCount(
                words[0]
            )
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                word1
            ),
            500
        );

        assertEq(
            pairYear1,
            0
        );

        assertEq(
            word3,
            500
        );
    }

    function test_applyBridgeIn_trackedGrowsByCarriedDeltaNotMint()
        public
    {
        uint256 carried = 400 * 1e6;

        seamHarness.harnessMintBalance(
            user1,
            carried + 111 * 1e6
        );

        bytes memory payload = _packCarry(
            address(0),
            3,
            carried,
            block.timestamp,
            0,
            0,
            0,
            0
        );

        uint256 before = seamHarness.viewTracked(
            user1
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_B,
            carried + 111 * 1e6,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            seamHarness.viewTracked(user1) - before,
            carried
        );
    }

    // ---- 11. apply with an unset registry pointer: tracked applied,
    // book lanes dropped ----

    function test_applyBridgeIn_registryUnset_bookDroppedTrackedApplied()
        public
    {
        uint256 amount = 700 * 1e6;

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp,
            3,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryBookDropped(
            user1,
            SELECTOR_A,
            refA,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    // ---- 12. a rejected merge is swallowed and the lanes land under
    // the local answer ----

    function test_applyBridgeIn_mergeReverts_lanesLandUnderLocalAnswer()
        public
    {
        MergeRevertRegistry hostile = new MergeRevertRegistry(
            refB
        );

        seamHarness.harnessSetRegistry(
            address(hostile)
        );

        uint256 amount = 600 * 1e6;

        uint256 slot = _creditSlot();

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            amount,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refB,
                slot
            )),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refB
            ),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    // ---- 13. merge succeeds but the post-merge lookup reverts:
    // tracked applied, book lanes dropped ----

    function test_applyBridgeIn_postMergeLookupReverts_bookDropped()
        public
    {
        LookupRevertRegistry hostile = new LookupRevertRegistry();

        seamHarness.harnessSetRegistry(
            address(hostile)
        );

        uint256 amount = 500 * 1e6;

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(seamHarness)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryBookDropped(
            user1,
            SELECTOR_A,
            refA,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            hostile.mergeCalls(),
            1
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    // ---- 14. flip migration no-op arms ----

    function test_migrateReferrerCohort_noOpArms_emitNothing()
        public
    {
        flipHarness.harnessMintBalance(
            user1,
            100 * 1e6
        );

        flipHarness.harnessSetTracked(
            user1,
            100 * 1e6
        );

        vm.recordLogs();

        flipHarness.exposedMigrateReferrer(
            user1,
            address(0),
            refB
        );

        flipHarness.exposedMigrateReferrer(
            user1,
            refA,
            refA
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            logs.length,
            0
        );

        assertEq(
            flipHarness.viewTracked(
                user1
            ),
            100 * 1e6
        );
    }

    // ---- 15. flip migration destroys a lazy deficit sale-like before
    // relocating the residual ----

    function test_migrateReferrerCohort_partiallyAttributed_chargesAndRelocatesAttributedOnly()
        public
    {
        uint256 slot = _creditSlot();

        flipHarness.harnessMintBalance(
            user1,
            300 * 1e6
        );

        flipHarness.harnessSetTracked(
            user1,
            500 * 1e6
        );

        flipHarness.harnessSetAttributed(
            user1,
            250 * 1e6
        );

        flipHarness.harnessSetRingYear1(
            refA,
            slot,
            uint64(500 * 1e6)
        );

        flipHarness.harnessSetBookLanes(
            refA,
            500 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(flipHarness)
        );

        emit CohortAttributionCharged(
            user1,
            refA,
            200 * 1e6,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(flipHarness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            50 * 1e6,
            0,
            0,
            1
        );

        flipHarness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        assertEq(
            flipHarness.viewTracked(
                user1
            ),
            300 * 1e6
        );

        assertEq(
            flipHarness.viewAttributed(
                user1
            ),
            50 * 1e6
        );

        assertEq(
            flipHarness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                250 * 1e6,
                0,
                0
            )
        );

        assertEq(
            flipHarness.viewBookWord(
                refB
            ),
            CohortWeeks._packLanes(
                50 * 1e6,
                0,
                0
            )
        );
    }

    function test_migrateReferrerCohort_deficitClampsSaleLikeThenMigratesResidual()
        public
    {
        uint256 slot = _creditSlot();

        flipHarness.harnessMintBalance(
            user1,
            300 * 1e6
        );

        flipHarness.harnessSetTracked(
            user1,
            500 * 1e6
        );

        flipHarness.harnessSetRingYear1(
            refA,
            slot,
            uint64(500 * 1e6)
        );

        flipHarness.harnessSetBookLanes(
            refA,
            500 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(flipHarness)
        );

        emit CohortContributionSynced(
            user1,
            refA,
            500 * 1e6,
            300 * 1e6
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(flipHarness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            300 * 1e6,
            0,
            0,
            1
        );

        flipHarness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        assertEq(
            flipHarness.viewTracked(
                user1
            ),
            300 * 1e6
        );

        assertEq(
            flipHarness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            uint256(flipHarness.viewRingYear1(
                refA,
                slot
            )),
            0
        );

        assertEq(
            flipHarness.viewBookWord(
                refB
            ),
            300 * 1e6
        );

        assertEq(
            uint256(flipHarness.viewRingYear1(
                refB,
                slot
            )),
            300 * 1e6
        );

        assertEq(
            uint256(flipHarness.viewRingYear1(
                refB,
                _landSlot()
            )),
            0
        );
    }

    // ---- 16. flip migration onto a saturated destination ring clips
    // softly, book keeps the full amount ----

    function test_migrateReferrerCohort_saturatedDestinationRing_clipsSoftly()
        public
    {
        uint256 slot = _creditSlot();

        flipHarness.harnessMintBalance(
            user1,
            400
        );

        flipHarness.harnessSetTracked(
            user1,
            400
        );

        flipHarness.harnessSetRingYear1(
            refA,
            slot,
            400
        );

        flipHarness.harnessSetBookLanes(
            refA,
            400,
            0,
            0
        );

        flipHarness.harnessSetRingYear1(
            refB,
            slot,
            type(uint64).max - 5
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(flipHarness)
        );

        emit CohortLaneSaturated(
            refB,
            0,
            slot,
            395
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(flipHarness)
        );

        emit CohortReferrerFlipApplied(
            user1,
            refA,
            refB,
            400,
            0,
            0,
            1
        );

        flipHarness.exposedMigrateReferrer(
            user1,
            refA,
            refB
        );

        assertEq(
            uint256(flipHarness.viewRingYear1(
                refB,
                slot
            )),
            uint256(type(uint64).max)
        );

        assertEq(
            flipHarness.viewBookWord(
                refB
            ),
            400
        );

        assertEq(
            flipHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    // ---- 17. the bridge-out stub short-circuits while disarmed ----

    function test_cohortBridgeOut_syncDisabled_returnsEmpty()
        public
    {
        vm.recordLogs();

        bytes memory payload = stubHarness.exposedCohortBridgeOut(
            user1,
            SELECTOR_B,
            SLICE,
            1,
            1
        );

        assertEq(
            payload.length,
            0
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );
    }

    // ---- 18. a scaled-down capture over three lanes floors each lane
    // on its own and lands strictly under the mint ----

    function test_captureBridgeOut_scaleDownMultiLane_floorsPerLaneAndLandsUnderMint()
        public
    {
        ReferralRegistry seamRegistry = new ReferralRegistry(
            address(this),
            0
        );

        seamRegistry.setAllowedVault(
            address(this),
            true
        );

        seamRegistry.assignReferrer(
            user1,
            refA
        );

        seamHarness.harnessSetRegistry(
            address(seamRegistry)
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            1_000 * 1e6 + 750
        );

        seamHarness.harnessSetBookLanes(
            refA,
            150,
            250,
            350
        );

        uint256 slot = _creditSlot();

        seamHarness.harnessSetRingYear1(
            refA,
            slot,
            150
        );

        seamHarness.harnessSetRingYear2(
            refA,
            slot,
            250
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarrySent(
            user1,
            SELECTOR_LOW,
            refA,
            7,
            1,
            2,
            3,
            refA
        );

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_LOW,
            750,
            1,
            100
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refA,
                slot
            )),
            0
        );

        assertEq(
            uint256(seamHarness.viewRingYear2(
                refA,
                slot
            )),
            0
        );

        assertEq(
            payload.length,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES + 32
        );

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            payload
        );

        uint256 word1 = words[1];

        uint256 word3 = words[2];

        (
            uint256 pairYear1,
            uint256 pairYear2
        ) = CohortWeeks._carryPairSums(
            words,
            3,
            CohortWeeks._bridgeCarryPairCount(
                words[0]
            )
        );

        assertEq(
            CohortWeeks._carryTrackedDelta(
                word1
            ),
            7
        );

        assertEq(
            pairYear1,
            1
        );

        assertEq(
            pairYear2,
            2
        );

        assertEq(
            word3,
            3
        );

        assertTrue(
            CohortWeeks._bridgeCarryValid(
                payload,
                7
            )
        );

        assertFalse(
            CohortWeeks._bridgeCarryValid(
                payload,
                5
            )
        );

        CohortBridgeSeamHarness dest = new CohortBridgeSeamHarness();

        ReferralRegistry destRegistry = new ReferralRegistry(
            address(this),
            1
        );

        destRegistry.setAllowedVault(
            address(dest),
            true
        );

        dest.harnessSetRegistry(
            address(destRegistry)
        );

        dest.harnessMintBalance(
            user1,
            7
        );

        uint256 landSlot = slot;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(dest)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            7,
            1,
            2,
            3
        );

        bool applied = dest.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            7,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            dest.viewTracked(
                user1
            ),
            7
        );

        assertLe(
            dest.viewTracked(
                user1
            ),
            7
        );

        assertEq(
            dest.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                1,
                2,
                3
            )
        );

        assertEq(
            uint256(dest.viewRingYear1(
                refA,
                landSlot
            )),
            1
        );

        assertEq(
            uint256(dest.viewRingYear2(
                refA,
                landSlot
            )),
            2
        );

        assertEq(
            destRegistry.referrerOf(
                user1
            ),
            refA
        );
    }

    // ---- 19. a registry pointer cleared while armed reads as a failed
    // lookup: the bridge-out carry is skipped and the clamp deferred ----

    function test_bridgeOut_zeroRegistryPointerWhileArmed_skipsCarryWithoutClamp()
        public
    {
        _armBoth();

        _depositWithReferralOn(
            vaultA,
            user1,
            DEPOSIT,
            refA
        );

        uint256 attributedBefore = _recorderOf(vaultA).getAttributedContribution(
            user1
        );

        vm.store(
            address(vaultA),
            bytes32(REFERRAL_REGISTRY_SLOT),
            bytes32(0)
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(vaultA)
        );

        emit CohortReferrerLookupFailed(
            user1
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultA)
        );

        emit CohortBridgeCarrySkipped(
            user1,
            SELECTOR_B
        );

        _bridgeAs(
            user1,
            vaultA,
            SELECTOR_B,
            SLICE
        );

        assertEq(
            _wireReferralBytes().length,
            0
        );

        assertEq(
            vaultA.balanceOf(
                user1
            ),
            DEPOSIT - SLICE
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            SLICE
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getAttributedContribution(
                user1
            ),
            attributedBefore
        );

        assertEq(
            _recorderOf(
                vaultA
            ).getCohortScore(
                refA
            ),
            DEPOSIT
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            0
        );
    }

    // ---- 20. capture stamps the capture week and codec version 2 on
    // the envelope word ----

    function test_captureBridgeOut_stampsCaptureWeekAndVersionThree()
        public
    {
        ReferralRegistry seamRegistry = new ReferralRegistry(
            address(this),
            0
        );

        seamRegistry.setAllowedVault(
            address(this),
            true
        );

        seamRegistry.assignReferrer(
            user1,
            refA
        );

        seamHarness.harnessSetRegistry(
            address(seamRegistry)
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        seamHarness.harnessSetTracked(
            user1,
            1_000 * 1e6 + 500
        );

        seamHarness.harnessSetBookLanes(
            refA,
            0,
            0,
            500
        );

        bytes memory payload = seamHarness.exposedCaptureBridgeOut(
            user1,
            SELECTOR_B,
            500,
            1,
            1
        );

        assertEq(
            payload.length,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES
        );

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            payload
        );

        uint256 word0 = words[0];

        uint256 word3 = words[2];

        assertEq(
            CohortWeeks._carryEnvelopeReferrer(
                word0
            ),
            refA
        );

        assertEq(
            CohortWeeks._carryEnvelopeVersion(
                word0
            ),
            3
        );

        assertEq(
            CohortWeeks._bridgeCarryCaptureWeek(
                word0
            ),
            block.timestamp / 1 weeks
        );

        assertEq(
            CohortWeeks._bridgeCarryCaptureWeek(
                word0
            ),
            3_000
        );

        assertEq(
            word0 >> 208,
            0
        );

        assertEq(
            word3,
            500
        );

        assertTrue(
            CohortWeeks._bridgeCarryValid(
                payload,
                500
            )
        );
    }

    // ---- 21. the carried capture week against the arrival clock ----

    function test_applyBridgeIn_captureWeekInTheFuture_landsWithoutDrift()
        public
    {
        ReferralRegistry destRegistry = new ReferralRegistry(
            address(this),
            1
        );

        destRegistry.setAllowedVault(
            address(seamHarness),
            true
        );

        seamHarness.harnessSetRegistry(
            address(destRegistry)
        );

        uint256 amount = 400 * 1e6;

        uint256 slot = _creditSlot();

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarryFromWeek(
            block.timestamp / 1 weeks + 5,
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            amount,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refA,
                slot
            )),
            amount
        );

        assertEq(
            uint256(seamHarness.viewRingYear2(
                refA,
                slot
            )),
            0
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                amount,
                0,
                0
            )
        );

        assertEq(
            destRegistry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_applyBridgeIn_oneBoundaryInFlight_year1KeepsItsSlot()
        public
    {
        ReferralRegistry destRegistry = new ReferralRegistry(
            address(this),
            1
        );

        destRegistry.setAllowedVault(
            address(seamHarness),
            true
        );

        seamHarness.harnessSetRegistry(
            address(destRegistry)
        );

        uint256 amount = 400 * 1e6;

        uint256 slot = (block.timestamp / 1 weeks - 1) % 52;

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarryFromWeek(
            block.timestamp / 1 weeks - 1,
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refA,
            refA,
            amount,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refA,
                slot
            )),
            amount
        );

        for (uint256 i; i < 52; ++i) {
            assertEq(
                uint256(seamHarness.viewRingYear2(
                    refA,
                    i
                )),
                0
            );
        }

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                amount,
                0,
                0
            )
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            amount
        );
    }

    function test_applyBridgeIn_registryUnset_bookDroppedReportsUnagedLanes()
        public
    {
        uint256 amount = 300 * 1e6;

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarryFromWeek(
            block.timestamp / 1 weeks - 1,
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            3,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryBookDropped(
            user1,
            SELECTOR_A,
            refA,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            0
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    // ---- 22. the quarantine read before the merge: a braked source
    // chain or an unreadable answer skips the merge, the lanes land
    // under the local answer ----

    function test_applyBridgeIn_sourceNotQuarantined_mergeAttempted()
        public
    {
        QuarantineRegistry registry = new QuarantineRegistry(
            refB
        );

        registry.setQuarantined(
            SELECTOR_B,
            true
        );

        seamHarness.harnessSetRegistry(
            address(registry)
        );

        uint256 amount = 600 * 1e6;

        uint256 slot = _creditSlot();

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        assertFalse(
            registry.syncPeerQuarantined(
                SELECTOR_A
            )
        );

        assertEq(
            registry.mergeCalls(),
            1
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refB,
                slot
            )),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refB
            ),
            amount
        );
    }

    function test_applyBridgeIn_sourceQuarantined_mergeSkippedLanesLandLocally()
        public
    {
        QuarantineRegistry registry = new QuarantineRegistry(
            refB
        );

        registry.setQuarantined(
            SELECTOR_A,
            true
        );

        seamHarness.harnessSetRegistry(
            address(registry)
        );

        uint256 amount = 600 * 1e6;

        uint256 slot = _creditSlot();

        seamHarness.harnessMintBalance(
            user1,
            amount
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp - 1 days,
            0,
            amount,
            0,
            0
        );

        vm.recordLogs();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryApplied(
            user1,
            SELECTOR_A,
            refB,
            refA,
            amount,
            amount,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            amount,
            payload
        );

        assertTrue(
            applied
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                keccak256(
                    "CohortReferrerLookupFailed(address)"
                )
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                keccak256(
                    "CohortQuarantineReadFailed(address,uint64)"
                )
            ),
            0
        );

        assertEq(
            registry.mergeCalls(),
            0
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            amount
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refB,
                slot
            )),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refB
            ),
            amount
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_applyBridgeIn_quarantineReadWrongSize_skipsMergeAndReportsReadFailure()
        public
    {
        _applyUnderQuarantineShape(
            0
        );
    }

    function test_applyBridgeIn_quarantineReadDirtyWord_skipsMergeAndReportsReadFailure()
        public
    {
        _applyUnderQuarantineShape(
            1
        );
    }

    function test_applyBridgeIn_quarantineReadReverts_skipsMergeAndReportsReadFailure()
        public
    {
        _applyUnderQuarantineShape(
            2
        );
    }

    // ---- 23. the post-mint headroom ceiling discards a carry that
    // would lift tracked above the balance held ----

    function test_applyBridgeIn_carriedDeltaAboveHeadroom_discardedWholesale()
        public
    {
        QuarantineRegistry registry = new QuarantineRegistry(
            refA
        );

        seamHarness.harnessSetRegistry(
            address(registry)
        );

        seamHarness.harnessSetTracked(
            user1,
            900 * 1e6
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        bytes memory payload = _packCarry(
            refA,
            3,
            200 * 1e6,
            block.timestamp - 1 days,
            0,
            200 * 1e6,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            200 * 1e6,
            payload
        );

        assertFalse(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            900 * 1e6
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            900 * 1e6
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            0
        );

        assertEq(
            registry.mergeCalls(),
            0
        );
    }

    function test_applyBridgeIn_carriedDeltaAtHeadroom_applies()
        public
    {
        QuarantineRegistry registry = new QuarantineRegistry(
            refA
        );

        seamHarness.harnessSetRegistry(
            address(registry)
        );

        seamHarness.harnessSetTracked(
            user1,
            900 * 1e6
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        uint256 slot = _creditSlot();

        bytes memory payload = _packCarry(
            refA,
            3,
            100 * 1e6,
            block.timestamp - 1 days,
            0,
            100 * 1e6,
            0,
            0
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            100 * 1e6,
            payload
        );

        assertTrue(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewAttributed(
                user1
            ),
            1_000 * 1e6
        );

        assertEq(
            seamHarness.viewBookWord(
                refA
            ),
            CohortWeeks._packLanes(
                100 * 1e6,
                0,
                0
            )
        );

        assertEq(
            uint256(seamHarness.viewRingYear1(
                refA,
                slot
            )),
            100 * 1e6
        );

        assertEq(
            registry.mergeCalls(),
            1
        );
    }

    function test_applyBridgeIn_unreferredDeltaAboveHeadroom_discardedWholesale()
        public
    {
        seamHarness.harnessSetTracked(
            user1,
            900 * 1e6
        );

        seamHarness.harnessMintBalance(
            user1,
            1_000 * 1e6
        );

        bytes memory payload = _packCarry(
            address(0),
            3,
            200 * 1e6,
            block.timestamp - 1 days,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(seamHarness)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        bool applied = seamHarness.exposedApplyBridgeIn(
            user1,
            SELECTOR_A,
            200 * 1e6,
            payload
        );

        assertFalse(
            applied
        );

        assertEq(
            seamHarness.viewTracked(
                user1
            ),
            900 * 1e6
        );
    }

    function test_ccipReceive_holderAboveHeld_carryDiscardedMintStands()
        public
    {
        _armDest();

        BridgeFacet(address(vaultB)).setReferralEnabled(
            true
        );

        _depositWithReferralOn(
            vaultB,
            user1,
            DEPOSIT_B,
            refB
        );

        vm.warp(
            block.timestamp + 3 days + 1
        );

        vm.store(
            address(vaultB),
            bytes32(TRANSFER_HOOK_SLOT),
            bytes32(0)
        );

        vm.prank(
            user1
        );

        vaultB.transfer(
            buyer,
            400 * 1e6
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT_B
        );

        uint256 amount = 300 * 1e6;

        bytes memory payload = _packCarry(
            refA,
            3,
            amount,
            block.timestamp,
            0,
            amount,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(vaultB)
        );

        emit CohortBridgeCarryDiscarded(
            user1,
            SELECTOR_A
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(vaultB)
        );

        emit BridgeReferral(
            user1,
            SELECTOR_A,
            bytes32(uint256(0x750)),
            payload
        );

        _deliverCarry(
            0x750,
            user1,
            amount,
            payload
        );

        assertEq(
            vaultB.balanceOf(
                user1
            ),
            DEPOSIT_B - 400 * 1e6 + amount
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getTrackedContribution(
                user1
            ),
            DEPOSIT_B
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refB
            ),
            DEPOSIT_B
        );

        assertEq(
            _recorderOf(
                vaultB
            ).getCohortScore(
                refA
            ),
            0
        );

        assertEq(
            registryB.effectiveReferrerOf(
                user1,
                address(vaultB)
            ),
            refB
        );
    }
}
