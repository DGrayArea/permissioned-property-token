// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";

/// @title Compliance
/// @notice The transfer gate. The token asks this contract before value moves,
///         and moves it only on `Denial.None`.
///
/// @dev Primary issuance and secondary transfer are deliberately different
///      checks. Issuance requires a live accreditation claim; a routine
///      secondary transfer between two verified holders may not (ADR-003).
///
///      Two policies are left configurable rather than hard-coded, because the
///      answers belong to counsel and the contract's job is to be able to
///      express whichever answer comes back:
///
///        - `requireSenderKycLive` — when a holder's KYC lapses, may they still
///          send? They clearly cannot receive. Whether they may exit is a
///          policy question with a real argument on both sides.
///        - `lockupEnd` — most private placement exemptions impose a holding
///          period before any resale (ADR-007). Until counsel confirms the
///          exemption, the mechanism exists and the date is a parameter.
contract Compliance is Ownable {
    enum Denial {
        None,
        Paused,
        SenderNotRegistered,
        RecipientNotRegistered,
        SenderKycNotLive,
        RecipientKycNotLive,
        RecipientNotAccredited,
        CountryNotAllowed,
        LockupActive,
        HolderCapExceeded
    }

    IdentityRegistry public immutable registry;
    IERC20 public token;

    mapping(uint16 country => bool) public allowedCountry;

    bool public paused;
    bool public requireSenderKycLive = true;
    bool public requireAccreditationOnTransfer;
    uint64 public lockupEnd;
    /// @notice Maximum balance a single holder may reach. 0 = no cap.
    uint256 public maxHolderBalance;

    event TokenSet(address indexed token);
    event CountryAllowed(uint16 indexed country, bool allowed);
    event PausedSet(bool paused);
    event LockupEndSet(uint64 lockupEnd);
    event HolderCapSet(uint256 maxHolderBalance);
    event PolicySet(bool requireSenderKycLive, bool requireAccreditationOnTransfer);

    error TokenAlreadySet();
    error ZeroAddress();

    constructor(address initialOwner, IdentityRegistry registry_) Ownable(initialOwner) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ------------------------------------------------------------ configuration

    /// @dev Set once, after the token is deployed. The token and the compliance
    ///      module reference each other, so one of the two links is late-bound.
    function setToken(IERC20 token_) external onlyOwner {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        emit TokenSet(address(token_));
    }

    function setCountryAllowed(uint16 country, bool allowed) external onlyOwner {
        allowedCountry[country] = allowed;
        emit CountryAllowed(country, allowed);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setLockupEnd(uint64 lockupEnd_) external onlyOwner {
        lockupEnd = lockupEnd_;
        emit LockupEndSet(lockupEnd_);
    }

    function setMaxHolderBalance(uint256 maxHolderBalance_) external onlyOwner {
        maxHolderBalance = maxHolderBalance_;
        emit HolderCapSet(maxHolderBalance_);
    }

    function setPolicy(bool requireSenderKycLive_, bool requireAccreditationOnTransfer_) external onlyOwner {
        requireSenderKycLive = requireSenderKycLive_;
        requireAccreditationOnTransfer = requireAccreditationOnTransfer_;
        emit PolicySet(requireSenderKycLive_, requireAccreditationOnTransfer_);
    }

    // ------------------------------------------------------------------ checks

    /// @notice Primary issuance. Stricter than a secondary transfer: the
    ///         recipient must hold a live accreditation claim.
    function checkMint(address to, uint256 amount) external view returns (Denial) {
        if (paused) return Denial.Paused;
        if (!registry.isRegistered(to)) return Denial.RecipientNotRegistered;
        if (!registry.isVerified(to)) return Denial.RecipientKycNotLive;
        if (!registry.isAccredited(to)) return Denial.RecipientNotAccredited;
        if (!allowedCountry[registry.countryOf(to)]) return Denial.CountryNotAllowed;
        return _checkHolderCap(to, amount);
    }

    /// @notice Secondary transfer between two holders.
    function checkTransfer(address from, address to, uint256 amount) external view returns (Denial) {
        if (paused) return Denial.Paused;
        if (block.timestamp < lockupEnd) return Denial.LockupActive;

        if (!registry.isRegistered(from)) return Denial.SenderNotRegistered;
        if (!registry.isRegistered(to)) return Denial.RecipientNotRegistered;

        // The recipient joins the register, so their claims must be live.
        if (!registry.isVerified(to)) return Denial.RecipientKycNotLive;
        if (requireAccreditationOnTransfer && !registry.isAccredited(to)) {
            return Denial.RecipientNotAccredited;
        }

        // Whether a lapsed holder may still exit is a policy decision.
        if (requireSenderKycLive && !registry.isVerified(from)) return Denial.SenderKycNotLive;

        if (!allowedCountry[registry.countryOf(to)]) return Denial.CountryNotAllowed;
        return _checkHolderCap(to, amount);
    }

    function _checkHolderCap(address to, uint256 amount) private view returns (Denial) {
        uint256 cap = maxHolderBalance;
        if (cap != 0 && address(token) != address(0)) {
            // Balances are read pre-transfer, so the post-state is balance + amount.
            if (token.balanceOf(to) + amount > cap) return Denial.HolderCapExceeded;
        }
        return Denial.None;
    }
}
