// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @dev The external surface of the deployed ReferralHub diamond, its own
 * getters and the facet routed entrypoints alike.
 */
interface IReferralHub {

    // ---- OwnableMaster (proxy native) ----

    function master()
        external
        view
        returns (address);

    function proposedMaster()
        external
        view
        returns (address);

    function proposeOwner(
        address _proposedMaster
    )
        external;

    function claimOwnership()
        external;

    function renounceOwnership()
        external;

    // ---- Selector machinery (proxy native) ----

    function initialized()
        external
        view
        returns (bool);

    function selectorToFacet(
        bytes4 _selector
    )
        external
        view
        returns (address);

    function proposedSelectorFacet(
        bytes4 _selector
    )
        external
        view
        returns (address);

    function selectorChangeQueuedAt(
        bytes4 _selector
    )
        external
        view
        returns (uint256);

    function finalizeSetup()
        external;

    function proposeSelector(
        bytes4 _selector,
        address _facet
    )
        external;

    function proposeSelectors(
        bytes4[] calldata _selectors,
        address _facet
    )
        external;

    function executeSelectorChange(
        bytes4 _selector
    )
        external;

    function executeSelectorChanges(
        bytes4[] calldata _selectors
    )
        external;

    function cancelSelectorProposal(
        bytes4 _selector
    )
        external;

    function proposeLeverChange(
        bytes calldata _call
    )
        external;

    function cancelLeverChange(
        bytes32 _changeHash
    )
        external;

    function leverChangeQueuedAt(
        bytes32 _changeHash
    )
        external
        view
        returns (uint256);

    // ---- Storage getters (proxy native) ----

    function USD_TOKEN()
        external
        view
        returns (IERC20);

    function claimable(
        uint256 _chainId,
        address _account
    )
        external
        view
        returns (uint256);

    function totalAccrued()
        external
        view
        returns (uint256);

    function totalClaimed()
        external
        view
        returns (uint256);

    function totalPayable()
        external
        view
        returns (uint256);

    function allowedReporter(
        address _reporter
    )
        external
        view
        returns (bool);

    function payoutStamp(
        uint256 _chainId,
        address _owner
    )
        external
        view
        returns (uint256);

    function ccipRouter()
        external
        view
        returns (address);

    function flushSourceChainId(
        uint64 _chainSelector,
        address _sender
    )
        external
        view
        returns (uint256);

    function designationSourceChainId(
        uint64 _chainSelector,
        address _sender
    )
        external
        view
        returns (uint256);

    function flushCommitment(
        bytes32 _messageId
    )
        external
        view
        returns (bytes32);

    function delivererShareCap()
        external
        view
        returns (uint256);

    function sourceSystemOf(
        bytes32 _source
    )
        external
        view
        returns (uint256);

    function sourceChainIdOf(
        bytes32 _source
    )
        external
        view
        returns (uint256);

    function MAX_SYSTEMS()
        external
        view
        returns (uint256);

    // ---- Intake facet ----

    function reportSelf(
        address _referrer,
        uint256[] calldata _selfRuns
    )
        external;

    function settleWeeks(
        address _referrer,
        uint256 _fromWeek,
        uint256 _weekCount
    )
        external;

    function deliverCrumbs(
        address _referrer,
        address _deliverer,
        uint256[] calldata _weeks,
        uint256[] calldata _words
    )
        external;

    function deliverGap(
        address _referrer,
        address _deliverer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        external;

    function setAllowedReporter(
        address _reporter,
        bool _allowed
    )
        external;

    function setSourceSystem(
        bytes32 _source,
        uint256 _systemId
    )
        external;

    function sourceKeyOf(
        uint256 _chainId,
        address _vault
    )
        external
        view
        returns (bytes32);

    function sourceCountOf(
        address _referrer
    )
        external
        view
        returns (uint256);

    function sourceOfAt(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (bytes32);

    function paidCursorAtSource(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        );

    // ---- Mailbox facet ----

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external;

    function applyFlush(
        bytes32 _messageId,
        uint64 _srcChainSelector,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        external;

    function supportsInterface(
        bytes4 _interfaceId
    )
        external
        view
        returns (bool);

    function setCcipRouter(
        address _router
    )
        external;

    function setFlushSource(
        uint64 _chainSelector,
        address _vault,
        uint256 _chainId
    )
        external;

    function setDesignationSource(
        uint64 _chainSelector,
        address _registry,
        uint256 _chainId
    )
        external;

    // ---- Payout facet ----

    function claim(
        uint256 _chainId,
        address _referrer
    )
        external;

    function claimUpTo(
        uint256 _chainId,
        address _referrer,
        uint256 _amount
    )
        external;

    function claimAll(
        address _referrer,
        uint256[] calldata _chainIds
    )
        external
        returns (uint256 total);

    function setPayoutAddress(
        address _payout
    )
        external;

    function payoutAddressOf(
        uint256 _chainId,
        address _owner
    )
        external
        view
        returns (address);

    // ---- Rates facet ----

    function pushRateTable(
        ReferralHubDeclarations.RateTable calldata _table
    )
        external;

    function setDelivererShareCap(
        uint256 _cap
    )
        external;

    function elevateReferrer(
        address _referrer,
        uint256 _fromWeek
    )
        external;

    function endElevation(
        address _referrer,
        uint256 _untilWeek
    )
        external;

    function elevatedFromWeek(
        address _referrer
    )
        external
        view
        returns (uint256);

    function elevatedUntilWeek(
        address _referrer
    )
        external
        view
        returns (uint256);

    function weeklyRates(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        );

    function rateTableCount()
        external
        view
        returns (uint256);

    function rateTableAt(
        uint256 _index
    )
        external
        view
        returns (ReferralHubDeclarations.RateTable memory);

    // ---- Checkpoints facet ----

    function ladderInputsAt(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredInput,
            uint256 selfInput
        );

    function weekReportOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 referredAverage,
            uint256 paidUnits
        );

    function weekSelfOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256);
}
