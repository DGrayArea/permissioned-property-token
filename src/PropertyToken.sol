// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Compliance} from "./Compliance.sol";

/// @title PropertyToken
/// @notice A permissioned ERC-20 representing beneficial interest in an SPV
///         holding one property.
///
/// @dev This is fungible, not an NFT. A holder's stake is their balance as a
///      fraction of total supply; there are no token ids and no per-unit
///      identity.
///
///      Two behaviours beyond a plain ERC-20:
///
///      1. Every movement of value passes through the compliance gate, which is
///         what makes the token unlistable on open venues — an arbitrary buyer
///         has no verified identity, so a marketplace's `transferFrom` reverts.
///         That is the design working, not failing (ADR-007).
///
///      2. Balances are checkpointed so a distribution can pay against a record
///         date rather than against live balances (ADR-004). OpenZeppelin
///         removed `ERC20Snapshot` in v5; this is a minimal equivalent, kept
///         in-repo and deliberately small enough to audit by reading.
contract PropertyToken is ERC20, Ownable {
    struct Checkpoint {
        uint64 id;
        uint192 value;
    }

    /// @notice Total units representing 100% of the SPV. Fixed at deployment.
    uint256 public immutable maxSupply;

    Compliance public immutable compliance;

    /// @notice Address permitted to open a new snapshot (the distribution vault).
    address public distributor;

    uint64 private _currentSnapshotId;
    mapping(address account => Checkpoint[]) private _accountCheckpoints;
    Checkpoint[] private _supplyCheckpoints;

    event DistributorSet(address indexed distributor);
    event Snapshot(uint64 indexed id);

    error NotCompliant(Compliance.Denial denial);
    error MaxSupplyExceeded(uint256 attempted, uint256 remaining);
    error NotDistributor(address caller);
    error NonexistentSnapshot(uint64 id);
    error ZeroAddress();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address initialOwner,
        Compliance compliance_
    ) ERC20(name_, symbol_) Ownable(initialOwner) {
        if (address(compliance_) == address(0)) revert ZeroAddress();
        maxSupply = maxSupply_;
        compliance = compliance_;
    }

    // ----------------------------------------------------------------- issuance

    /// @notice Primary issuance to a verified, accredited investor.
    function issue(address to, uint256 amount) external onlyOwner {
        uint256 remaining = maxSupply - totalSupply();
        if (amount > remaining) revert MaxSupplyExceeded(amount, remaining);
        _mint(to, amount);
    }

    // ---------------------------------------------------------------- snapshots

    function setDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    /// @notice Open a new snapshot and return its id. This is the record date.
    function snapshot() external returns (uint64) {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor(msg.sender);
        unchecked {
            _currentSnapshotId += 1;
        }
        emit Snapshot(_currentSnapshotId);
        return _currentSnapshotId;
    }

    function currentSnapshotId() external view returns (uint64) {
        return _currentSnapshotId;
    }

    function balanceOfAt(address account, uint64 snapshotId) public view returns (uint256) {
        (bool found, uint256 value) = _valueAt(snapshotId, _accountCheckpoints[account]);
        return found ? value : balanceOf(account);
    }

    function totalSupplyAt(uint64 snapshotId) public view returns (uint256) {
        (bool found, uint256 value) = _valueAt(snapshotId, _supplyCheckpoints);
        return found ? value : totalSupply();
    }

    // ------------------------------------------------------------------ internal

    function _update(address from, address to, uint256 value) internal override {
        // Gate first. A denied transfer must not leave a checkpoint behind.
        Compliance.Denial denial;
        if (from == address(0)) {
            denial = compliance.checkMint(to, value);
        } else if (to != address(0)) {
            denial = compliance.checkTransfer(from, to, value);
        }
        if (denial != Compliance.Denial.None) revert NotCompliant(denial);

        // Record pre-change values against the open snapshot, if any.
        if (from == address(0)) {
            _writeSupplyCheckpoint();
            _writeAccountCheckpoint(to);
        } else if (to == address(0)) {
            _writeSupplyCheckpoint();
            _writeAccountCheckpoint(from);
        } else {
            _writeAccountCheckpoint(from);
            _writeAccountCheckpoint(to);
        }

        super._update(from, to, value);
    }

    function _writeAccountCheckpoint(address account) private {
        _write(_accountCheckpoints[account], balanceOf(account));
    }

    function _writeSupplyCheckpoint() private {
        _write(_supplyCheckpoints, totalSupply());
    }

    /// @dev Push the value as it stood *before* the pending change, but only
    ///      once per snapshot — the first write after a snapshot opens is the
    ///      one that captures the record-date value.
    function _write(Checkpoint[] storage checkpoints, uint256 currentValue) private {
        uint64 current = _currentSnapshotId;
        uint256 length = checkpoints.length;
        uint64 last = length == 0 ? 0 : checkpoints[length - 1].id;
        if (last < current) {
            checkpoints.push(Checkpoint({id: current, value: uint192(currentValue)}));
        }
    }

    /// @dev Binary search for the first checkpoint at or after `snapshotId`.
    ///      No checkpoint means the value has not changed since, so the caller
    ///      falls back to the live value.
    function _valueAt(uint64 snapshotId, Checkpoint[] storage checkpoints)
        private
        view
        returns (bool found, uint256 value)
    {
        if (snapshotId == 0 || snapshotId > _currentSnapshotId) revert NonexistentSnapshot(snapshotId);

        uint256 low = 0;
        uint256 high = checkpoints.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (checkpoints[mid].id < snapshotId) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low == checkpoints.length) return (false, 0);
        return (true, checkpoints[low].value);
    }
}
