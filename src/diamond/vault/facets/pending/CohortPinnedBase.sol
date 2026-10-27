// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {OwnableMaster} from "../../../shared/OwnableMaster.sol";
import {OnlyDelegateCall} from "../../../shared/DiamondErrors.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

import {WiseSovrenNodesDiamondErrors} from "../../WiseSovrenNodesDiamondErrors.sol";
import {WiseSovrenNodesDiamondEvents} from "../../WiseSovrenNodesDiamondEvents.sol";

import {ReferralRegistryDeclaration} from "../../declarations/pending/ReferralRegistryDeclaration.sol";
import {CohortContributionDeclaration} from "../../declarations/pending/CohortContributionDeclaration.sol";
import {CohortBookDeclaration} from "../../declarations/pending/CohortBookDeclaration.sol";
import {ReferralPayoutDeclaration} from "../../declarations/pending/ReferralPayoutDeclaration.sol";
import {ReferralRegistryPointerDeclaration} from "../../declarations/pending/ReferralRegistryPointerDeclaration.sol";
import {PayoutHubPointerDeclaration} from "../../declarations/pending/PayoutHubPointerDeclaration.sol";
import {CohortFlushDeclaration} from "../../declarations/pending/CohortFlushDeclaration.sol";
import {CohortAttributionDeclaration} from "../../declarations/pending/CohortAttributionDeclaration.sol";
import {CohortDivestDeclaration} from "../../declarations/pending/CohortDivestDeclaration.sol";
import {CohortSelfDeclaration} from "../../declarations/pending/CohortSelfDeclaration.sol";
import {CohortDisarmDeclaration} from "../../declarations/pending/CohortDisarmDeclaration.sol";
import {CohortSelfLogDeclaration} from "../../declarations/pending/CohortSelfLogDeclaration.sol";

/**
 * @dev Genesis slots 0 to 66 of the diamond layout, pinned by label
 * for the slim cohort facets. Slots 0 to 2 come from the same bases
 * the declaration chain inherits first; the rest is __gap filler.
 * Checked against the snapshot by script/check_storage_layout.sh.
 */
abstract contract CohortPinnedPrefix is
    WiseSovrenNodesDiamondEvents,
    WiseSovrenNodesDiamondErrors,
    OwnableMaster,
    Pausable,
    ReentrancyGuard
{
    mapping(address => uint256) internal _balances;

    uint256[19] private __gap4;

    mapping(bytes4 => address) internal selectorToFacet;

    uint256[10] private __gap24;

    bool private __pad34;

    address internal ccipRouter;

    uint256[10] private __gap35;

    address internal transferHookFacet;

    uint256[5] private __gap46;

    uint256 internal gracePeriodDuration;

    uint256 private __gap52;

    mapping(address => uint256) internal lastLargeDepositAt;

    bool internal graceFreezeEnabled;

    uint256[12] private __gap55;

    bool internal transient hookExecuting;
}

/**
 * @dev Slim storage base of the cohort engine slices and the flush
 * facet: the pinned genesis prefix, then the tail shards from slot 67
 * inherited verbatim in declaration chain order, plus the few helper
 * chain internals these facets call. The hook dispatch is reached only
 * after the flush armed check, so it omits the disarmed and unset hook
 * early returns of the helper chain. A new tail shard must be appended
 * here as well before a slim facet reads it.
 */
abstract contract CohortPinnedBase is
    CohortPinnedPrefix,
    ReferralRegistryDeclaration,
    CohortContributionDeclaration,
    CohortBookDeclaration,
    ReferralPayoutDeclaration,
    ReferralRegistryPointerDeclaration,
    PayoutHubPointerDeclaration,
    CohortFlushDeclaration,
    CohortAttributionDeclaration,
    CohortDivestDeclaration,
    CohortSelfDeclaration,
    CohortDisarmDeclaration,
    CohortSelfLogDeclaration
{
    address internal immutable _self;

    constructor()
        OwnableMaster(msg.sender)
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall()
        internal
        view
    {
        if (address(this) != _self) {
            return;
        }

        revert OnlyDelegateCall();
    }

    function balanceOf(
        address _account
    )
        internal
        view
        returns (uint256)
    {
        return _balances[_account];
    }

    function _checkGracePeriod(
        address _user
    )
        internal
        view
    {
        require(
            lastLargeDepositAt[_user] == 0
                || block.timestamp >= lastLargeDepositAt[_user] + gracePeriodDuration,
            GracePeriodNotElapsed()
        );
    }

    function _parkedAtDisarmCohort(
        uint256 _cursor,
        uint256 _disarmedAt,
        uint256 _rearmedAt
    )
        internal
        view
        returns (bool)
    {
        return _rearmedAt > _disarmedAt
            && _cursor <= _disarmedAt
            && block.timestamp < _rearmedAt + CohortWeeks.WEEK;
    }

    function _staticWordsCohort(
        address _target,
        bytes4 _selector,
        uint256 _argument0,
        uint256 _argument1,
        uint256 _calldataLength,
        uint256 _outWords
    )
        internal
        view
        returns (
            bool success,
            uint256 word0,
            uint256 word1,
            uint256 word2
        )
    {
        assembly {
            let ptr := mload(0x40)

            mstore(ptr, _selector)
            mstore(add(ptr, 0x04), _argument0)
            mstore(add(ptr, 0x24), _argument1)

            success := staticcall(
                gas(),
                _target,
                ptr,
                _calldataLength,
                0x00,
                0x00
            )

            if iszero(eq(returndatasize(), mul(_outWords, 32))) {
                success := 0
            }

            if success {
                returndatacopy(ptr, 0, mul(_outWords, 32))
                word0 := mload(ptr)
                word1 := mload(add(ptr, 0x20))
                word2 := mload(add(ptr, 0x40))
            }
        }
    }

    function _cohortSettle(
        address _referrer
    )
        internal
    {
        _runCohortHook(
            abi.encodeWithSelector(
                COHORT_SETTLE_SELECTOR,
                _referrer
            )
        );
    }

    function _runCohortHook(
        bytes memory _callData
    )
        internal
    {
        hookExecuting = true;

        (
            bool success,
            bytes memory returnData
        ) = transferHookFacet.delegatecall(
            _callData
        );

        hookExecuting = false;

        if (success == false) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
