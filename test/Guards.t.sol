// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {Compliance} from "../src/Compliance.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Privileged entry points and the rejection paths around them.
contract GuardsTest is Base {
    // --------------------------------------------------------------- the token

    function test_Issue_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.issue(alice, 1e18);
    }

    /// @dev Only the vault opens record dates. An attacker who could snapshot
    ///      at will could shift every holder's entitlement.
    function test_Snapshot_RevertsFor_UnauthorisedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NotDistributor.selector, alice));
        vm.prank(alice);
        token.snapshot();
    }

    function test_Snapshot_AllowedFor_OwnerAndDistributor() public {
        vm.prank(issuer);
        assertEq(token.snapshot(), 1);

        vm.prank(address(vault));
        assertEq(token.snapshot(), 2);
    }

    function test_SetDistributor_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.setDistributor(alice);
    }

    function test_SetDistributor_RevertsFor_ZeroAddress() public {
        vm.expectRevert(PropertyToken.ZeroAddress.selector);
        vm.prank(issuer);
        token.setDistributor(address(0));
    }

    function test_BalanceOfAt_RevertsFor_NonexistentSnapshot() public {
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NonexistentSnapshot.selector, uint64(0)));
        token.balanceOfAt(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NonexistentSnapshot.selector, uint64(1)));
        token.balanceOfAt(alice, 1);
    }

    function test_TotalSupplyAt_TracksIssuanceAcrossSnapshots() public {
        _issue(alice, 100e18);

        vm.prank(issuer);
        uint64 first = token.snapshot();

        _issue(bob, 50e18);

        assertEq(token.totalSupplyAt(first), 100e18);
        assertEq(token.totalSupply(), 150e18);
    }

    /// @dev Repeated snapshots without intervening activity all read the same
    ///      balances — no checkpoint is written until something changes.
    function test_Snapshots_WithoutActivity_ReadIdentically() public {
        _issue(alice, 100e18);

        vm.startPrank(issuer);
        uint64 a = token.snapshot();
        uint64 b = token.snapshot();
        vm.stopPrank();

        assertEq(token.balanceOfAt(alice, a), 100e18);
        assertEq(token.balanceOfAt(alice, b), 100e18);
    }

    // ---------------------------------------------------------- the compliance

    function test_SetToken_OnlyOnce() public {
        vm.expectRevert(Compliance.TokenAlreadySet.selector);
        vm.prank(issuer);
        compliance.setToken(IERC20(address(0xdead)));
    }

    function test_ComplianceSetters_OnlyOwner() public {
        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);

        vm.expectRevert(err);
        compliance.setCountryAllowed(US, false);
        vm.expectRevert(err);
        compliance.setPaused(true);
        vm.expectRevert(err);
        compliance.setLockupEnd(uint64(block.timestamp + 1 days));
        vm.expectRevert(err);
        compliance.setMaxHolderBalance(1);
        vm.expectRevert(err);
        compliance.setPolicy(false, false);
        vm.stopPrank();
    }

    function test_Mint_RevertsWhenPaused() public {
        vm.prank(issuer);
        compliance.setPaused(true);

        _expectDenial(Compliance.Denial.Paused);
        vm.prank(issuer);
        token.issue(alice, 1e18);
    }

    function test_Mint_RevertsWhen_HolderCapExceeded() public {
        vm.prank(issuer);
        compliance.setMaxHolderBalance(10e18);

        _expectDenial(Compliance.Denial.HolderCapExceeded);
        vm.prank(issuer);
        token.issue(alice, 11e18);
    }

    function test_Transfer_RevertsFor_UnregisteredSender() public {
        // mallory holds nothing, but the sender check precedes the balance check
        _expectDenial(Compliance.Denial.SenderNotRegistered);
        vm.prank(mallory);
        token.transfer(alice, 0);
    }

    // ---------------------------------------------------------------- the vault

    function test_Distribute_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.distribute(1);
    }

    function test_Distribute_RevertsWhen_NothingToDistribute() public {
        _issue(alice, 100e18);
        vm.expectRevert(DistributionVault.NothingToDistribute.selector);
        vm.prank(issuer);
        vault.distribute(0);
    }

    /// @dev Income arriving before any tokens exist would divide by zero.
    function test_Distribute_RevertsWhen_NoSupply() public {
        usdc.mint(issuer, 100e6);
        vm.startPrank(issuer);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DistributionVault.NoSupply.selector);
        vault.distribute(100e6);
        vm.stopPrank();
    }

    function test_SetClaimWindow_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setClaimWindow(1 days);
    }

    function test_UnknownDistribution_RevertsEverywhere() public {
        vm.expectRevert(abi.encodeWithSelector(DistributionVault.UnknownDistribution.selector, uint256(0)));
        vault.entitlement(0, alice);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.UnknownDistribution.selector, uint256(0)));
        vm.prank(alice);
        vault.claim(0);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.UnknownDistribution.selector, uint256(0)));
        vault.close(0);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.UnknownDistribution.selector, uint256(0)));
        vault.distributionAt(0);
    }

    function test_Close_RevertsOnSecondAttempt() public {
        _issue(alice, 100e18);
        uint256 id = _distribute(1_000e6);

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(id);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.DistributionAlreadyClosed.selector, id));
        vault.close(id);
    }

    function test_Claim_RevertsFor_NonHolder() public {
        _issue(alice, 100e18);
        uint256 id = _distribute(1_000e6);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.NothingOwed.selector, id, bob));
        vm.prank(bob);
        vault.claim(id);
    }
}
