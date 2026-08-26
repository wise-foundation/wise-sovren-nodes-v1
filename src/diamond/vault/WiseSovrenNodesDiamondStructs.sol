// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Struct-wrapped constructor arguments for the WiseSovrenNodes
 * diamond. Solidity's stack only fits seven or so locals plus the
 * EVM scratch slots, so the legacy 11-arg constructor was already
 * close to the limit; adding the worker role pushed it over. Passing
 * one memory pointer keeps stack pressure flat and matches the
 * shape callers want anyway.
 */
struct WiseSovrenNodesInitParams {
    address usdAddress;
    address thirdPartyAddress;
    address workerAddress;
    address oldVault;
    address[] initialDistributionAddresses;
    uint256[] initialDistributionAmounts;
    uint256 totalDepositCap;
    uint256 interestRate;
    uint8 decimalsValue;
    string tokenName;
    string tokenSymbol;
}
