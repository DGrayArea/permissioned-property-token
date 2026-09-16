// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PropertyToken} from "./PropertyToken.sol";

/// @title DistributionVault
/// @notice Distributes rental income in a stablecoin, pro rata, against a record
///         date.
/// @dev Balances move between distributions, so paying against live balances
///      would pay a holder who has already sold. Each distribution opens a
///      snapshot and entitlements read that instant. This is the record date the
///      offering documents already use. See ADR-004.
///
///      Claims are pull-based. A reverting recipient cannot block the
///      distribution, and each holder pays their own claim gas.
///
///      Rounding remainder and unclaimed balances are the same problem: money
///      sitting in the vault that nobody has taken. Both roll into the next pool
///      when the claim window closes. Nothing is swept to the issuer, and
///      undistributed() keeps the amount visible.
contract DistributionVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Distribution {
        uint64 snapshotId;
        uint64 closesAt;
        bool closed;
        uint256 pool; // deposited amount plus any carried remainder
        uint256 totalSupplyAt;
        uint256 claimed;
    }

    PropertyToken public immutable token;
    /// @notice Distribution currency. A stablecoin in production.
    IERC20 public immutable currency;

    Distribution[] private _distributions;
    mapping(uint256 distributionId => mapping(address holder => bool)) public hasClaimed;

    /// @notice Remainder carried into the next distribution. Never swept.
    uint256 public undistributed;
    uint256 public totalDeposited;
    uint256 public totalPaid;

    uint64 public claimWindow;

    event Distributed(uint256 indexed id, uint64 indexed snapshotId, uint256 pool, uint256 carriedIn);
    event Claimed(uint256 indexed id, address indexed holder, uint256 amount);
    event DistributionClosed(uint256 indexed id, uint256 carriedOut);
    event ClaimWindowSet(uint64 claimWindow);

    error NothingToDistribute();
    error NoSupply();
    error UnknownDistribution(uint256 id);
    error DistributionAlreadyClosed(uint256 id);
    error WindowStillOpen(uint256 id, uint64 closesAt);
    error AlreadyClaimed(uint256 id, address holder);
    error NothingOwed(uint256 id, address holder);

    constructor(address initialOwner, PropertyToken token_, IERC20 currency_, uint64 claimWindow_)
        Ownable(initialOwner)
    {
        token = token_;
        currency = currency_;
        claimWindow = claimWindow_;
    }

    function setClaimWindow(uint64 claimWindow_) external onlyOwner {
        claimWindow = claimWindow_;
        emit ClaimWindowSet(claimWindow_);
    }

    // ------------------------------------------------------------ distribution

    /// @notice Deposit income and open a distribution against a fresh snapshot.
    /// @dev The caller must have approved `amount` of `currency` to this vault.
    function distribute(uint256 amount) external onlyOwner returns (uint256 id) {
        uint256 carriedIn = undistributed;
        uint256 pool = amount + carriedIn;
        if (pool == 0) revert NothingToDistribute();

        uint64 snapshotId = token.snapshot();
        uint256 supplyAt = token.totalSupplyAt(snapshotId);
        if (supplyAt == 0) revert NoSupply();

        undistributed = 0;
        totalDeposited += amount;

        id = _distributions.length;
        _distributions.push(
            Distribution({
                snapshotId: snapshotId,
                closesAt: uint64(block.timestamp) + claimWindow,
                closed: false,
                pool: pool,
                totalSupplyAt: supplyAt,
                claimed: 0
            })
        );

        if (amount != 0) {
            currency.safeTransferFrom(msg.sender, address(this), amount);
        }

        emit Distributed(id, snapshotId, pool, carriedIn);
    }

    /// @notice A holder's share of a distribution, floored by integer division.
    function entitlement(uint256 id, address holder) public view returns (uint256) {
        if (id >= _distributions.length) revert UnknownDistribution(id);
        Distribution storage d = _distributions[id];
        uint256 balanceAt = token.balanceOfAt(holder, d.snapshotId);
        return (balanceAt * d.pool) / d.totalSupplyAt;
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        if (id >= _distributions.length) revert UnknownDistribution(id);
        Distribution storage d = _distributions[id];
        if (d.closed) revert DistributionAlreadyClosed(id);
        if (hasClaimed[id][msg.sender]) revert AlreadyClaimed(id, msg.sender);

        amount = entitlement(id, msg.sender);
        if (amount == 0) revert NothingOwed(id, msg.sender);

        // Effects before interaction.
        hasClaimed[id][msg.sender] = true;
        d.claimed += amount;
        totalPaid += amount;

        currency.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Close a distribution once its claim window has passed, rolling
    ///         the unclaimed remainder into the next one.
    /// @dev Permissionless: closing can only move value forward for holders,
    ///      never out of the vault, so there is nothing to gate.
    function close(uint256 id) external {
        if (id >= _distributions.length) revert UnknownDistribution(id);
        Distribution storage d = _distributions[id];
        if (d.closed) revert DistributionAlreadyClosed(id);
        if (block.timestamp < d.closesAt) revert WindowStillOpen(id, d.closesAt);

        d.closed = true;
        uint256 remainder = d.pool - d.claimed;
        undistributed += remainder;

        emit DistributionClosed(id, remainder);
    }

    // ------------------------------------------------------------------- views

    function distributionCount() external view returns (uint256) {
        return _distributions.length;
    }

    function distributionAt(uint256 id) external view returns (Distribution memory) {
        if (id >= _distributions.length) revert UnknownDistribution(id);
        return _distributions[id];
    }
}
