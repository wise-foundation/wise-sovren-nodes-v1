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
 *
 * Referral attribution: a same-chain move is a
 * system relocation, so the cohort recorder CARRIES the moved slice
 * of referral credit instead of destroying it. The exit path keeps
 * the pre-burn `_cohortSync` (any pre-existing deficit clamps
 * sale-like) and replaces the post-burn sync with `_cohortMoveOut`,
 * which captures the reduction walk's exact slot pairs and stages
 * them in the chain registry before `mintFromPeer` is called; the
 * enter path adds `_cohortMoveIn` after the mint, which drains and
 * replants them at the same slots in the same transaction. The user
 * is by construction the same address on both ends — `mintFromPeer`
 * is always called with `msg.sender` and carries no recipient
 * parameter. Every attribution failure degrades soft (anomaly event,
 * move unaffected); both stubs are inert until `cohortSyncEnabled`.
 * Decimal scaling factors are computed once per move via
 * `_peerScaleFactors` and shared by the amount scaling and the
 * carry's per-component scaling.
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

        (
            uint256 scaleNumerator,
            uint256 scaleDenominator
        ) = _peerScaleFactors(
            _dstVault
        );

        dstAmount = _amount * scaleNumerator / scaleDenominator;

        uint256 dust = _amount - dstAmount * scaleDenominator / scaleNumerator;

        require(
            dstAmount > 0,
            MoveAmountTooSmall()
        );

        _cohortSync(
            msg.sender
        );

        _burn(
            msg.sender,
            _amount
        );

        _cohortMoveOut(
            msg.sender,
            _dstVault,
            _amount,
            scaleNumerator,
            scaleDenominator
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
     * near-cap destination — the same cap-relocation room law the
     * bridge-receive path holds. The pre-mint `_cohortSync`
     * clamps the user's pre-existing deficit against OLD tracked before
     * the balance grows (clamp-before-mint, dip-healing closed); the
     * post-mint `_cohortMoveIn` then replants the attribution the source
     * staged for this move — ordered after the mint so replanted tracked
     * never exceeds the held balance.
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

        _cohortSync(
            _user
        );

        _mint(
            _user,
            _amount
        );

        _cohortMoveIn(
            _user,
            msg.sender
        );

        emit MovedIn(
            _user,
            msg.sender,
            _amount
        );
    }

    function _peerScaleFactors(
        address _dstVault
    )
        internal
        view
        returns (
            uint256 numerator,
            uint256 denominator
        )
    {
        uint8 srcDec = decimalsSet;

        uint8 dstDec = IERC20Metadata(
            _dstVault
        ).decimals();

        if (dstDec >= srcDec) {
            return (
                10 ** (dstDec - srcDec),
                1
            );
        }

        return (
            1,
            10 ** (srcDec - dstDec)
        );
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
