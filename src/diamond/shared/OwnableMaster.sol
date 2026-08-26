// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

error NoValue();

error NotMaster();

error NotProposed();

/**
 * @dev Two-step ownership transfer, ported verbatim from
 * `src/legacy/OwnableMasterLegacy.sol`. Storage layout is identical
 * (slots 0 and 1) so a diamond inheriting this contract reproduces
 * the legacy slot ordering for the master/proposedMaster pair.
 */
contract OwnableMaster {

    address public master;

    address public proposedMaster;

    address internal constant ZERO_ADDRESS = address(0x0);

    event MasterProposed(
        address indexed proposer,
        address indexed proposedMaster
    );

    event RenouncedOwnership(
        address indexed previousMaster
    );

    modifier onlyProposed() {
        _onlyProposed();
        _;
    }

    modifier onlyMaster() {
        _onlyMaster();
        _;
    }

    function _onlyMaster()
        private
        view
    {
        if (msg.sender == master) {
            return;
        }

        revert NotMaster();
    }

    function _onlyProposed()
        private
        view
    {
        if (msg.sender == proposedMaster) {
            return;
        }

        revert NotProposed();
    }

    constructor(
        address _master
    ) {
        if (_master == ZERO_ADDRESS) {
            revert NoValue();
        }

        master = _master;
    }

    function proposeOwner(
        address _proposedOwner
    )
        external
        onlyMaster
    {
        if (_proposedOwner == ZERO_ADDRESS) {
            revert NoValue();
        }

        proposedMaster = _proposedOwner;

        emit MasterProposed(
            msg.sender,
            _proposedOwner
        );
    }

    function claimOwnership()
        external
        onlyProposed
    {
        master = msg.sender;
    }

    function renounceOwnership()
        external
        onlyMaster
    {
        master = ZERO_ADDRESS;
        proposedMaster = ZERO_ADDRESS;

        emit RenouncedOwnership(
            msg.sender
        );
    }
}
