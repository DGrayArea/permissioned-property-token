// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {Compliance} from "../src/Compliance.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {MockMarketplace} from "./mocks/MockMarketplace.sol";

/// @notice The transfer gate: who may hold the token, and when.
contract ComplianceTest is Base {
    // ------------------------------------------------------- primary issuance

    function test_Issue_ToVerifiedAccreditedInvestor() public {
        _issue(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Issue_RevertsFor_UnregisteredWallet() public {
        _expectDenial(Compliance.Denial.RecipientNotRegistered);
        vm.prank(issuer);
        token.issue(mallory, 100e18);
    }

    /// @dev KYC is not accreditation. A fully identified investor who has not
    ///      established accredited status cannot take part in the placement.
    function test_Issue_RevertsFor_VerifiedButNotAccredited() public {
        address dave = makeAddr("dave");
        _onboardKycOnly(dave, US);

        _expectDenial(Compliance.Denial.RecipientNotAccredited);
        vm.prank(issuer);
        token.issue(dave, 100e18);
    }

    function test_Issue_RevertsFor_DisallowedJurisdiction() public {
        address erin = makeAddr("erin");
        _onboard(erin, KP);

        _expectDenial(Compliance.Denial.CountryNotAllowed);
        vm.prank(issuer);
        token.issue(erin, 100e18);
    }

    function test_Issue_RevertsAbove_MaxSupply() public {
        _issue(alice, MAX_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.MaxSupplyExceeded.selector, 1, 0));
        vm.prank(issuer);
        token.issue(bob, 1);
    }

    // ----------------------------------------------------- secondary transfer

    function test_Transfer_BetweenVerifiedHolders() public {
        _issue(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    /// @dev Accreditation gates issuance but not routine secondary transfer,
    ///      unless the policy is tightened.
    function test_Transfer_ToVerifiedNonAccredited_AllowedByDefault() public {
        address dave = makeAddr("dave");
        _onboardKycOnly(dave, US);
        _issue(alice, 100e18);

        vm.prank(alice);
        token.transfer(dave, 10e18);
        assertEq(token.balanceOf(dave), 10e18);
    }

    function test_Transfer_ToVerifiedNonAccredited_BlockedWhenPolicyTightened() public {
        address dave = makeAddr("dave");
        _onboardKycOnly(dave, US);
        _issue(alice, 100e18);

        vm.prank(issuer);
        compliance.setPolicy(true, true);

        _expectDenial(Compliance.Denial.RecipientNotAccredited);
        vm.prank(alice);
        token.transfer(dave, 10e18);
    }

    function test_Transfer_RevertsFor_UnregisteredRecipient() public {
        _issue(alice, 100e18);

        _expectDenial(Compliance.Denial.RecipientNotRegistered);
        vm.prank(alice);
        token.transfer(mallory, 1e18);
    }

    function test_Transfer_RevertsWhen_RecipientKycExpired() public {
        _issue(alice, 100e18);
        vm.warp(block.timestamp + 400 days); // both claims lapse

        _expectDenial(Compliance.Denial.RecipientKycNotLive);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    /// @dev The lapsed-holder question from ADR-003. Under the default policy a
    ///      holder whose KYC has expired cannot move their position.
    function test_Transfer_RevertsWhen_SenderKycExpired_UnderDefaultPolicy() public {
        _issue(alice, 100e18);
        _setKyc(alice, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);

        _expectDenial(Compliance.Denial.SenderKycNotLive);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    /// @dev ...and the same contract expresses the opposite answer, because the
    ///      decision belongs to counsel rather than to the implementation.
    function test_Transfer_AllowsLapsedSender_WhenPolicyRelaxed() public {
        _issue(alice, 100e18);
        _setKyc(alice, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);

        vm.prank(issuer);
        compliance.setPolicy(false, false);

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_Transfer_RevertsDuring_Lockup() public {
        _issue(alice, 100e18);

        vm.prank(issuer);
        compliance.setLockupEnd(uint64(block.timestamp + 180 days));

        _expectDenial(Compliance.Denial.LockupActive);
        vm.prank(alice);
        token.transfer(bob, 1e18);

        vm.warp(block.timestamp + 181 days);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_Transfer_RevertsWhen_HolderCapExceeded() public {
        _issue(alice, 100e18);

        vm.prank(issuer);
        compliance.setMaxHolderBalance(10e18);

        _expectDenial(Compliance.Denial.HolderCapExceeded);
        vm.prank(alice);
        token.transfer(bob, 11e18);

        vm.prank(alice);
        token.transfer(bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_Transfer_RevertsWhen_Paused() public {
        _issue(alice, 100e18);

        vm.prank(issuer);
        compliance.setPaused(true);

        _expectDenial(Compliance.Denial.Paused);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_Transfer_RevertsAfter_IdentityDeleted() public {
        _issue(alice, 100e18);

        vm.prank(issuer);
        registry.deleteIdentity(bob);

        _expectDenial(Compliance.Denial.RecipientNotRegistered);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    // ------------------------------------------------------- the venue problem

    /// @notice The headline behaviour. A marketplace holding a valid approval
    ///         still cannot sell to an arbitrary buyer, because the buyer is
    ///         the destination and the buyer has no identity. This is why the
    ///         token cannot be listed on any open venue — and why the L1
    ///         liquidity argument in the brief does not apply to it.
    function test_OpenMarketplace_CannotSettle_ToUnverifiedBuyer() public {
        MockMarketplace venue = new MockMarketplace();
        _issue(alice, 100e18);

        vm.prank(alice);
        token.approve(address(venue), type(uint256).max);

        _expectDenial(Compliance.Denial.RecipientNotRegistered);
        venue.fill(token, alice, mallory, 10e18);
    }

    /// @dev Whitelisting the venue does not help: the venue is not the
    ///      destination. Registering it changes nothing about the buyer.
    function test_OpenMarketplace_StillFails_WhenVenueItselfIsVerified() public {
        MockMarketplace venue = new MockMarketplace();
        _onboard(address(venue), US);
        _issue(alice, 100e18);

        vm.prank(alice);
        token.approve(address(venue), type(uint256).max);

        _expectDenial(Compliance.Denial.RecipientNotRegistered);
        venue.fill(token, alice, mallory, 10e18);
    }

    /// @dev The same venue settling between two verified holders works. A
    ///      permissioned matching venue is possible; an open one is not.
    function test_Venue_CanSettle_BetweenVerifiedHolders() public {
        MockMarketplace venue = new MockMarketplace();
        _issue(alice, 100e18);

        vm.prank(alice);
        token.approve(address(venue), type(uint256).max);

        venue.fill(token, alice, bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }
}
