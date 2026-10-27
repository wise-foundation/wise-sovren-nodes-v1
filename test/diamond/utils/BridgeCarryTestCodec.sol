// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Test-side builder of version-3 bridge carry payloads from lane
 * totals: a year-one total becomes one pair at the capture week's slot on
 * ring one, a year-two total one pair at the same slot on ring two, so a
 * payload built at capture week W carries a year-one cohort credited in W
 * and a year-two cohort credited in W - 52. The version argument is
 * written as given, so negative tests can stamp any version.
 */
library BridgeCarryTestCodec {

    function _pack(
        address _referrer,
        uint256 _version,
        uint256 _captureWeek,
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
        uint256 pairCount = (_year1 > 0 ? 1 : 0)
            + (_year2 > 0 ? 1 : 0);

        uint256[] memory words = new uint256[](
            3 + (pairCount + 1) / 2
        );

        words[0] = uint256(uint160(_referrer))
            | (_version << CohortWeeks.CARRY_VERSION_SHIFT)
            | (_captureWeek << CohortWeeks.BRIDGE_CARRY_CAPTURE_WEEK_SHIFT)
            | (pairCount << CohortWeeks.BRIDGE_CARRY_PAIR_COUNT_SHIFT);

        words[1] = _trackedDelta
            | (_assignedAt << CohortWeeks.BRIDGE_CARRY_ASSIGNED_AT_SHIFT)
            | (_rank << CohortWeeks.BRIDGE_CARRY_RANK_SHIFT);

        words[2] = _mature;

        uint256 slot = _captureWeek % CohortWeeks.RING_SLOTS;

        uint256 pairYear1 = CohortWeeks._packCarryPair(
            _year1,
            slot,
            CohortWeeks.CARRY_RING_YEAR1
        );

        uint256 pairYear2 = CohortWeeks._packCarryPair(
            _year2,
            slot,
            CohortWeeks.CARRY_RING_YEAR2
        );

        if (_year1 > 0 && _year2 > 0) {
            words[3] = CohortWeeks._packCarryPairsWord(
                pairYear1,
                pairYear2
            );
        } else if (_year1 > 0) {
            words[3] = pairYear1;
        } else if (_year2 > 0) {
            words[3] = pairYear2;
        }

        return CohortWeeks._packBridgeCarry(
            words
        );
    }
}
