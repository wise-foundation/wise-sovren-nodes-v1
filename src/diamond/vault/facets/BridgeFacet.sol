// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Cross-chain bridge surface. `bridgeToVault` is the user entry
 * that banks accrued interest to the source chain (via the
 * `assignInterest` modifier), burns the shares, and dispatches a
 * Chainlink CCIP message to the registered peer vault on the
 * destination chain; `ccipReceive` is the router-authenticated
 * counterpart that mints the bridged shares on arrival exactly as a
 * deposit would. Registering the router is master-only and one-shot
 * (settable once, never re-pointed); registering peers is master-only
 * and timelocked, matching the same-chain peer-vault flow in
 * {MoveFacet}.
 *
 * `ccipReceive` deliberately omits `whenNotPaused`: pausing halts new
 * deposits, but shares already burned on a source chain must always
 * be mintable here so cross-chain funds are never stranded.
 */
contract BridgeFacet is FacetBase, IAny2EVMMessageReceiver {

    constructor()
        FacetBase()
    {}

    function setCcipRouter(
        address _router
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setCcipRouter(
            _router
        );
    }

    function setReferralEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setReferralEnabled(
            _enabled
        );
    }

    function setBridgeGasLimit(
        uint256 _gasLimit
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setBridgeGasLimit(
            _gasLimit
        );
    }

    function proposeCrossChainPeer(
        uint64 _chainSelector,
        address _peer,
        uint8 _peerDecimals
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeCrossChainPeer(
            _chainSelector,
            _peer,
            _peerDecimals
        );
    }

    function executeCrossChainPeerChange(
        uint64 _chainSelector
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyCrossChainPeerChange(
            _chainSelector
        );
    }

    function cancelCrossChainPeerChange(
        uint64 _chainSelector
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelCrossChainPeerChange(
            _chainSelector
        );
    }

    function removeCrossChainPeer(
        uint64 _chainSelector
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _removeCrossChainPeer(
            _chainSelector
        );
    }

    function bridgeToVault(
        uint64 _destChainSelector,
        uint256 _amount
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        gracePeriodCheck(msg.sender)
        assignInterest(msg.sender)
        returns (
            uint256 dstAmount,
            bytes32 messageId
        )
    {
        (
            dstAmount,
            messageId
        ) = _executeBridgeOut(
            _destChainSelector,
            _amount,
            ""
        );
    }

    function bridgeToVaultWithReferral(
        uint64 _destChainSelector,
        uint256 _amount,
        bytes calldata _referralData
    )
        external
        payable
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        gracePeriodCheck(msg.sender)
        assignInterest(msg.sender)
        returns (
            uint256 dstAmount,
            bytes32 messageId
        )
    {
        (
            dstAmount,
            messageId
        ) = _executeBridgeOut(
            _destChainSelector,
            _amount,
            _referralData
        );
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _executeBridgeReceive(
            _message
        );
    }

    function quoteBridgeFee(
        uint64 _destChainSelector,
        uint256 _amount
    )
        external
        view
        returns (uint256)
    {
        return _quoteBridgeFee(
            _destChainSelector,
            _amount,
            ""
        );
    }

    function quoteBridgeFeeWithReferral(
        uint64 _destChainSelector,
        uint256 _amount,
        bytes calldata _referralData
    )
        external
        view
        returns (uint256)
    {
        return _quoteBridgeFee(
            _destChainSelector,
            _amount,
            _referralData
        );
    }

    function getBridgeableBalance(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return balanceOf(
            _user
        );
    }

    function supportsInterface(
        bytes4 _interfaceId
    )
        external
        pure
        returns (bool)
    {
        return _interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }
}
