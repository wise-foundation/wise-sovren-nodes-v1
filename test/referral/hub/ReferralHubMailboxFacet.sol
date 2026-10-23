// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubMailbox} from "./ReferralHubMailbox.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev ReferralHubMailboxFacet: the CCIP receive, the permissionless
 * `applyFlush`, the source registrations and the router pointer over the
 * ReferralHubMailbox machinery. After `finalizeSetup` a router change and
 * a source set to a chain id run only as a call proposed through
 * `proposeLeverChange` at least SELECTOR_CHANGE_DELAY earlier; removing a
 * source (chain id zero) never waits.
 */
contract ReferralHubMailboxFacet is
    ReferralHubMailbox,
    ReferralHubFacetBase,
    IAny2EVMMessageReceiver,
    IERC165
{

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
        onlyDelegateCall
    {
        require(
            msg.sender == ccipRouter,
            NotCcipRouter()
        );

        uint64 srcChainSelector = _message.sourceChainSelector;

        address srcSender = abi.decode(
            _message.sender,
            (address)
        );

        uint256 chainId = flushSourceChainId[srcChainSelector][srcSender];

        if (chainId != 0) {

            _receiveFlush(
                _message.messageId,
                srcChainSelector,
                srcSender,
                chainId,
                _message.data
            );

            return;
        }

        chainId = designationSourceChainId[srcChainSelector][srcSender];

        require(
            chainId != 0,
            UnknownFlushSource()
        );

        _receiveDesignationPush(
            srcChainSelector,
            chainId,
            _message.data
        );
    }

    function applyFlush(
        bytes32 _messageId,
        uint64 _srcChainSelector,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        external
        onlyDelegateCall
    {
        _applyFlushEnvelope(
            _messageId,
            _srcChainSelector,
            _chainId,
            _vault,
            _payload
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

    function setCcipRouter(
        address _router
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        require(
            _router != ZERO_ADDRESS,
            ZeroAddress()
        );

        _consumeLeverChange(
            keccak256(
                abi.encodeCall(
                    this.setCcipRouter,
                    (
                        _router
                    )
                )
            )
        );

        ccipRouter = _router;

        emit CcipRouterSet(
            _router
        );
    }

    function setFlushSource(
        uint64 _chainSelector,
        address _vault,
        uint256 _chainId
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        _setSourceChainId(
            flushSourceChainId,
            _chainSelector,
            _vault,
            _chainId,
            keccak256(
                abi.encodeCall(
                    this.setFlushSource,
                    (
                        _chainSelector,
                        _vault,
                        _chainId
                    )
                )
            )
        );

        emit FlushSourceSet(
            _chainSelector,
            _vault,
            _chainId
        );
    }

    function setDesignationSource(
        uint64 _chainSelector,
        address _registry,
        uint256 _chainId
    )
        external
        onlyMaster
        onlyDelegateCall
    {
        _setSourceChainId(
            designationSourceChainId,
            _chainSelector,
            _registry,
            _chainId,
            keccak256(
                abi.encodeCall(
                    this.setDesignationSource,
                    (
                        _chainSelector,
                        _registry,
                        _chainId
                    )
                )
            )
        );

        emit DesignationSourceSet(
            _chainSelector,
            _registry,
            _chainId
        );
    }

    function _setSourceChainId(
        mapping(uint64 => mapping(address => uint256)) storage _sources,
        uint64 _chainSelector,
        address _sender,
        uint256 _chainId,
        bytes32 _leverHash
    )
        internal
    {
        require(
            _sender != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _chainId != block.chainid,
            SourceOnHubChain()
        );

        uint256 stored = _sources[_chainSelector][_sender];

        require(
            _chainId == 0
                || stored == 0
                || stored == _chainId,
            SourceAlreadySet()
        );

        if (_chainId > 0) {
            _consumeLeverChange(
                _leverHash
            );
        }

        _sources[_chainSelector][_sender] = _chainId;
    }
}
