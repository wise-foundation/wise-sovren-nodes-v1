// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Testnet stand-in for the mainnet WISE token. Eighteen decimals
 * like the real token, openly mintable so the deployer can seed the
 * vault, and exposes the same permissionless `burn(uint256)` that the
 * vault's `burnWise` calls — decreasing the caller's balance and
 * totalSupply. Not for mainnet.
 */
contract MockWise is ERC20 {

    constructor()
        ERC20("Mock WISE", "mWISE")
    {}

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

    function burn(
        uint256 _amount
    )
        external
    {
        _burn(
            msg.sender,
            _amount
        );
    }
}
