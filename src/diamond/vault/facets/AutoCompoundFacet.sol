// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Keeper-driven compounding: a master-allowlisted bot converts
 * an opted-in user's settled interest into shares and keeps
 * `autoCompoundFeeBps` of it as its USD reward. The compound is the
 * audited `compoundInterest` flow plus a fee split: identical
 * modifier order, bucket cleared and net minted before the two USD
 * transfers, and `fee + net` exactly offsets the cleared liability.
 * It stamps the user's grace lock on the minted net. Opting out is
 * always callable. Inherits the full declaration chain because it
 * needs the OZ `_mint` and the remainder-carrying banking.
 */
contract AutoCompoundFacet is FacetBase {

    using SafeERC20 for IERC20;

    constructor()
        FacetBase()
    {}

    modifier onlyAutoCompoundBot() {
        _onlyAutoCompoundBot();
        _;
    }

    modifier autoCompoundOptedIn(
        address _user
    ) {
        _autoCompoundOptedIn(
            _user
        );
        _;
    }

    function _onlyAutoCompoundBot()
        internal
        view
    {
        require(
            isAutoCompoundBot[msg.sender],
            NotAutoCompoundBot()
        );
    }

    function _autoCompoundOptedIn(
        address _user
    )
        internal
        view
    {
        require(
            autoCompoundAllowed[_user],
            AutoCompoundNotAllowed()
        );
    }

    function compoundInterestOnBehalf(
        address _user
    )
        external
        onlyDelegateCall
        whenNotPaused
        nonReentrant
        onlyAutoCompoundBot
        autoCompoundOptedIn(_user)
        assignInterest(_user)
        gracePeriodCheck(_user)
        registerLargeDeposit(_user)
        returns (uint256 netAmount)
    {
        uint256 interest = _prepareClaim(
            _user
        );

        uint256 feeAmount = interest
            * autoCompoundFeeBps
            / PRECISION_RATE;

        netAmount = interest - feeAmount;

        _checkDepositCap(
            netAmount
        );

        _mint(
            _user,
            netAmount
        );

        if (feeAmount > 0) {
            USD_TOKEN.safeTransfer(
                msg.sender,
                feeAmount
            );
        }

        USD_TOKEN.safeTransfer(
            thirdPartyAddress,
            netAmount
        );

        emit CompoundInterestOnBehalf(
            _user,
            msg.sender,
            netAmount,
            feeAmount
        );
    }

    function setAutoCompoundAllowed(
        bool _allowed
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        autoCompoundAllowed[msg.sender] = _allowed;

        emit AutoCompoundAllowedSet(
            msg.sender,
            _allowed
        );
    }

    function setAutoCompoundBot(
        address _bot,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _bot != ZERO_ADDRESS,
            InvalidValue()
        );

        isAutoCompoundBot[_bot] = _allowed;

        emit AutoCompoundBotSet(
            _bot,
            _allowed
        );
    }

    function setAutoCompoundFeeBps(
        uint256 _bps
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            _bps <= MAX_AUTO_COMPOUND_FEE_BPS,
            AutoCompoundFeeTooHigh()
        );

        autoCompoundFeeBps = _bps;

        emit AutoCompoundFeeBpsSet(
            _bps
        );
    }
}
