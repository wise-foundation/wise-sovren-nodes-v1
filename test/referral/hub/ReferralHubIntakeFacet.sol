// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";
import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev ReferralHubIntakeFacet: the reporter surface of the hub
 * (`reportSelf`, `deliverCrumbs`, `deliverGap` behind the reporter
 * allowlist), the source and cursor reads, `setAllowedReporter`,
 * `setSourceSystem`, and the permissionless `settleWeeks`, which re-settles
 * every source listed for a referrer at the current rates of up to
 * MAX_SETTLE_BOUNDARIES consecutive weeks after later reports raised them
 * (idempotent, so anyone may poke it; bounded by the weeks asked for and
 * the referrer's listed sources). A source's system tag is informational
 * and frozen once the source has delivered. A local delivery names its
 * deliverer like any remote one, and zero is refused. After
 * `finalizeSetup` allowing a reporter runs only as a call proposed through
 * `proposeLeverChange` at least SELECTOR_CHANGE_DELAY earlier; a revoke
 * never waits.
 */
contract ReferralHubIntakeFacet is
    ReferralHubIntake,
    ReferralHubFacetBase
{

    modifier onlyReporter() {
        require(
            allowedReporter[msg.sender],
            NotReporter()
        );
        _;
    }

    function reportSelf(
        address _referrer,
        uint256[] calldata _selfRuns
    )
        external
        onlyReporter
        onlyDelegateCall
    {
        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _selfRuns.length <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            BatchTooLarge()
        );

        bytes32 source = _sourceKey(
            msg.sender
        );

        for (uint256 i; i < _selfRuns.length; ++i) {
            _applySelfRun(
                source,
                _referrer,
                _selfRuns[i],
                block.chainid
            );
        }
    }

    function settleWeeks(
        address _referrer,
        uint256 _fromWeek,
        uint256 _weekCount
    )
        external
        onlyDelegateCall
    {
        require(
            _weekCount <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            BatchTooLarge()
        );

        for (uint256 i; i < _weekCount; ++i) {
            _settleWeekSources(
                _referrer,
                _fromWeek + i
            );
        }
    }

    function deliverCrumbs(
        address _referrer,
        address _deliverer,
        uint256[] calldata _weeks,
        uint256[] calldata _words
    )
        external
        onlyReporter
        onlyDelegateCall
    {
        require(
            _referrer != ZERO_ADDRESS
                && _deliverer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _weeks.length == _words.length,
            LengthMismatch()
        );

        require(
            _weeks.length <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            BatchTooLarge()
        );

        bytes32 source = _sourceKey(
            msg.sender
        );

        DeliveryOrigin memory origin = _localOrigin(
            _deliverer
        );

        for (uint256 i; i < _weeks.length; ++i) {

            _deliverCrumb(
                source,
                _referrer,
                _weeks[i],
                _words[i],
                origin
            );
        }
    }

    function deliverGap(
        address _referrer,
        address _deliverer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        external
        onlyReporter
        onlyDelegateCall
    {
        require(
            _referrer != ZERO_ADDRESS
                && _deliverer != ZERO_ADDRESS,
            ZeroAddress()
        );

        bytes32 source = _sourceKey(
            msg.sender
        );

        _deliverGap(
            source,
            _referrer,
            _record,
            _fromWeek,
            _maxWeeks,
            _localOrigin(
                _deliverer
            )
        );
    }

    function setAllowedReporter(
        address _reporter,
        bool _allowed
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        require(
            _reporter != ZERO_ADDRESS,
            ZeroAddress()
        );

        if (_allowed) {
            _consumeLeverChange(
                keccak256(
                    abi.encodeCall(
                        this.setAllowedReporter,
                        (
                            _reporter,
                            true
                        )
                    )
                )
            );
        }

        allowedReporter[_reporter] = _allowed;

        emit ReporterAllowedSet(
            _reporter,
            _allowed
        );
    }

    function setSourceSystem(
        bytes32 _source,
        uint256 _systemId
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        require(
            _systemId < MAX_SYSTEMS,
            SystemOutOfRange()
        );

        if (sourceSystemOf[_source] == _systemId) {
            return;
        }

        require(
            sourceChainIdOf[_source] == 0,
            SourceAlreadySet()
        );

        sourceSystemOf[_source] = _systemId;

        emit SourceSystemSet(
            _source,
            _systemId
        );
    }

    function sourceKeyOf(
        uint256 _chainId,
        address _vault
    )
        external
        view
        returns (bytes32)
    {
        if (_chainId == block.chainid) {
            return _sourceKey(
                _vault
            );
        }

        return keccak256(
            abi.encode(
                _chainId,
                _vault
            )
        );
    }

    function sourceCountOf(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return sourcesOf[_referrer].length;
    }

    function sourceOfAt(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (bytes32)
    {
        return sourcesOf[_referrer][_index];
    }

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
        )
    {
        uint256 word = paidCursor[_source][_referrer][_week];

        return (
            CohortWeeks._laneY1(
                word
            ),
            CohortWeeks._laneY2(
                word
            ),
            CohortWeeks._laneM(
                word
            )
        );
    }

    function _localOrigin(
        address _deliverer
    )
        internal
        view
        returns (DeliveryOrigin memory)
    {
        return DeliveryOrigin({
            chainId: block.chainid,
            deliverer: _deliverer,
            messageId: bytes32(0)
        });
    }

    function _sourceKey(
        address _reporter
    )
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(
                    _reporter
                )
            )
        );
    }
}
