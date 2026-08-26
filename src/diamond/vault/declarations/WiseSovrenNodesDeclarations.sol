// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OwnableMaster} from "../../shared/OwnableMaster.sol";

import {WiseSovrenNodesDiamondEvents} from "../WiseSovrenNodesDiamondEvents.sol";
import {WiseSovrenNodesDiamondErrors} from "../WiseSovrenNodesDiamondErrors.sol";
import {WiseSovrenNodesInitParams} from "../WiseSovrenNodesDiamondStructs.sol";
import {WiseSovrenNodesIncentiveLadder} from "../WiseSovrenNodesIncentiveLadder.sol";

import {ConfigDeclaration} from "./ConfigDeclaration.sol";
import {UserStateDeclaration} from "./UserStateDeclaration.sol";
import {ProxyDeclaration} from "./ProxyDeclaration.sol";
import {WorkerDeclaration} from "./WorkerDeclaration.sol";
import {PeerVaultDeclaration} from "./PeerVaultDeclaration.sol";
import {SelectorRoutingDeclaration} from "./SelectorRoutingDeclaration.sol";
import {QueueStateDeclaration} from "./QueueStateDeclaration.sol";
import {QueueConfigDeclaration} from "./QueueConfigDeclaration.sol";
import {CrossChainDeclaration} from "./CrossChainDeclaration.sol";
import {WiseDeclaration} from "./WiseDeclaration.sol";
import {BridgeReplayDeclaration} from "./BridgeReplayDeclaration.sol";
import {ThirdPartyDeclaration} from "./ThirdPartyDeclaration.sol";
import {TransferHookDeclaration} from "./TransferHookDeclaration.sol";
import {BurnWiseRotationDeclaration} from "./BurnWiseRotationDeclaration.sol";
import {ReferralDeclaration} from "./ReferralDeclaration.sol";
import {DepositGateDeclaration} from "./DepositGateDeclaration.sol";
import {GracePeriodDeclaration} from "./GracePeriodDeclaration.sol";
import {DepositHookDeclaration} from "./DepositHookDeclaration.sol";
import {DepositAccumDeclaration} from "./DepositAccumDeclaration.sol";
import {CashedInterestTotalDeclaration} from "./CashedInterestTotalDeclaration.sol";
import {SweeperDeclaration} from "./SweeperDeclaration.sol";
import {DepositAccumPrevDeclaration} from "./DepositAccumPrevDeclaration.sol";
import {HookGuardDeclaration} from "./HookGuardDeclaration.sol";
import {InterestRemainderDeclaration} from "./InterestRemainderDeclaration.sol";

/**
 * @title WiseSovrenNodesDeclarations
 * @dev Storage composer for the WiseSovrenNodes diamond. Inherits, in
 * order: OwnableMaster, Pausable, ReentrancyGuard, ERC20, then the
 * vault-specific shards — matching the legacy slot ordering for the
 * shared bases. USD_TOKEN sits in storage rather than `immutable`
 * because immutables don't survive DELEGATECALL into facets.
 *
 * The rate validator rejects only a rate above `MAX_INTEREST_RATE`;
 * a genesis rate of zero is deliberately legal and safe by
 * construction, since the rate is only ever a multiplier and never a
 * divisor: at zero, `_assignInterest` banks nothing and merely
 * restamps `lastSyncTimeStamp`, and the sweep reserve degenerates to
 * exactly `totalCashedInterest`. `bufferInterestRate` starts at the
 * genesis rate and only ever ratchets up, so lowering the user rate
 * never shrinks the sweep reserve.
 *
 * Accrual is measured from each holder's own `lastSyncTimeStamp` and
 * `setInterestRate` writes no checkpoint, so a rate change is a
 * plain master call and a holder's un-banked window is priced at
 * whatever rate is current when it banks. When that window should be
 * preserved at the outgoing rate across a change, the interest-admin
 * facet's `syncInterestBulk` banks it first.
 *
 * The constructor seeds only the discount half of the incentive
 * ladder. The premium half is 245 further lanes, and writing them
 * here would cost roughly 5.4 million gas inside the one transaction
 * that also creates the diamond and wires every selector, pushing
 * that transaction over the 16,777,216 gas ceiling a single
 * transaction may not exceed. The premium lanes are therefore opened
 * by the master through `setIncentivesAllowed` in a following
 * transaction, before the setup is finalised. Both halves come from
 * the same ladder library, so the two paths cannot describe
 * different ladders.
 */
abstract contract WiseSovrenNodesDeclarations is
    WiseSovrenNodesDiamondEvents,
    WiseSovrenNodesDiamondErrors,
    OwnableMaster,
    Pausable,
    ReentrancyGuard,
    ERC20,
    ConfigDeclaration,
    UserStateDeclaration,
    ProxyDeclaration,
    WorkerDeclaration,
    PeerVaultDeclaration,
    SelectorRoutingDeclaration,
    QueueStateDeclaration,
    QueueConfigDeclaration,
    CrossChainDeclaration,
    WiseDeclaration,
    BridgeReplayDeclaration,
    ThirdPartyDeclaration,
    TransferHookDeclaration,
    BurnWiseRotationDeclaration,
    ReferralDeclaration,
    DepositGateDeclaration,
    GracePeriodDeclaration,
    DepositHookDeclaration,
    DepositAccumDeclaration,
    CashedInterestTotalDeclaration,
    SweeperDeclaration,
    DepositAccumPrevDeclaration,
    HookGuardDeclaration,
    InterestRemainderDeclaration
{

    constructor(
        WiseSovrenNodesInitParams memory _params
    )
        OwnableMaster(msg.sender)
        ERC20(
            _params.tokenName,
            _params.tokenSymbol
        )
    {
        _validateConstructorInputs(
            _params
        );

        USD_TOKEN = IERC20(
            _params.usdAddress
        );

        thirdPartyAddress = _params.thirdPartyAddress;
        workerAddress = _params.workerAddress;
        totalDepositCap = _params.totalDepositCap;
        interestRate = _params.interestRate;
        bufferInterestRate = _params.interestRate;
        decimalsSet = _params.decimalsValue;

        InterestRateProxy = address(this);

        _seedSweepers(
            _params.workerAddress,
            _params.thirdPartyAddress
        );

        _performInitialMinting(
            _params.initialDistributionAddresses,
            _params.initialDistributionAmounts
        );

        _migrateInterest(
            _params.oldVault,
            _params.initialDistributionAddresses
        );

        _initializeIncentives();

        minDepositAmount = 50
            * 10
            ** decimalsSet;

        gracePeriodDuration = 45 days;

        graceThresholdAmount = 10_000
            * 10
            ** decimalsSet;
    }

    function _initializeIncentives()
        internal
    {
        int256[] memory allowed = WiseSovrenNodesIncentiveLadder.positiveIncentives();

        for (uint256 i = 0; i < allowed.length; i++) {
            incentiveAllowed[allowed[i]] = true;
        }
    }

    function _validateConstructorInputs(
        WiseSovrenNodesInitParams memory _params
    )
        internal
        pure
    {
        if (
            _params.totalDepositCap == 0
                || _params.usdAddress == ZERO_ADDRESS
                || _params.thirdPartyAddress == ZERO_ADDRESS
                || _params.workerAddress == ZERO_ADDRESS
        ) {
            revert InvalidValue();
        }

        if (_params.interestRate > MAX_INTEREST_RATE) {
            revert InterestRateTooHigh();
        }
    }

    function _performInitialMinting(
        address[] memory _initialDistributionAddresses,
        uint256[] memory _initialDistributionAmounts
    )
        internal
    {
        for (uint256 i = 0; i < _initialDistributionAddresses.length; i++) {
            if (totalSupply() + _initialDistributionAmounts[i] > totalDepositCap) {
                revert DepositExceedCap();
            }

            _mint(
                _initialDistributionAddresses[i],
                _initialDistributionAmounts[i]
            );

            lastSyncTimeStamp[_initialDistributionAddresses[i]] = block.timestamp;
        }
    }

    function _migrateInterest(
        address _oldVault,
        address[] memory _initialDistributionAddresses
    )
        internal
    {
        if (_oldVault != ZERO_ADDRESS) {

            if (_oldVault.code.length == 0) {
                revert OldVaultNoCode();
            }

            for (uint256 i = 0; i < _initialDistributionAddresses.length; i++) {
                (
                    bool ok,
                    bytes memory returnValue
                ) = _oldVault.staticcall(
                    abi.encodeWithSignature(
                        "getTotalInterestUser(address)",
                        _initialDistributionAddresses[i]
                    )
                );

                require(
                    ok,
                    "old vault call failed"
                );

                if (returnValue.length != 32) {
                    revert OldVaultBadResponse();
                }

                uint256 migratedInterest = abi.decode(
                    returnValue,
                    (uint256)
                );

                uint256 previousInterest = cashedInterest[
                    _initialDistributionAddresses[i]
                ];

                cashedInterest[_initialDistributionAddresses[i]] = migratedInterest;

                totalCashedInterest = totalCashedInterest
                    + migratedInterest
                    - previousInterest;
            }

            emit TotalCashedInterestChanged(
                totalCashedInterest
            );
        }
    }

    /**
     * @dev Seeds the sweeper allowlist at genesis: the worker, the
     * third party and the deployer (`msg.sender` — the real owner
     * on a direct deploy, the bootstrap shim on the deterministic
     * CREATE3 path, where the shim grants the pending master and
     * revokes itself before handing off ownership).
     */
    function _seedSweepers(
        address _worker,
        address _thirdParty
    )
        internal
    {
        isSweeper[_worker] = true;

        emit SweeperSet(
            _worker,
            true
        );

        isSweeper[_thirdParty] = true;

        emit SweeperSet(
            _thirdParty,
            true
        );

        isSweeper[msg.sender] = true;

        emit SweeperSet(
            msg.sender,
            true
        );
    }

    /**
     * @dev Returns the per-deployment `decimalsSet`. Lives on the
     * diamond so it's reachable regardless of facet routing.
     */
    function decimals()
        public
        view
        virtual
        override
        returns (uint8)
    {
        return decimalsSet;
    }
}
