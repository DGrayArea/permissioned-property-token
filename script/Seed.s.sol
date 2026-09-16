// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Puts real history on a fresh deployment: onboarded investors, an
///         issuance, and a distribution with a claim against it.
/// @dev A deployment with no activity demonstrates nothing. This writes the
///      state that makes the record date and the compliance gate visible on an
///      explorer.
///
///      Reads the four addresses printed by Deploy.s.sol:
///        REGISTRY, TOKEN, VAULT, and optionally USDC.
///
///      The distribution step needs testnet USDC in the deployer's wallet. If
///      there is none, issuance still runs and the script reports what it
///      skipped rather than reverting.
contract Seed is Script {
    uint16 internal constant US = 840;
    uint16 internal constant GB = 826;

    uint256 internal constant ALICE_UNITS = 500_000e18;
    uint256 internal constant BOB_UNITS = 300_000e18;
    uint256 internal constant ISSUER_UNITS = 200_000e18;

    uint256 internal constant RENT = 3_000e6; // 3,000 USDC

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IdentityRegistry registry = IdentityRegistry(vm.envAddress("REGISTRY"));
        PropertyToken token = PropertyToken(vm.envAddress("TOKEN"));
        DistributionVault vault = DistributionVault(vm.envAddress("VAULT"));
        IERC20 currency = vault.currency();

        // Demo investors. Deterministic so a second run addresses the same
        // wallets rather than scattering state across new ones.
        address alice = vm.addr(uint256(keccak256("poc.investor.alice")));
        address bob = vm.addr(uint256(keccak256("poc.investor.bob")));

        uint64 claimExpiry = uint64(block.timestamp + 365 days);

        vm.startBroadcast(pk);

        _onboard(registry, deployer, US, claimExpiry);
        _onboard(registry, alice, US, claimExpiry);
        _onboard(registry, bob, GB, claimExpiry);

        token.issue(alice, ALICE_UNITS);
        token.issue(bob, BOB_UNITS);
        token.issue(deployer, ISSUER_UNITS);

        uint256 available = currency.balanceOf(deployer);
        bool distributed = available >= RENT;

        if (distributed) {
            currency.approve(address(vault), RENT);
            uint256 id = vault.distribute(RENT);
            // The deployer holds 20% of supply, so claims 20% of the pool.
            vault.claim(id);
        }

        vm.stopBroadcast();

        console.log("investor alice   ", alice);
        console.log("investor bob     ", bob);
        console.log("issuer           ", deployer);
        console.log("total supply     ", token.totalSupply());

        if (distributed) {
            console.log("distributed       ", RENT);
            console.log("issuer balance    ", currency.balanceOf(deployer));
            console.log("unclaimed in vault", currency.balanceOf(address(vault)));
        } else {
            console.log("distribution skipped: deployer holds", available, "of required", RENT);
        }
    }

    function _onboard(IdentityRegistry registry, address who, uint16 country, uint64 expiry) private {
        if (!registry.isRegistered(who)) {
            registry.registerIdentity(who, country);
        }
        registry.setKycClaim(who, expiry);
        registry.setAccreditationClaim(who, expiry);
    }
}
