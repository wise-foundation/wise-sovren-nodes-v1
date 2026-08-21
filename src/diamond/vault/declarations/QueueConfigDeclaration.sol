// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Queue configuration shard for the merged diamond. The vault
 * itself is the custodian and the USD token lives in `USD_TOKEN`
 * (slot 8), so the legacy `forwardVault` / `usdToken` fields are
 * dropped. `PRECISION_RATE` is inherited from {ConfigDeclaration}.
 */
abstract contract QueueConfigDeclaration {

    uint256 public minDepositAmount;

    bool public negativeIncentivesNotAllowed;

    uint256 internal constant MAX_ORDERS_TO_CONSIDER_LIMIT = 100;
}
