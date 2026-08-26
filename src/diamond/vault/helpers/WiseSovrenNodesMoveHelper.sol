// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {WiseSovrenNodesBufferHelper} from "./WiseSovrenNodesBufferHelper.sol";

import {IPeerVault} from "../interfaces/IPeerVault.sol";

/**
 * @dev Same-chain vault-to-vault movement. The user calls
 * `moveBetweenVaults` on the source diamond which (a) banks the
 * user's accrued-but-unclaimed interest into `cashedInterest` via the
 * `assignInterest` facet modifier — mirroring `bridgeToVault` — so it
 * stays claimable on the source diamond and never moves, (b) burns
 * `_amount` source vault tokens and relocates the matching deposit-cap
 * budget via `_reduceDepositCap`, keeping source room
 * (`totalDepositCap - totalSupply()`) unchanged, and (c) calls
 * `mintFromPeer` on the destination diamond which raises its cap by
 * the decimal-scaled equivalent and mints it to the same user. No
 * `USD_TOKEN` is moved between diamonds — the share claim is shifted
 * on-chain and the underlying backing is reconciled off-chain by the
 * custodian based on the emitted `MovedOut` / `MovedIn` events.
 * Scale-down rounding loss is surfaced via `MoveDust` so off-chain
 * reconciliation can see the lost dust rather than reasoning about it
 * from event amounts alone.
 *
 * Enabling a peer is timelocked: `proposePeerVault` queues the
 * change, `executePeerVaultChange` activates it after
 * `PEER_VAULT_CHANGE_DELAY`. Disabling is instant via
 * `removePeerVault` so a misbehaving peer can be quarantined
 * without waiting out the delay.
 */
abstract contract WiseSovrenNodesMoveHelper is WiseSovrenNodesBufferHelper {

    function _proposePeerVault(
        address _peer
    )
        internal
    {
        require(
            _peer != ZERO_ADDRESS,
            InvalidValue()
        );

        require(
            _peer != address(this),
            SelfPeerNotAllowed()
        );

        peerVaultChangeQueuedAt[_peer] = block.timestamp;

        emit PeerVaultProposed(
            _peer,
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );
    }

    function _applyPeerVaultChange(
        address _peer
    )
        internal
    {
        uint256 queuedAt = peerVaultChangeQueuedAt[_peer];

        require(
            queuedAt > 0,
            NoPeerVaultChangeProposed()
        );

        require(
            block.timestamp >= queuedAt + PEER_VAULT_CHANGE_DELAY,
            PeerVaultTimelockNotElapsed()
        );

        peerVault[_peer] = true;
        peerVaultChangeQueuedAt[_peer] = 0;

        emit PeerVaultSet(
            _peer,
            true
        );
    }

    function _cancelPeerVaultChange(
        address _peer
    )
        internal
    {
        require(
            peerVaultChangeQueuedAt[_peer] > 0,
            NoPeerVaultChangeProposed()
        );

        peerVaultChangeQueuedAt[_peer] = 0;

        emit PeerVaultProposalCancelled(
            _peer
        );
    }

    function _removePeerVault(
        address _peer
    )
        internal
    {
        peerVault[_peer] = false;
        peerVaultChangeQueuedAt[_peer] = 0;

        emit PeerVaultSet(
            _peer,
            false
        );
    }

    function _executeMoveOut(
        address _dstVault,
        uint256 _amount
    )
        internal
        returns (uint256 dstAmount)
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        require(
            _dstVault != ZERO_ADDRESS,
            InvalidValue()
        );

        require(
            _dstVault != address(this),
            SelfPeerNotAllowed()
        );

        require(
            peerVault[_dstVault] == true,
            PeerVaultNotEnabled()
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
        ) = _scaleAmountForPeer(
            _dstVault,
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

        emit MovedOut(
            msg.sender,
            _dstVault,
            _amount,
            dstAmount
        );

        if (dust > 0) {
            emit MoveDust(
                msg.sender,
                _dstVault,
                dust
            );
        }

        IPeerVault(_dstVault).mintFromPeer(
            msg.sender,
            dstAmount
        );
    }

    /**
     * @dev Same-chain move-in, mirroring `_executeBridgeReceive`. The shares
     * were burned on a registered peer vault (`_executeMoveOut`, which took
     * the matching deposit-cap budget out of that peer), so they are
     * relocation, not new local origination: the cap is raised by the moved
     * amount via `_raiseDepositCap` before the mint, keeping the move
     * room-neutral on both ends and never reverting `DepositExceedCap` on a
     * near-cap destination (BRG-5 / NI-2).
     */
    function _executeMintFromPeer(
        address _user,
        uint256 _amount
    )
        internal
    {
        require(
            peerVault[msg.sender] == true,
            NotPeerVault()
        );

        require(
            _amount > 0,
            InvalidValue()
        );

        _raiseDepositCap(
            _amount
        );

        _mint(
            _user,
            _amount
        );

        emit MovedIn(
            _user,
            msg.sender,
            _amount
        );
    }

    function _scaleAmountForPeer(
        address _dstVault,
        uint256 _srcAmount
    )
        internal
        view
        returns (
            uint256 dstAmount,
            uint256 dust
        )
    {
        uint8 srcDec = decimalsSet;

        uint8 dstDec = IERC20Metadata(
            _dstVault
        ).decimals();

        if (srcDec == dstDec) {
            return (
                _srcAmount,
                0
            );
        }

        if (dstDec > srcDec) {
            return (
                _srcAmount * (10 ** (dstDec - srcDec)),
                0
            );
        }

        uint256 factor = 10 ** (srcDec - dstDec);

        dstAmount = _srcAmount / factor;
        dust = _srcAmount % factor;
    }

    function _getMoveableBalance(
        address _user
    )
        internal
        view
        returns (uint256)
    {
        return balanceOf(
            _user
        );
    }
}
