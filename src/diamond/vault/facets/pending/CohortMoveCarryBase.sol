// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {CohortClampBase} from "./CohortClampBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortMoveCarryBase: the same-chain move carry. The source clamps
 * the mover, takes `min(deficit, burned)` through the sale walk, scales the
 * taken pairs to destination units and stages them in the registry. The
 * destination consumes them in the same transaction and applies them only
 * when they were staged in this block, their lane sum is at most the
 * tracked delta and the tracked delta fits the mover's post-mint headroom.
 * Registry calls are guarded, so a failure loses attribution but never
 * blocks the move.
 */
abstract contract CohortMoveCarryBase is CohortClampBase {

    struct CarryStage {
        uint256[] pairs;
        uint256 pairCount;
        uint256 mature;
        uint256 year1Sum;
        uint256 year2Sum;
        uint256 trackedDelta;
    }

    function _captureMoveOutCohort(
        address _user,
        address _dstVault,
        uint256 _burnedAmount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
    {
        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false) {

            emit CohortCarrySkipped(
                _user,
                _dstVault
            );

            return;
        }

        ClampSplit memory split = _clampForCarryCohort(
            _user,
            referrer,
            tracked - held,
            _burnedAmount
        );

        _settleSelfCohort(
            _user,
            block.timestamp
        );

        trackedContribution[_user] = held;

        _stageMoveCarryCohort(
            _user,
            _dstVault,
            referrer,
            split,
            _scaleNumerator,
            _scaleDenominator
        );

        emit CohortContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }

    function _stageMoveCarryCohort(
        address _user,
        address _dstVault,
        address _referrer,
        ClampSplit memory _split,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
    {
        CarryStage memory stage;

        if (_referrer != ZERO_ADDRESS && _split.carryCharge > 0) {
            (
                stage.pairs,
                stage.pairCount,
                ,
                ,
                stage.mature
            ) = _reduceBookCohortCaptured(
                _referrer,
                _split.carryCharge
            );
        }

        stage.mature = _scaleCarryAmount(
            stage.mature,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.LANE_MASK_80
        );

        (
            stage.year1Sum,
            stage.year2Sum
        ) = _scaleCarryPairsCohort(
            stage.pairs,
            stage.pairCount,
            _scaleNumerator,
            _scaleDenominator
        );

        stage.trackedDelta = _scaleCarryAmount(
            _split.carryDelta,
            _scaleNumerator,
            _scaleDenominator,
            CohortWeeks.CARRY_HALF_MASK
        );

        if (stage.trackedDelta == 0 && stage.pairCount == 0) {
            return;
        }

        if (
            _stageCarryGuarded(
                referralRegistry,
                _dstVault,
                _user,
                _packCarryPayloadCohort(
                    _referrer,
                    stage.pairs,
                    stage.pairCount,
                    stage.trackedDelta,
                    stage.mature
                )
            ) == false
        ) {

            emit CohortCarrySkipped(
                _user,
                _dstVault
            );

            return;
        }

        emit CohortCarryStaged(
            _user,
            _dstVault,
            _referrer,
            stage.trackedDelta,
            stage.year1Sum,
            stage.year2Sum,
            stage.mature,
            stage.pairCount
        );
    }

    function _scaleCarryPairsCohort(
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator
    )
        internal
        pure
        returns (
            uint256 year1Sum,
            uint256 year2Sum
        )
    {
        for (uint256 i; i < _pairCount; ++i) {

            uint256 pair = _pairs[i];

            uint256 scaledAmount = _scaleCarryAmount(
                CohortWeeks._carryPairAmount(
                    pair
                ),
                _scaleNumerator,
                _scaleDenominator,
                CohortWeeks.RING_LANE_MAX
            );

            uint256 ring = CohortWeeks._carryPairRing(
                pair
            );

            if (ring == CohortWeeks.CARRY_RING_YEAR1) {
                year1Sum += scaledAmount;
            } else {
                year2Sum += scaledAmount;
            }

            _pairs[i] = CohortWeeks._packCarryPair(
                scaledAmount,
                CohortWeeks._carryPairSlot(
                    pair
                ),
                ring
            );
        }
    }

    function _packCarryPayloadCohort(
        address _referrer,
        uint256[] memory _pairs,
        uint256 _pairCount,
        uint256 _trackedDelta,
        uint256 _mature
    )
        internal
        pure
        returns (uint256[] memory payload)
    {
        payload = _packPairWordsCohort(
            2,
            _pairs,
            _pairCount
        );

        payload[0] = CohortWeeks._packCarryEnvelope(
            _referrer,
            _pairCount
        );

        payload[1] = CohortWeeks._packCarryAmounts(
            _trackedDelta,
            _mature
        );
    }

    function _packPairWordsCohort(
        uint256 _headerWords,
        uint256[] memory _pairs,
        uint256 _pairCount
    )
        internal
        pure
        returns (uint256[] memory words)
    {
        words = new uint256[](
            _headerWords + (_pairCount + 1) / 2
        );

        for (uint256 i; i < _pairCount; ++i) {

            uint256 wordIndex = _headerWords + i / 2;

            if (i % 2 == 0) {
                words[wordIndex] = _pairs[i];
            } else {
                words[wordIndex] = CohortWeeks._packCarryPairsWord(
                    words[wordIndex],
                    _pairs[i]
                );
            }
        }
    }

    function _scaleCarryAmount(
        uint256 _amount,
        uint256 _scaleNumerator,
        uint256 _scaleDenominator,
        uint256 _cap
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scaled = _amount * _scaleNumerator / _scaleDenominator;

        return scaled > _cap
            ? _cap
            : scaled;
    }

    function _stageCarryGuarded(
        address _registry,
        address _dstVault,
        address _user,
        uint256[] memory _payload
    )
        internal
        returns (bool)
    {
        try IReferralRegistry(_registry).stageCarry(
            _dstVault,
            _user,
            _payload
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _applyMoveInCohort(
        address _user,
        address _srcVault
    )
        internal
    {
        address registry = referralRegistry;

        if (registry == ZERO_ADDRESS) {

            emit CohortCarryDiscarded(
                _user,
                _srcVault,
                0
            );

            return;
        }

        (
            bool consumeOk,
            uint256 stagedAt,
            uint256[] memory payload
        ) = _consumeCarryGuarded(
            registry,
            _srcVault,
            _user
        );

        if (consumeOk == true && stagedAt == 0) {
            return;
        }

        if (
            consumeOk == false
            || stagedAt != block.timestamp
            || _carryPayloadValid(
                _user,
                payload
            ) == false
        ) {

            emit CohortCarryDiscarded(
                _user,
                _srcVault,
                stagedAt
            );

            return;
        }

        _applyCarryPayloadCohort(
            _user,
            _srcVault,
            payload
        );
    }

    function _applyCarryPayloadCohort(
        address _user,
        address _srcVault,
        uint256[] memory _payload
    )
        internal
    {
        CarryStage memory stage;

        address carriedReferrer = CohortWeeks._carryEnvelopeReferrer(
            _payload[0]
        );

        stage.pairCount = CohortWeeks._carryEnvelopePairCount(
            _payload[0]
        );

        stage.trackedDelta = CohortWeeks._carryTrackedDelta(
            _payload[1]
        );

        stage.mature = CohortWeeks._carryMature(
            _payload[1]
        );

        _settleSelfCohort(
            _user,
            block.timestamp
        );

        trackedContribution[_user] += stage.trackedDelta;

        if (carriedReferrer == ZERO_ADDRESS || (stage.pairCount == 0 && stage.mature == 0)) {

            emit CohortCarryApplied(
                _user,
                _srcVault,
                ZERO_ADDRESS,
                carriedReferrer,
                stage.trackedDelta,
                0,
                0,
                stage.mature,
                stage.pairCount
            );

            return;
        }

        (
            bool lookupOk,
            address referrer
        ) = _cohortReferrerOf(
            _user
        );

        if (lookupOk == false || referrer == ZERO_ADDRESS) {

            emit CohortCarryBookDropped(
                _user,
                _srcVault,
                carriedReferrer,
                stage.trackedDelta,
                stage.mature,
                stage.pairCount
            );

            return;
        }

        _settleBookCohort(
            referrer
        );

        (
            stage.year1Sum,
            stage.year2Sum,
            stage.mature
        ) = _landCarryCohort(
            referrer,
            _payload,
            2,
            stage.pairCount,
            block.timestamp / CohortWeeks.WEEK,
            stage.mature
        );

        attributedContribution[_user] += stage.year1Sum
            + stage.year2Sum
            + stage.mature;

        emit CohortCarryApplied(
            _user,
            _srcVault,
            referrer,
            carriedReferrer,
            stage.trackedDelta,
            stage.year1Sum,
            stage.year2Sum,
            stage.mature,
            stage.pairCount
        );
    }

    function _carryPayloadValid(
        address _user,
        uint256[] memory _payload
    )
        private
        view
        returns (bool)
    {
        if (_payload.length < 2) {
            return false;
        }

        if (_payload.length > CohortWeeks.MAX_CARRY_WORDS) {
            return false;
        }

        uint256 envelope = _payload[0];

        if (CohortWeeks._carryEnvelopeVersion(envelope) != CohortWeeks.CARRY_VERSION) {
            return false;
        }

        uint256 pairCount = CohortWeeks._carryEnvelopePairCount(
            envelope
        );

        if (pairCount > CohortWeeks.MAX_CARRY_PAIRS) {
            return false;
        }

        if (_payload.length != 2 + (pairCount + 1) / 2) {
            return false;
        }

        (
            bool pairsOk,
            uint256 laneSum
        ) = CohortWeeks._carryPairsValid(
            _payload,
            2,
            pairCount,
            CohortWeeks._carryMature(
                _payload[1]
            ),
            false
        );

        if (pairsOk == false) {
            return false;
        }

        uint256 trackedDelta = CohortWeeks._carryTrackedDelta(
            _payload[1]
        );

        if (laneSum > trackedDelta) {
            return false;
        }

        uint256 held = balanceOf(
            _user
        );

        if (trackedContribution[_user] + trackedDelta > held) {
            return false;
        }

        return true;
    }

    function _consumeCarryGuarded(
        address _registry,
        address _srcVault,
        address _user
    )
        internal
        returns (
            bool ok,
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        if (_registry.code.length == 0) {
            return (
                false,
                0,
                payload
            );
        }

        try IReferralRegistry(_registry).consumeCarry(
            _srcVault,
            _user
        ) returns (
            uint256 returnedStagedAt,
            uint256[] memory returnedPayload
        ) {
            return (
                true,
                returnedStagedAt,
                returnedPayload
            );
        } catch {
            return (
                false,
                0,
                payload
            );
        }
    }
}
