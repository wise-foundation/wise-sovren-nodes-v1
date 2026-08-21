// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Vault configuration storage shard. USD_TOKEN sits in storage
 * (was `immutable` in legacy) so it survives DELEGATECALL into
 * facets.
 */
abstract contract ConfigDeclaration {

    IERC20 public USD_TOKEN;

    uint256 public interestRate;

    uint8 internal decimalsSet;

    address public thirdPartyAddress;

    address public InterestRateProxy;

    address public currentProxyBenefactor;

    bool public supplyChangeByOwnerNotAllowed;

    uint256 public totalDepositCap;

    bytes4 public constant IERC20Decimals = bytes4(keccak256("decimals()"));

    uint256 internal constant SECONDS_IN_YEAR = 31_540_000;

    uint256 internal constant PRECISION_RATE = 10_000;

    uint256 internal constant PRECISION_FACTOR_E18 = 1e18;

    uint256 internal constant MAX_INTEREST_RATE = 20_000;
}
