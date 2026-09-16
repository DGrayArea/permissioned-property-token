// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Drives the vault through arbitrary sequences of distributions, claims,
///      transfers, closes and time jumps. Expected reverts (claiming twice,
///      closing early, claiming nothing) are swallowed so the fuzzer keeps
///      making progress rather than stalling on them.
contract Handler is Test {
    PropertyToken public token;
    DistributionVault public vault;
    MockUSDC public usdc;
    address[3] public actors;

    constructor(PropertyToken token_, DistributionVault vault_, MockUSDC usdc_, address[3] memory actors_) {
        token = token_;
        vault = vault_;
        usdc = usdc_;
        actors = actors_;
    }

    function distribute(uint96 amount) external {
        uint256 amt = bound(uint256(amount), 0, 1_000_000e6);
        usdc.mint(address(this), amt);
        usdc.approve(address(vault), amt);
        try vault.distribute(amt) {} catch {}
    }

    function claim(uint8 actorSeed, uint8 idSeed) external {
        uint256 count = vault.distributionCount();
        if (count == 0) return;
        address actor = actors[actorSeed % 3];
        uint256 id = idSeed % count;
        vm.prank(actor);
        try vault.claim(id) {} catch {}
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint96 amount) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        if (from == to) return;
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        uint256 amt = bound(uint256(amount), 1, balance);
        vm.prank(from);
        try token.transfer(to, amt) {} catch {}
    }

    function close(uint8 idSeed) external {
        uint256 count = vault.distributionCount();
        if (count == 0) return;
        try vault.close(idSeed % count) {} catch {}
    }

    function skipTime(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(uint256(seconds_), 1, 45 days));
    }
}

/// @notice The properties that must hold no matter what order things happen in.
contract VaultInvariantTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();

        _issue(alice, 500_000e18);
        _issue(bob, 300_000e18);
        _issue(carol, 200_000e18);

        handler = new Handler(token, vault, usdc, [alice, bob, carol]);

        vm.prank(issuer);
        vault.transferOwnership(address(handler));

        targetContract(address(handler));
    }

    /// @notice The vault can never pay out more than it took in. This is the
    ///         one that matters: every rounding decision, every carry-forward,
    ///         every re-claim attempt has to respect it.
    function invariant_NeverPaysOutMoreThanItTookIn() public view {
        assertLe(vault.totalPaid(), vault.totalDeposited());
    }

    /// @notice Every unit deposited is either still held or has been paid to a
    ///         holder. Nothing leaks, nothing is conjured.
    function invariant_VaultBalanceMatchesUnpaidRemainder() public view {
        assertEq(usdc.balanceOf(address(vault)), vault.totalDeposited() - vault.totalPaid());
    }

    /// @notice Per-distribution accounting sums to the global figure.
    function invariant_ClaimedSumsAcrossDistributions() public view {
        uint256 count = vault.distributionCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += vault.distributionAt(i).claimed;
        }
        assertEq(sum, vault.totalPaid());
    }

    /// @notice No distribution can pay out more than its own pool.
    function invariant_NoDistributionOverspendsItsPool() public view {
        uint256 count = vault.distributionCount();
        for (uint256 i; i < count; ++i) {
            DistributionVault.Distribution memory d = vault.distributionAt(i);
            assertLe(d.claimed, d.pool);
        }
    }

    /// @notice Supply is conserved: the compliance gate must never mint or burn
    ///         as a side effect of a denied or permitted transfer.
    function invariant_SupplyIsConserved() public view {
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol),
            token.totalSupply()
        );
    }
}
