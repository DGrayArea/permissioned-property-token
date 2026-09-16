// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Who may write to the register, and what a claim's expiry means.
///
/// @dev The role separation here is the point. A privileged action that can be
///      reached from an unexpected caller is the failure mode that drains
///      systems like this one, so each issuer role is tested against every
///      caller that should not hold it — including the *other* issuer.
contract IdentityRegistryTest is Base {
    address internal dave = makeAddr("dave");

    // ------------------------------------------------------- issuer administration

    function test_SetIssuer_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        registry.setIssuer(alice, true, true);
    }

    function test_SetIssuer_RevertsFor_ZeroAddress() public {
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        vm.prank(issuer);
        registry.setIssuer(address(0), true, true);
    }

    function test_SetIssuer_CanRevoke() public {
        vm.prank(issuer);
        registry.setIssuer(kycIssuer, false, false);

        assertFalse(registry.isKycIssuer(kycIssuer));
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, kycIssuer));
        vm.prank(kycIssuer);
        registry.registerIdentity(dave, US);
    }

    // ----------------------------------------------------------- identity records

    function test_RegisterIdentity_RevertsFor_UnauthorisedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, mallory));
        vm.prank(mallory);
        registry.registerIdentity(dave, US);
    }

    function test_RegisterIdentity_RevertsFor_DuplicateWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRegistered.selector, alice));
        vm.prank(kycIssuer);
        registry.registerIdentity(alice, US);
    }

    function test_RegisterIdentity_RevertsFor_ZeroAddress() public {
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        vm.prank(kycIssuer);
        registry.registerIdentity(address(0), US);
    }

    function test_RegisterIdentity_OwnerMayAlsoRegister() public {
        vm.prank(issuer);
        registry.registerIdentity(dave, US);
        assertTrue(registry.isRegistered(dave));
    }

    function test_SetCountry_UpdatesJurisdiction() public {
        vm.prank(kycIssuer);
        registry.setCountry(alice, GB);
        assertEq(registry.countryOf(alice), GB);
    }

    function test_SetCountry_RevertsFor_UnauthorisedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, mallory));
        vm.prank(mallory);
        registry.setCountry(alice, GB);
    }

    function test_SetCountry_RevertsFor_UnregisteredWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, dave));
        vm.prank(kycIssuer);
        registry.setCountry(dave, US);
    }

    function test_DeleteIdentity_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, kycIssuer));
        vm.prank(kycIssuer);
        registry.deleteIdentity(alice);
    }

    function test_DeleteIdentity_RevertsFor_UnregisteredWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, dave));
        vm.prank(issuer);
        registry.deleteIdentity(dave);
    }

    function test_DeleteIdentity_ClearsClaims() public {
        vm.prank(issuer);
        registry.deleteIdentity(alice);

        assertFalse(registry.isRegistered(alice));
        assertFalse(registry.isVerified(alice));
        assertFalse(registry.isAccredited(alice));
    }

    // ------------------------------------------------------------ role separation

    /// @dev The accreditation issuer must not be able to attest to identity.
    function test_SetKycClaim_RevertsFor_AccreditationIssuer() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, accreditationIssuer));
        vm.prank(accreditationIssuer);
        registry.setKycClaim(alice, uint64(block.timestamp + 1 days));
    }

    /// @dev ...and the KYC issuer must not be able to attest to accreditation.
    function test_SetAccreditationClaim_RevertsFor_KycIssuer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.NotAccreditationIssuer.selector, kycIssuer)
        );
        vm.prank(kycIssuer);
        registry.setAccreditationClaim(alice, uint64(block.timestamp + 1 days));
    }

    /// @dev The owner administers issuers but does not get to issue claims
    ///      directly. Separating "who may appoint an attestor" from "who may
    ///      attest" is the whole point of having a trusted-issuer registry.
    function test_SetKycClaim_RevertsFor_Owner() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, issuer));
        vm.prank(issuer);
        registry.setKycClaim(alice, uint64(block.timestamp + 1 days));
    }

    function test_SetAccreditationClaim_RevertsFor_Owner() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotAccreditationIssuer.selector, issuer));
        vm.prank(issuer);
        registry.setAccreditationClaim(alice, uint64(block.timestamp + 1 days));
    }

    function test_SetClaims_RevertFor_UnregisteredWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, dave));
        vm.prank(kycIssuer);
        registry.setKycClaim(dave, uint64(block.timestamp + 1 days));

        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, dave));
        vm.prank(accreditationIssuer);
        registry.setAccreditationClaim(dave, uint64(block.timestamp + 1 days));
    }

    function test_RevokeKycClaim_RevertsFor_UnauthorisedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotKycIssuer.selector, mallory));
        vm.prank(mallory);
        registry.revokeKycClaim(alice);
    }

    function test_RevokeKycClaim_TakesEffectImmediately() public {
        assertTrue(registry.isVerified(alice));

        vm.prank(kycIssuer);
        registry.revokeKycClaim(alice);

        assertFalse(registry.isVerified(alice));
        assertTrue(registry.isAccredited(alice)); // the other claim is untouched
    }

    // --------------------------------------------------------------------- expiry

    /// @dev A claim expiring exactly now is not live. Off-by-one here would let
    ///      a lapsed investor transact for the length of one block.
    function test_Claim_IsNotLive_AtExactExpiry() public {
        uint64 expiry = uint64(block.timestamp + 10 days);
        _setKyc(alice, expiry);

        vm.warp(expiry - 1);
        assertTrue(registry.isVerified(alice));

        vm.warp(expiry);
        assertFalse(registry.isVerified(alice));
    }

    function test_Claims_ExpireIndependently() public {
        _setKyc(alice, uint64(block.timestamp + 10 days));
        _setAccreditation(alice, uint64(block.timestamp + 100 days));

        vm.warp(block.timestamp + 20 days);
        assertFalse(registry.isVerified(alice));
        assertTrue(registry.isAccredited(alice));
    }

    function test_UnregisteredWallet_HasNoClaims() public view {
        assertFalse(registry.isRegistered(mallory));
        assertFalse(registry.isVerified(mallory));
        assertFalse(registry.isAccredited(mallory));
    }

    function test_IdentityOf_ReturnsRecord() public view {
        IdentityRegistry.Identity memory id = registry.identityOf(alice);
        assertTrue(id.registered);
        assertEq(id.country, US);
        assertGt(id.kycExpiry, block.timestamp);
        assertGt(id.accreditationExpiry, block.timestamp);
    }
}
