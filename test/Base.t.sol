// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {Compliance} from "../src/Compliance.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Shared deployment. One property, one SPV, a handful of investors.
abstract contract Base is Test {
    uint16 internal constant US = 840;
    uint16 internal constant GB = 826;
    uint16 internal constant KP = 408; // not in the permitted set

    uint256 internal constant MAX_SUPPLY = 1_000_000e18;
    uint64 internal constant CLAIM_WINDOW = 30 days;

    IdentityRegistry internal registry;
    Compliance internal compliance;
    PropertyToken internal token;
    DistributionVault internal vault;
    MockUSDC internal usdc;

    address internal issuer = makeAddr("issuer");
    address internal kycIssuer = makeAddr("kycIssuer");
    address internal accreditationIssuer = makeAddr("accreditationIssuer");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory"); // never onboarded

    function setUp() public virtual {
        vm.warp(1_760_000_000); // a sane starting timestamp

        vm.startPrank(issuer);
        registry = new IdentityRegistry(issuer);
        compliance = new Compliance(issuer, registry);
        token = new PropertyToken("123 Example Street SPV", "EX123", MAX_SUPPLY, issuer, compliance);
        compliance.setToken(token);

        usdc = new MockUSDC();
        vault = new DistributionVault(issuer, token, usdc, CLAIM_WINDOW);
        token.setDistributor(address(vault));

        registry.setIssuer(kycIssuer, true, false);
        registry.setIssuer(accreditationIssuer, false, true);
        compliance.setCountryAllowed(US, true);
        compliance.setCountryAllowed(GB, true);
        vm.stopPrank();

        _onboard(alice, US);
        _onboard(bob, US);
        _onboard(carol, GB);
    }

    /// @dev Register an identity and issue both claims, each from its own issuer.
    function _onboard(address who, uint16 country) internal {
        vm.prank(kycIssuer);
        registry.registerIdentity(who, country);
        _setKyc(who, uint64(block.timestamp + 365 days));
        _setAccreditation(who, uint64(block.timestamp + 365 days));
    }

    /// @dev Identity and KYC only — no accreditation claim.
    function _onboardKycOnly(address who, uint16 country) internal {
        vm.prank(kycIssuer);
        registry.registerIdentity(who, country);
        _setKyc(who, uint64(block.timestamp + 365 days));
    }

    function _setKyc(address who, uint64 expiry) internal {
        vm.prank(kycIssuer);
        registry.setKycClaim(who, expiry);
    }

    function _setAccreditation(address who, uint64 expiry) internal {
        vm.prank(accreditationIssuer);
        registry.setAccreditationClaim(who, expiry);
    }

    function _issue(address to, uint256 amount) internal {
        vm.prank(issuer);
        token.issue(to, amount);
    }

    /// @dev Fund the issuer and open a distribution of `amount` USDC.
    function _distribute(uint256 amount) internal returns (uint256 id) {
        usdc.mint(issuer, amount);
        vm.startPrank(issuer);
        usdc.approve(address(vault), amount);
        id = vault.distribute(amount);
        vm.stopPrank();
    }

    function _expectDenial(Compliance.Denial denial) internal {
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NotCompliant.selector, denial));
    }
}
