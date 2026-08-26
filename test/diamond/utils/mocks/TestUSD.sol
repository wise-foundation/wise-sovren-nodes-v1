// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Throwaway stablecoin stand-in for the testnet ForwardVault
 * deployment. Six decimals like USDC/USDT and openly mintable so the
 * deployer can fund the vault and simulate user liquidity while the
 * UI is wired up. Not for mainnet.
 */
contract TestUSD is ERC20 {

    uint8 internal immutable DECIMALS;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    )
        ERC20(_name, _symbol)
    {
        DECIMALS = _decimals;
    }

    function decimals()
        public
        view
        override
        returns (uint8)
    {
        return DECIMALS;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}
