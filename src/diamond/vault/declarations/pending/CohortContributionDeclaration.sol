// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Tail shard at slots 68 and 69: the recorder switch
 * `cohortSyncEnabled` and each account's `trackedContribution`, which
 * rises only on a deposit or compound and falls only through the clamp.
 * The switch is off by default, so a live diamond with virgin tail storage
 * behaves as before. The selector constants name the engine entrypoints the
 * helper chain stubs call and take no storage.
 */
abstract contract CohortContributionDeclaration {

    bool internal cohortSyncEnabled;

    mapping(address => uint256) internal trackedContribution;

    bytes4 internal constant COHORT_SYNC_SELECTOR = bytes4(
        keccak256(
            "applyCohortSync(address)"
        )
    );

    bytes4 internal constant COHORT_CREDIT_SELECTOR = bytes4(
        keccak256(
            "applyCohortCredit(address,uint256)"
        )
    );

    bytes4 internal constant COHORT_ADVANCE_SELECTOR = bytes4(
        keccak256(
            "applyCohortAdvance(address,uint256)"
        )
    );

    bytes4 internal constant COHORT_SETTLE_SELECTOR = bytes4(
        keccak256(
            "applyCohortSettle(address)"
        )
    );

    bytes4 internal constant COHORT_MOVE_OUT_SELECTOR = bytes4(
        keccak256(
            "applyCohortMoveOut(address,address,uint256,uint256,uint256)"
        )
    );

    bytes4 internal constant COHORT_MOVE_IN_SELECTOR = bytes4(
        keccak256(
            "applyCohortMoveIn(address,address)"
        )
    );

    bytes4 internal constant COHORT_FLIP_SELECTOR = bytes4(
        keccak256(
            "applyCohortFlip(address,address,address)"
        )
    );

    bytes4 internal constant COHORT_BRIDGE_OUT_SELECTOR = bytes4(
        keccak256(
            "applyCohortBridgeOut(address,uint64,uint256,uint256,uint256)"
        )
    );

    bytes4 internal constant COHORT_BRIDGE_IN_SELECTOR = bytes4(
        keccak256(
            "applyCohortBridgeIn(address,uint64,uint256,bytes)"
        )
    );
}
