// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {WiseSovrenNodesMoveHelper} from "./WiseSovrenNodesMoveHelper.sol";

/**
 * @dev Cross-chain sibling of {WiseSovrenNodesMoveHelper}. Where
 * `moveBetweenVaults` shifts a share claim to a peer vault on the
 * same chain in one transaction, `bridgeToVault` does the same across
 * chains over Chainlink CCIP arbitrary messaging: the source burns
 * the user's shares and sends a data-only message; the destination
 * peer mints the scaled equivalent when CCIP delivers it.
 *
 * The interest handling mirrors the same-chain move helper: the
 * `assignInterest(msg.sender)` modifier on the
 * facet entry banks the user's accrued-but-unclaimed interest into
 * `cashedInterest` and resets `lastSyncTimeStamp` before the burn, so
 * that interest stays claimable on the source chain and is never
 * bridged. On delivery `_executeBridgeReceive` runs the same
 * `_assignInterest` then `_mint`, so the freshly minted balance starts
 * accruing from the arrival timestamp exactly as a normal deposit
 * would — and if the receiver already holds shares, their prior
 * accrual is banked first so forward accrual stays correct.
 *
 * No `USD_TOKEN` crosses chains — the share claim is burned here and
 * minted there, and the underlying backing is reconciled off-chain by
 * the custodian from the emitted `BridgeSent` / `BridgeReceived`
 * events, mirroring the on-chain `MovedOut` / `MovedIn` model.
 *
 * Both directions relocate the deposit-cap budget with the shares:
 * the out-path burns and then lowers `totalDepositCap` by the burned
 * amount via `_reduceDepositCap`, while the receive-path raises
 * `totalDepositCap` by the minted amount via `_raiseDepositCap`
 * before the mint. Local room (`totalDepositCap - totalSupply()`) is
 * therefore invariant under bridging on both ends, the mesh-wide cap
 * sum is conserved by user flows, and the receive-path mint can never
 * exceed the cap — `ccipReceive` has no economic revert path at all
 * (only router, peer, replay and zero-amount guards).
 *
 * Registering a peer is timelocked behind `CROSS_CHAIN_PEER_CHANGE_DELAY`,
 * gated on `initialized` like the selector routing: instant while the
 * mesh is still being wired before `finalizeSetup`, delayed afterwards,
 * so a compromised master cannot instantly point a lane at a malicious
 * vault that would mint unbacked shares. Disabling is instant via
 * `removeCrossChainPeer`.
 */
abstract contract WiseSovrenNodesCrossChainHelper is WiseSovrenNodesMoveHelper {

    function _setCcipRouter(
        address _router
    )
        internal
    {
        require(
            _router != ZERO_ADDRESS,
            InvalidValue()
        );

        require(
            ccipRouter == ZERO_ADDRESS,
            RouterAlreadySet()
        );

        ccipRouter = _router;

        emit CcipRouterSet(
            _router
        );
    }

    function _setReferralEnabled(
        bool _enabled
    )
        internal
    {
        referralEnabled = _enabled;

        emit ReferralEnabledSet(
            _enabled
        );
    }

    function _setBridgeGasLimit(
        uint256 _gasLimit
    )
        internal
    {
        require(
            _gasLimit >= BRIDGE_GAS_LIMIT,
            InvalidBridgeGasLimit()
        );

        require(
            _gasLimit <= MAX_BRIDGE_GAS_LIMIT,
            InvalidBridgeGasLimit()
        );

        bridgeGasLimit = uint64(_gasLimit);

        emit BridgeGasLimitSet(
            _gasLimit
        );
    }

    function _proposeCrossChainPeer(
        uint64 _chainSelector,
        address _peer,
        uint8 _peerDecimals
    )
        internal
    {
        require(
            _chainSelector != 0,
            InvalidValue()
        );

        require(
            _peer != ZERO_ADDRESS,
            InvalidValue()
        );

        proposedCrossChainPeer[_chainSelector] = _peer;
        proposedCrossChainPeerDecimals[_chainSelector] = _peerDecimals;
        crossChainPeerChangeQueuedAt[_chainSelector] = block.timestamp;

        emit CrossChainPeerProposed(
            _chainSelector,
            _peer,
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );
    }

    function _applyCrossChainPeerChange(
        uint64 _chainSelector
    )
        internal
    {
        uint256 queuedAt = crossChainPeerChangeQueuedAt[_chainSelector];

        require(
            queuedAt > 0,
            NoCrossChainPeerChangeProposed()
        );

        if (initialized) {
            require(
                block.timestamp >= queuedAt + CROSS_CHAIN_PEER_CHANGE_DELAY,
                CrossChainPeerTimelockNotElapsed()
            );
        }

        crossChainPeer[_chainSelector] = proposedCrossChainPeer[_chainSelector];
        crossChainPeerDecimals[_chainSelector] = proposedCrossChainPeerDecimals[_chainSelector];
        crossChainPeerEnabled[_chainSelector] = true;

        proposedCrossChainPeer[_chainSelector] = ZERO_ADDRESS;
        proposedCrossChainPeerDecimals[_chainSelector] = 0;
        crossChainPeerChangeQueuedAt[_chainSelector] = 0;

        emit CrossChainPeerSet(
            _chainSelector,
            crossChainPeer[_chainSelector],
            true
        );
    }

    function _cancelCrossChainPeerChange(
        uint64 _chainSelector
    )
        internal
    {
        require(
            crossChainPeerChangeQueuedAt[_chainSelector] > 0,
            NoCrossChainPeerChangeProposed()
        );

        proposedCrossChainPeer[_chainSelector] = ZERO_ADDRESS;
        proposedCrossChainPeerDecimals[_chainSelector] = 0;
        crossChainPeerChangeQueuedAt[_chainSelector] = 0;

        emit CrossChainPeerProposalCancelled(
            _chainSelector
        );
    }

    function _removeCrossChainPeer(
        uint64 _chainSelector
    )
        internal
    {
        crossChainPeerEnabled[_chainSelector] = false;

        proposedCrossChainPeer[_chainSelector] = ZERO_ADDRESS;
        proposedCrossChainPeerDecimals[_chainSelector] = 0;
        crossChainPeerChangeQueuedAt[_chainSelector] = 0;

        emit CrossChainPeerSet(
            _chainSelector,
            crossChainPeer[_chainSelector],
            false
        );
    }

    function _executeBridgeOut(
        uint64 _destChainSelector,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
        returns (
            uint256 dstAmount,
            bytes32 messageId
        )
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        require(
            _referralData.length <= MAX_REFERRAL_BYTES,
            ReferralDataTooLong()
        );

        require(
            ccipRouter != ZERO_ADDRESS,
            RouterNotSet()
        );

        require(
            crossChainPeerEnabled[_destChainSelector] == true,
            CrossChainPeerNotEnabled()
        );

        require(
            msg.sender != InterestRateProxy,
            InterestRateProxyCannotMove()
        );

        require(
            balanceOf(msg.sender) >= _amount,
            InsufficientBalance()
        );

        uint256 dust;

        (
            dstAmount,
            dust
        ) = _scaleAmountForCrossChainPeer(
            crossChainPeerDecimals[_destChainSelector],
            _amount
        );

        require(
            dstAmount > 0,
            MoveAmountTooSmall()
        );

        _burn(
            msg.sender,
            _amount
        );

        _reduceDepositCap(
            _amount
        );

        Client.EVM2AnyMessage memory message = _buildBridgeMessage(
            crossChainPeer[_destChainSelector],
            msg.sender,
            dstAmount,
            _referralData
        );

        uint256 fee = IRouterClient(ccipRouter).getFee(
            _destChainSelector,
            message
        );

        require(
            msg.value >= fee,
            InsufficientBridgeFee()
        );

        messageId = IRouterClient(ccipRouter).ccipSend{value: fee}(
            _destChainSelector,
            message
        );

        emit BridgeSent(
            msg.sender,
            _destChainSelector,
            _amount,
            dstAmount,
            messageId
        );

        if (dust > 0) {
            emit MoveDust(
                msg.sender,
                crossChainPeer[_destChainSelector],
                dust
            );
        }

        _refundExcessFee(
            fee
        );
    }

    function _executeBridgeReceive(
        Client.Any2EVMMessage calldata _message
    )
        internal
    {
        require(
            msg.sender == ccipRouter,
            NotCcipRouter()
        );

        uint64 srcChainSelector = _message.sourceChainSelector;

        address srcPeer = abi.decode(
            _message.sender,
            (address)
        );

        require(
            crossChainPeerEnabled[srcChainSelector] == true,
            CrossChainPeerNotEnabled()
        );

        require(
            crossChainPeer[srcChainSelector] == srcPeer,
            CrossChainPeerMismatch()
        );

        require(
            processedMessageId[_message.messageId] == false,
            MessageAlreadyProcessed()
        );

        processedMessageId[_message.messageId] = true;

        address user;
        uint256 amount;
        bytes memory referralData;

        if (_message.data.length == LEGACY_BRIDGE_PAYLOAD_LENGTH) {
            (
                user,
                amount
            ) = abi.decode(
                _message.data,
                (address, uint256)
            );
        } else {
            (
                user,
                amount,
                referralData
            ) = abi.decode(
                _message.data,
                (address, uint256, bytes)
            );
        }

        require(
            amount > 0,
            InvalidValue()
        );

        _assignInterest(
            user
        );

        _raiseDepositCap(
            amount
        );

        _mint(
            user,
            amount
        );

        emit BridgeReceived(
            user,
            srcChainSelector,
            amount,
            _message.messageId
        );

        if (referralEnabled && referralData.length > 0) {
            emit BridgeReferral(
                user,
                srcChainSelector,
                _message.messageId,
                referralData
            );
        }
    }

    function _quoteBridgeFee(
        uint64 _destChainSelector,
        uint256 _amount,
        bytes memory _referralData
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 dstAmount,
        ) = _scaleAmountForCrossChainPeer(
            crossChainPeerDecimals[_destChainSelector],
            _amount
        );

        Client.EVM2AnyMessage memory message = _buildBridgeMessage(
            crossChainPeer[_destChainSelector],
            msg.sender,
            dstAmount,
            _referralData
        );

        return IRouterClient(ccipRouter).getFee(
            _destChainSelector,
            message
        );
    }

    function _buildBridgeMessage(
        address _peer,
        address _user,
        uint256 _dstAmount,
        bytes memory _referralData
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        uint256 gasLimit = bridgeGasLimit == 0
            ? BRIDGE_GAS_LIMIT
            : bridgeGasLimit;

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_peer),
            data: abi.encode(
                _user,
                _dstAmount,
                _referralData
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: true
                })
            )
        });
    }

    function _scaleAmountForCrossChainPeer(
        uint8 _dstDecimals,
        uint256 _srcAmount
    )
        internal
        view
        returns (
            uint256 dstAmount,
            uint256 dust
        )
    {
        uint8 srcDecimals = decimalsSet;

        if (srcDecimals == _dstDecimals) {
            return (
                _srcAmount,
                0
            );
        }

        if (_dstDecimals > srcDecimals) {
            return (
                _srcAmount * (10 ** (_dstDecimals - srcDecimals)),
                0
            );
        }

        uint256 factor = 10 ** (srcDecimals - _dstDecimals);

        dstAmount = _srcAmount / factor;
        dust = _srcAmount % factor;
    }

    function _refundExcessFee(
        uint256 _fee
    )
        internal
    {
        uint256 refund = msg.value - _fee;

        if (refund == 0) {
            return;
        }

        (
            bool ok,
        ) = payable(msg.sender).call{value: refund}(
            ""
        );

        require(
            ok,
            BridgeRefundFailed()
        );
    }
}
