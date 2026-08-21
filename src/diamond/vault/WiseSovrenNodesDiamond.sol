// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {WiseSovrenNodesHelper} from "./helpers/WiseSovrenNodesHelper.sol";
import {WiseSovrenNodesDeclarations} from "./declarations/WiseSovrenNodesDeclarations.sol";
import {WiseSovrenNodesInitParams} from "./WiseSovrenNodesDiamondStructs.sol";

import {
    FacetNotFound,
    AlreadyInitialized,
    NoSelectorChangeQueued,
    SelectorTimelockNotElapsed
} from "../shared/DiamondErrors.sol";

/**
 * @title WiseSovrenNodesDiamond
 * @dev Entry contract for the WiseSovrenNodes diamond. Owns the
 * constructor, `finalizeSetup`, the propose/execute/cancel selector
 * machinery, and the `fallback` dispatcher that DELEGATECALLs
 * registered facets. Functions inherited from the helper chain are
 * matched by Solidity's own dispatcher before fallback runs.
 *
 * Selector changes are timelocked behind `SELECTOR_CHANGE_DELAY`
 * (3 days) once `finalizeSetup` is called.
 */
contract WiseSovrenNodesDiamond is WiseSovrenNodesHelper {

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        WiseSovrenNodesDeclarations(
            _params
        )
    {}

    // ---- Setup finalization ----

    function finalizeSetup()
        external
        onlyMaster
    {
        require(
            !initialized,
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
        for (uint256 i = 0; i < _selectors.length;) {
            proposedSelectorFacet[_selectors[i]] = _facet;
            selectorChangeQueuedAt[_selectors[i]] = block.timestamp;

            unchecked {
                ++i;
            }
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
        for (uint256 i = 0; i < _selectors.length;) {
            _applySelectorChange(
                _selectors[i]
            );

            unchecked {
                ++i;
            }
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
            InvalidValue()
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
        proposedSelectorFacet[_selector] = ZERO_ADDRESS;
        selectorChangeQueuedAt[_selector] = 0;

        emit SelectorProposalCancelled(
            _selector
        );
    }

    // ---- Fallback dispatcher ----

    fallback()
        external
        payable
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
