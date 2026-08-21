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
        int256[] memory allowed = new int256[](17);
        allowed[0] = 0;
        allowed[1] = 100;
        allowed[2] = 200;
        allowed[3] = 300;
        allowed[4] = 500;
        allowed[5] = 1000;
        allowed[6] = 1500;
        allowed[7] = 2500;
        allowed[8] = 5000;
        allowed[9] = -100;
        allowed[10] = -200;
        allowed[11] = -300;
        allowed[12] = -500;
        allowed[13] = -1000;
        allowed[14] = -1500;
        allowed[15] = -2500;
        allowed[16] = -5000;

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
            _params.interestRate == 0
                || _params.totalDepositCap == 0
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
