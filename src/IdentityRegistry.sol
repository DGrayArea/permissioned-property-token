// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title IdentityRegistry
/// @notice Minimal ONCHAINID-style registry mapping wallets to identity records.
///
/// @dev Two design points carried from ADR-003:
///
///      1. KYC and accreditation are SEPARATE claims with SEPARATE issuers and
///         SEPARATE expiries. Knowing who someone is and knowing they are
///         permitted to invest are different questions answered by different
///         evidence. Collapsing them into one "verified" flag is a compliance
///         gap, not a simplification.
///
///      2. No personal data is stored on chain. A claim records only that a
///         trusted issuer attested and when that attestation lapses. The
///         documents behind it never leave the issuer. On-chain data cannot be
///         deleted, so anything identifying written here would be permanently
///         irreconcilable with a data subject's right to erasure.
contract IdentityRegistry is Ownable {
    struct Identity {
        bool registered;
        uint16 country; // ISO 3166-1 numeric
        uint64 kycExpiry; // 0 = no live claim
        uint64 accreditationExpiry; // 0 = no live claim
    }

    mapping(address wallet => Identity) private _identities;
    mapping(address issuer => bool) public isKycIssuer;
    mapping(address issuer => bool) public isAccreditationIssuer;

    event IdentityRegistered(address indexed wallet, uint16 country);
    event IdentityDeleted(address indexed wallet);
    event CountryUpdated(address indexed wallet, uint16 country);
    event KycClaimSet(address indexed wallet, address indexed issuer, uint64 expiry);
    event AccreditationClaimSet(address indexed wallet, address indexed issuer, uint64 expiry);
    event IssuerUpdated(address indexed issuer, bool kyc, bool accreditation);

    error NotRegistered(address wallet);
    error AlreadyRegistered(address wallet);
    error NotKycIssuer(address caller);
    error NotAccreditationIssuer(address caller);
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------- issuers

    /// @notice Add or remove a trusted issuer. In production this is the
    ///         multi-sig; the two roles are separable so an accreditation
    ///         verifier need not be trusted for identity, or vice versa.
    function setIssuer(address issuer, bool kyc, bool accreditation) external onlyOwner {
        if (issuer == address(0)) revert ZeroAddress();
        isKycIssuer[issuer] = kyc;
        isAccreditationIssuer[issuer] = accreditation;
        emit IssuerUpdated(issuer, kyc, accreditation);
    }

    // ------------------------------------------------------- identity records

    function registerIdentity(address wallet, uint16 country) external {
        if (!isKycIssuer[msg.sender] && msg.sender != owner()) revert NotKycIssuer(msg.sender);
        if (wallet == address(0)) revert ZeroAddress();
        if (_identities[wallet].registered) revert AlreadyRegistered(wallet);

        _identities[wallet] = Identity({registered: true, country: country, kycExpiry: 0, accreditationExpiry: 0});
        emit IdentityRegistered(wallet, country);
    }

    function setCountry(address wallet, uint16 country) external {
        if (!isKycIssuer[msg.sender] && msg.sender != owner()) revert NotKycIssuer(msg.sender);
        if (!_identities[wallet].registered) revert NotRegistered(wallet);
        _identities[wallet].country = country;
        emit CountryUpdated(wallet, country);
    }

    /// @notice Remove an identity record entirely.
    /// @dev The erasure path. It removes the claim record; it cannot remove
    ///      history, which is why no identifying data is written here at all.
    function deleteIdentity(address wallet) external onlyOwner {
        if (!_identities[wallet].registered) revert NotRegistered(wallet);
        delete _identities[wallet];
        emit IdentityDeleted(wallet);
    }

    // ----------------------------------------------------------------- claims

    function setKycClaim(address wallet, uint64 expiry) external {
        if (!isKycIssuer[msg.sender]) revert NotKycIssuer(msg.sender);
        if (!_identities[wallet].registered) revert NotRegistered(wallet);
        _identities[wallet].kycExpiry = expiry;
        emit KycClaimSet(wallet, msg.sender, expiry);
    }

    function setAccreditationClaim(address wallet, uint64 expiry) external {
        if (!isAccreditationIssuer[msg.sender]) revert NotAccreditationIssuer(msg.sender);
        if (!_identities[wallet].registered) revert NotRegistered(wallet);
        _identities[wallet].accreditationExpiry = expiry;
        emit AccreditationClaimSet(wallet, msg.sender, expiry);
    }

    /// @notice Revoke a live KYC claim before its natural expiry.
    function revokeKycClaim(address wallet) external {
        if (!isKycIssuer[msg.sender] && msg.sender != owner()) revert NotKycIssuer(msg.sender);
        _identities[wallet].kycExpiry = 0;
        emit KycClaimSet(wallet, msg.sender, 0);
    }

    // ------------------------------------------------------------------ views

    /// @notice A live KYC claim. Expiry is strict: a claim expiring exactly now
    ///         is not live.
    function isVerified(address wallet) external view returns (bool) {
        Identity storage id = _identities[wallet];
        return id.registered && id.kycExpiry > block.timestamp;
    }

    function isAccredited(address wallet) external view returns (bool) {
        Identity storage id = _identities[wallet];
        return id.registered && id.accreditationExpiry > block.timestamp;
    }

    function isRegistered(address wallet) external view returns (bool) {
        return _identities[wallet].registered;
    }

    function countryOf(address wallet) external view returns (uint16) {
        return _identities[wallet].country;
    }

    function identityOf(address wallet) external view returns (Identity memory) {
        return _identities[wallet];
    }
}
