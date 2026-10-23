// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Storage, events and errors of the per-chain referral registry, a
 * standalone contract (never a facet) whose layout this chain owns
 * outright; OwnableMaster holds slots 0 and 1. The read paths stay plain
 * mapping reads with no gating, because the vault recorder staticcalls them
 * inside the transfer hook. A sync key is `(assignedAt << 8) |
 * originChainRank` and the lower key wins a merge. A vault never repoints
 * its registry once its recorder is armed.
 */
abstract contract ReferralRegistryDeclarations is OwnableMaster {

    uint256 internal constant SYNC_VERSION = 1;

    uint256 internal constant SYNC_PAYLOAD_LENGTH = 160;

    uint256 internal constant KEY_RANK_SHIFT = 8;

    uint256 internal constant KEY_RANK_MASK = (1 << KEY_RANK_SHIFT) - 1;

    uint256 internal constant MAX_CHAIN_RANK = 15;

    uint256 internal constant DEFAULT_MAX_SYNC_RANK = 3;

    uint256 internal constant MAX_SYNC_FUTURE_DRIFT = 1 hours;

    uint256 internal constant SYNC_KEY_FLOOR = 1_700_000_000;

    uint256 internal constant SYNC_KEY_MIRROR = 2 * SYNC_KEY_FLOOR - 1;

    uint256 internal constant SYNC_PEER_CHANGE_DELAY = 3 days;

    uint64 internal constant SYNC_GAS_LIMIT = 300_000;

    uint64 internal constant MAX_SYNC_GAS_LIMIT = 2_000_000;

    uint256 internal constant MAX_SYNC_LANES = 8;

    uint256 internal constant MAX_TRACKED_VAULTS = 8;

    uint256 internal constant PAYOUT_PUSH_VERSION = 2;

    uint256 internal constant PAYOUT_HUB_CHANGE_DELAY = 3 days;

    uint256 internal constant REFERRER_CORRECTION_DELAY = 3 days;

    // The cycle walk has no hop bound; this floor makes a too deep walk
    // revert ReferralWalkGasCap instead of running out of gas mid write.
    uint256 internal constant CYCLE_WALK_GAS_FLOOR = 10_000;

    // ---- Referrer book ----

    mapping(address => address) public referrerOf;

    // ---- Writer allowlist ----

    mapping(address => bool) public allowedVault;

    // ---- Move-carry staging ----

    mapping(address => mapping(address => mapping(address => uint256[]))) internal carryPayload;

    mapping(address => mapping(address => mapping(address => uint256))) internal carryStagedAt;

    // ---- Sync key ----

    mapping(address => uint256) public referrerKey;

    // ---- CCIP wiring ----

    address public ccipRouter;

    bool public syncInitialized;

    uint64 public syncGasLimit;

    // ---- Sync peer table ----

    mapping(uint64 => address) public syncPeer;

    mapping(uint64 => bool) public syncPeerEnabled;

    mapping(uint64 => address) public proposedSyncPeer;

    mapping(uint64 => uint256) public syncPeerChangeQueuedAt;

    // ---- Replay guard ----

    mapping(bytes32 => bool) public processedSyncMessageId;

    // ---- Flip coordination ----

    mapping(address => mapping(address => address)) public pendingFlip;

    address[] internal trackedVaults;

    // ---- Payout designation ----

    mapping(address => address) public payoutAddress;

    mapping(address => uint256) public payoutStamp;

    // ---- Payout hub route ----

    address public payoutHub;

    uint64 public payoutHubChainSelector;

    address public proposedPayoutHub;

    uint64 public proposedPayoutHubChainSelector;

    uint256 public payoutHubChangeQueuedAt;

    // ---- Referrer correction ----

    mapping(address => address) public proposedCorrection;

    mapping(address => uint256) public correctionQueuedAt;

    bool public correctionsLatched;

    bool public seedsLatched;

    // ---- Allowlist timelock ----

    mapping(address => bool) public everAllowedVault;

    mapping(address => uint256) public allowedVaultQueuedAt;

    // ---- Sync quarantine ----

    mapping(uint64 => bool) public syncPeerQuarantined;

    // ---- Router change ----

    address public proposedCcipRouter;

    uint256 public ccipRouterChangeQueuedAt;

    // ---- Correction binding ----

    mapping(address => uint256) public proposedCorrectionKey;

    // ---- Sync rank bound ----

    uint256 public maxSyncRank;

    // ---- Events ----

    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    event VaultAllowedSet(
        address indexed vault,
        bool allowed
    );

    event CarryStaged(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 words
    );

    event CarryConsumed(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 stagedAt
    );

    event ReferralSyncAdopted(
        address indexed user,
        address indexed referrer,
        uint256 syncKey
    );

    event ReferralSyncKeyLowered(
        address indexed user,
        address indexed referrer,
        uint256 oldKey,
        uint256 newKey
    );

    event ReferralSyncFlipped(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    event SyncKeyCollision(
        address indexed user,
        address indexed localReferrer,
        address indexed incomingReferrer,
        uint256 syncKey
    );

    event ReferralMutualDissolved(
        address indexed user,
        address indexed oldReferrer,
        uint256 winnerKey
    );

    event FlipMarked(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipCleared(
        address indexed vault,
        address indexed user,
        address indexed oldReferrer
    );

    event FlipMigrated(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event FlipMigrationDeferred(
        address indexed vault,
        address indexed user,
        address oldReferrer,
        address newReferrer
    );

    event SyncReceived(
        uint64 indexed srcChainSelector,
        bytes32 indexed messageId,
        address indexed user
    );

    event SyncBroadcast(
        address indexed user,
        uint64 indexed destChainSelector,
        address indexed referrer,
        uint256 syncKey,
        bytes32 messageId
    );

    event CcipRouterSet(
        address indexed router
    );

    event SyncGasLimitSet(
        uint64 gasLimit
    );

    event MaxSyncRankRaised(
        uint256 rank
    );

    event SyncPeerProposed(
        uint64 indexed chainSelector,
        address indexed peer,
        uint256 queuedAt
    );

    event SyncPeerSet(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerProposalCancelled(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncPeerRemoved(
        uint64 indexed chainSelector,
        address indexed peer
    );

    event SyncSetupFinalized();

    event PayoutAddressSet(
        address indexed owner,
        address indexed payout,
        uint256 stamp
    );

    event PayoutPushed(
        address indexed owner,
        uint64 indexed destChainSelector,
        address payout,
        uint256 stamp,
        bytes32 messageId
    );

    event PayoutHubProposed(
        address indexed hub,
        uint64 chainSelector,
        uint256 queuedAt
    );

    event PayoutHubSet(
        address indexed hub,
        uint64 chainSelector
    );

    event PayoutHubProposalCancelled(
        address indexed hub
    );

    event ReferralCorrectionProposed(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 queuedAt
    );

    event ReferralCorrectionCancelled(
        address indexed user,
        address indexed newReferrer,
        address indexed cancelledBy
    );

    event ReferralCorrectionExecuted(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 syncKey
    );

    event CorrectionsLatched();

    event SeedsLatched();

    event VaultAllowProposed(
        address indexed vault,
        uint256 queuedAt
    );

    event VaultAllowProposalCancelled(
        address indexed vault
    );

    event SyncPeerQuarantined(
        uint64 indexed chainSelector
    );

    event SyncPeerQuarantineLifted(
        uint64 indexed chainSelector
    );

    event CcipRouterProposed(
        address indexed router,
        uint256 queuedAt
    );

    event CcipRouterProposalCancelled(
        address indexed router
    );

    // ---- Errors ----

    error NotAllowedVault();

    error ZeroAddress();

    error SelfReferral();

    error InvalidReferrer();

    error ReferralWalkGasCap();

    error CarryPayloadInvalid();

    error NotCcipRouter();

    error SyncPeerNotEnabled();

    error SyncPeerMismatch();

    error SyncAlreadyProcessed();

    error SyncPayloadInvalid();

    error SyncKeyInvalid();

    error NothingToSync();

    error TooManySyncLanes();

    error InsufficientSyncFee();

    error RouterNotSet();

    error RouterAlreadySet();

    error SyncSetupAlreadyFinalized();

    error SyncPeerTimelockNotElapsed();

    error NoSyncPeerProposed();

    error InvalidSyncGasLimit();

    error InvalidChainRank();

    error TooManyTrackedVaults();

    error SyncRefundFailed();

    error NothingToPush();

    error PayoutHubNotSet();

    error NoPayoutHubProposed();

    error PayoutHubTimelockNotElapsed();

    error InvalidPayoutHub();

    error InsufficientPushFee();

    error PushRefundFailed();

    error CorrectionsDisabled();

    error CorrectionsAlreadyLatched();

    error NothingToCorrect();

    error NoCorrectionProposed();

    error CorrectionTimelockNotElapsed();

    error NotCorrectionParty();

    error SeedsAlreadyLatched();

    error VaultNotTracked();

    error NoVaultAllowProposed();

    error VaultAllowTimelockNotElapsed();

    error NoCcipRouterProposed();

    error CcipRouterTimelockNotElapsed();

    error PayoutStampNotNewer();

    error InvalidPayoutOwner();

    error CorrectionKeyNotLower();

    error WrongCorrectionChain();
}
