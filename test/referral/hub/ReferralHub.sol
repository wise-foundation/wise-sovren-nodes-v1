// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubDeclarations} from "./ReferralHubDeclarations.sol";
import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    FacetNotFound,
    AlreadyInitialized,
    NoSelectorChangeQueued,
    SelectorTimelockNotElapsed
} from "../../../src/diamond/shared/DiamondErrors.sol";

/**
 * @dev ReferralHub: the mainnet hub of the referral commission system, a
 * diamond whose five facets share the ReferralHubDeclarations layout. This
 * contract holds the constructor seeds, the two-step ownership, the
 * selector changes (timelocked after `finalizeSetup`), the lever change
 * proposals (a proposal carries the exact setter call it queues, so the
 * pending grant is public for the whole delay) and the fallback
 * dispatcher. Master can never write scores, cursors, week buckets or
 * claimables. Referrers claim the hub's own USD here per (source chain,
 * referrer), so money earned on a chain moves only to the payout address
 * proven on that chain; the hub is funded by plain USD transfers and never
 * draws on a vault. Claims follow checks, effects, interactions.
 */
contract ReferralHub is ReferralHubDeclarations {

    constructor(
        address _usdToken
    )
        OwnableMaster(
            msg.sender
        )
    {
        require(
            _usdToken != ZERO_ADDRESS,
            ZeroAddress()
        );

        USD_TOKEN = IERC20(
            _usdToken
        );

        _seedGenesisRateTable();
    }

    // ---- Setup finalization ----

    function finalizeSetup()
        external
        onlyMaster
    {
        require(
            initialized == false,
            AlreadyInitialized()
        );

        initialized = true;

        emit SetupFinalized();
    }

    // ---- Selector propose / execute / cancel ----

    function proposeSelector(
        bytes4 _selector,
        address _facet
    )
        external
        onlyMaster
    {
        proposedSelectorFacet[_selector] = _facet;

        selectorChangeQueuedAt[_selector] = block.timestamp;

        emit SelectorProposed(
            _selector,
            _facet,
            block.timestamp + SELECTOR_CHANGE_DELAY
        );
    }

    function proposeSelectors(
        bytes4[] calldata _selectors,
        address _facet
    )
        external
        onlyMaster
    {
        for (uint256 i; i < _selectors.length; ++i) {

            proposedSelectorFacet[_selectors[i]] = _facet;

            selectorChangeQueuedAt[_selectors[i]] = block.timestamp;
        }

        emit SelectorsProposed(
            _selectors,
            _facet,
            block.timestamp + SELECTOR_CHANGE_DELAY
        );
    }

    function executeSelectorChange(
        bytes4 _selector
    )
        external
        onlyMaster
    {
        _applySelectorChange(
            _selector
        );
    }

    function executeSelectorChanges(
        bytes4[] calldata _selectors
    )
        external
        onlyMaster
    {
        for (uint256 i; i < _selectors.length; ++i) {

            _applySelectorChange(
                _selectors[i]
            );
        }
    }

    function _applySelectorChange(
        bytes4 _selector
    )
        internal
    {
        require(
            selectorChangeQueuedAt[_selector] > 0,
            NoSelectorChangeQueued()
        );

        if (initialized) {

            require(
                block.timestamp >= selectorChangeQueuedAt[_selector] + SELECTOR_CHANGE_DELAY,
                SelectorTimelockNotElapsed()
            );
        }

        address newFacet = proposedSelectorFacet[_selector];

        require(
            newFacet == ZERO_ADDRESS
                || newFacet.code.length > 0,
            ZeroAddress()
        );

        selectorToFacet[_selector] = newFacet;

        proposedSelectorFacet[_selector] = ZERO_ADDRESS;

        selectorChangeQueuedAt[_selector] = 0;

        emit SelectorUpdated(
            _selector,
            newFacet
        );
    }

    function cancelSelectorProposal(
        bytes4 _selector
    )
        external
        onlyMaster
    {
        require(
            selectorChangeQueuedAt[_selector] > 0,
            NoSelectorChangeQueued()
        );

        proposedSelectorFacet[_selector] = ZERO_ADDRESS;

        selectorChangeQueuedAt[_selector] = 0;

        emit SelectorProposalCancelled(
            _selector
        );
    }

    // ---- Lever propose / cancel ----

    function proposeLeverChange(
        bytes calldata _call
    )
        external
        onlyMaster
    {
        require(
            initialized,
            SetupNotFinalized()
        );

        bytes32 changeHash = keccak256(
            _call
        );

        leverChangeQueuedAt[changeHash] = block.timestamp;

        emit LeverChangeProposed(
            changeHash,
            _call,
            block.timestamp + SELECTOR_CHANGE_DELAY
        );
    }

    function cancelLeverChange(
        bytes32 _changeHash
    )
        external
        onlyMaster
    {
        require(
            leverChangeQueuedAt[_changeHash] > 0,
            LeverChangeNotQueued()
        );

        leverChangeQueuedAt[_changeHash] = 0;

        emit LeverChangeCancelled(
            _changeHash
        );
    }

    // ---- Fallback dispatcher ----

    fallback()
        external
    {
        address facet = selectorToFacet[msg.sig];

        require(
            facet != ZERO_ADDRESS,
            FacetNotFound()
        );

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
