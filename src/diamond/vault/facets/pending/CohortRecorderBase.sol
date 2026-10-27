// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortMoveCarryBase} from "./CohortMoveCarryBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortRecorderBase: the bridge carry and the referrer flip, the top
 * of the cohort engine inherited by the hook, move and bridge facets. A
 * bridge out debits the book the local seam names, captures the taken ring
 * slots as pairs and packs them with the mature amount and the referrer's
 * origin sync key. A bridge in validates the payload wholesale and lands
 * every pair at its own slot, aged by the boundaries crossed in flight,
 * under the local registry's answer, never the carried name. A flip
 * resolves a parked user at its park instant, settles the old book and
 * replants the attributed slice's pairs at their own slots in the new
 * referrer's rings.
 */
abstract contract CohortRecorderBase is CohortMoveCarryBase {

    modifier onlyHookExecution() {
        require(
            hookExecuting,
            NotHookExecution()
        );
        _;
    }

    struct BridgeCarryStage {
        address referrer;
        uint256 assignedAt;
        uint256 rank;
        uint256 year1;
        uint256 year2;
        uint256 mature;
        uint256 trackedDelta;
        uint256 captureWeek;
        uint256 pairCount;
        uint256[] pairs;
    }

    function _cohortReferrerPairOf(
        address _user
    )
        internal
        returns (
            bool,
            address,
            uint256,
            uint256
        )
    {
        address registry = referralRegistry;

        bytes4 selector = IReferralRegistry.getReferrerPair.selector;

        bool success;

        uint256 word0;

        uint256 word1;

        uint256 word2;

        if (registry != ZERO_ADDRESS) {
            (
                success,
                word0,
                word1,
                word2
            ) = _staticWordsCohort(
                registry,
                selector,
                uint256(uint160(_user)),
                0,
                0x24,
                3
            );
        }

        if (
            success == false
                || word0 > type(uint160).max
                || word1 > CohortWeeks.RING_LANE_MAX
                || word2 > CohortWeeks.CARRY_BYTE_MASK
        ) {

            emit CohortReferrerLookupFailed(
                _user
            );

            return (
                false,
                ZERO_ADDRESS,
                0,
                0
            );
        }

        return (
            true,
            address(uint160(word0)),
            word1,
            word2
        );
    }

    function _mergeReferrerGuarded(
        address _registry,
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        internal
        returns (bool)
    {
        try IReferralRegistry(_registry).mergeReferrer(
            _user,
            _referrer,
            _assignedAt,
            _rank
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _cohortSourceQuarantined(
        address _registry,
        address _user,
        uint64 _srcChainSelector
    )
        internal
        returns (bool)
    {
        (
            bool success,
            uint256 word
        ) = _staticWordCohort(
            _registry,
            IReferralRegistry.syncPeerQuarantined.selector,
            uint256(_srcChainSelector),
            0,
            0x24
        );

        if (success == false || word > 1) {

            emit CohortQuarantineReadFailed(
                _user,
                _srcChainSelector
            );

            return true;
        }

        return word == 1;
    }

    function _captureBridgeOutCohort(
        address _user,
        uint64 _dstChainSelector,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
        returns (bytes memory)
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return "";
        }

        BridgeCarryStage memory stage;

        address bookReferrer;

        {
            bool pairOk;
            bool effectiveOk;

            (
                pairOk,
                stage.referrer,
                stage.assignedAt,
                stage.rank
            ) = _cohortReferrerPairOf(
                _user
            );

            if (pairOk == true) {
                (
                    effectiveOk,
                    bookReferrer
                ) = _cohortReferrerOf(
                    _user
                );
            }

            if (pairOk == false || effectiveOk == false) {

                emit CohortBridgeCarrySkipped(
                    _user,
                    _dstChainSelector
                );

                return "";
            }
        }

        ClampSplit memory split = _clampForCarryCohort(
            _user,
            bookReferrer,
            tracked - held,
            _burnedAmount
        );

        if (bookReferrer != ZERO_ADDRESS && split.carryCharge > 0) {
            (
                stage.pairs,
                stage.pairCount,
                ,
                ,
                stage.mature
            ) = _reduceBookCohortCaptured(
                bookReferrer,
                split.carryCharge
            );
        }

        if (stage.referrer == ZERO_ADDRESS) {
            stage.pairCount = 0;
            stage.mature = 0;
        }

        _settleSelfCohort(
            _user,
            block.timestamp
        );

        trackedContribution[_user] = held;

        emit CohortContributionSynced(
            _user,
            bookReferrer,
            tracked,
            held
        );

        (
            stage.year1,
            stage.year2
        ) = _scaleCarryPairsCohort(
            stage.pairs,
            stage.pairCount,
            _scaleNumerator,
            _scaleDenominator
        );

        stage.mature = _scaleCarryAmount(
            stage.mature,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        stage.trackedDelta = _scaleCarryAmount(
            split.carryDelta,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.CARRY_HALF_MASK
        );

        if (stage.trackedDelta == 0) {
            return "";
        }

        emit CohortBridgeCarrySent(
            _user,
            _dstChainSelector,
            stage.referrer,
            stage.trackedDelta,
            stage.year1,
            stage.year2,
            stage.mature,
            bookReferrer
        );

        uint256[] memory words = _packPairWordsCohort(
            CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
            stage.pairs,
            stage.pairCount
        );

        words[0] = CohortWeeks._packBridgeCarryEnvelope(
            stage.referrer,
            block.timestamp / CohortWeeks.WEEK,
            stage.pairCount
        );

        words[1] = CohortWeeks._packBridgeCarryTracked(
            stage.trackedDelta,
            stage.assignedAt,
            stage.rank
        );

        words[2] = stage.mature;

        return CohortWeeks._packBridgeCarry(
            words
        );
    }

    function _applyBridgeInCohort(
        address _user,
        uint64 _srcChainSelector,
        uint256 _mintedAmount,
        bytes memory _payload
    )
        internal
        returns (bool)
    {
        if (
            CohortWeeks._bridgeCarryValid(
                _payload,
                _mintedAmount
            ) == false
        ) {

            emit CohortBridgeCarryDiscarded(
                _user,
                _srcChainSelector
            );

            return false;
        }

        BridgeCarryStage memory stage;

        uint256[] memory words = CohortWeeks._unpackBridgeCarry(
            _payload
        );

        stage.referrer = CohortWeeks._carryEnvelopeReferrer(
            words[0]
        );

        stage.captureWeek = CohortWeeks._bridgeCarryCaptureWeek(
            words[0]
        );

        stage.pairCount = CohortWeeks._bridgeCarryPairCount(
            words[0]
        );

        stage.trackedDelta = CohortWeeks._carryTrackedDelta(
            words[1]
        );

        stage.assignedAt = CohortWeeks._bridgeCarryAssignedAt(
            words[1]
        );

        stage.rank = CohortWeeks._bridgeCarryRank(
            words[1]
        );

        stage.mature = words[2];

        if (
            trackedContribution[_user] + stage.trackedDelta > balanceOf(
                _user
            )
        ) {

            emit CohortBridgeCarryDiscarded(
                _user,
                _srcChainSelector
            );

            return false;
        }

        _settleSelfCohort(
            _user,
            block.timestamp
        );

        trackedContribution[_user] += stage.trackedDelta;

        if (stage.referrer == ZERO_ADDRESS) {

            emit CohortBridgeCarryApplied(
                _user,
                _srcChainSelector,
                ZERO_ADDRESS,
                ZERO_ADDRESS,
                stage.trackedDelta,
                0,
                0,
                0
            );

            return true;
        }

        address registry = referralRegistry;

        bool lookupOk;

        address effectiveReferrer;

        if (registry != ZERO_ADDRESS) {

            if (
                _cohortSourceQuarantined(
                    registry,
                    _user,
                    _srcChainSelector
                ) == false
            ) {
                _mergeReferrerGuarded(
                    registry,
                    _user,
                    stage.referrer,
                    stage.assignedAt,
                    stage.rank
                );
            }

            (
                lookupOk,
                effectiveReferrer
            ) = _cohortReferrerOf(
                _user
            );
        }

        if (lookupOk == false || effectiveReferrer == ZERO_ADDRESS) {

            (
                stage.year1,
                stage.year2
            ) = CohortWeeks._carryPairSums(
                words,
                CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
                stage.pairCount
            );

            emit CohortBridgeCarryBookDropped(
                _user,
                _srcChainSelector,
                stage.referrer,
                stage.year1,
                stage.year2,
                stage.mature
            );

            return true;
        }

        _resolveLandingParkCohort(
            effectiveReferrer
        );

        _settleBookCohort(
            effectiveReferrer
        );

        (
            stage.year1,
            stage.year2,
            stage.mature
        ) = _landCarryCohort(
            effectiveReferrer,
            words,
            CohortWeeks.BRIDGE_CARRY_HEADER_WORDS,
            stage.pairCount,
            stage.captureWeek,
            stage.mature
        );

        attributedContribution[_user] += stage.year1
            + stage.year2
            + stage.mature;

        emit CohortBridgeCarryApplied(
            _user,
            _srcChainSelector,
            effectiveReferrer,
            stage.referrer,
            stage.trackedDelta,
            stage.year1,
            stage.year2,
            stage.mature
        );

        return true;
    }

    function _migrateReferrerCohort(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        internal
    {
        if (_oldReferrer == ZERO_ADDRESS || _oldReferrer == _newReferrer) {
            return;
        }

        if (pendingDivestSync == _user) {

            _syncRefereeCohortAgainstAt(
                _user,
                _oldReferrer,
                pendingDivestParkedAt
            );

            _clearParkCohort(
                _user
            );
        }

        _settleBookCohort(
            _oldReferrer
        );

        _syncRefereeCohortAgainstAt(
            _user,
            _oldReferrer,
            block.timestamp
        );

        uint256 attributed = attributedContribution[_user];

        uint256[] memory pairs;

        uint256 pairCount;

        uint256 year1Sum;

        uint256 year2Sum;

        uint256 mature;

        if (attributed > 0) {

            (
                pairs,
                pairCount,
                year1Sum,
                year2Sum,
                mature
            ) = _reduceBookCohortCaptured(
                _oldReferrer,
                attributed
            );

            if (_newReferrer == ZERO_ADDRESS) {
                attributedContribution[_user] = 0;
            } else if (pairCount > 0 || mature > 0) {

                _settleBookCohort(
                    _newReferrer
                );

                _landCarryCohort(
                    _newReferrer,
                    _packPairWordsCohort(
                        0,
                        pairs,
                        pairCount
                    ),
                    0,
                    pairCount,
                    block.timestamp / CohortWeeks.WEEK,
                    mature
                );
            }
        }

        emit CohortReferrerFlipApplied(
            _user,
            _oldReferrer,
            _newReferrer,
            year1Sum,
            year2Sum,
            mature,
            pairCount
        );
    }
}
