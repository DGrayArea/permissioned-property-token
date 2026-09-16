// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {Compliance} from "../src/Compliance.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the stack to Base Sepolia.
///
/// @dev Chain choice follows ADR-001: one chain, not two. A permissioned token
///      cannot reach L1 liquidity by construction, and splitting issuance from
///      secondary means bridging a restricted security — which requires running
///      the compliance stack twice or losing the restrictions at the bridge.
///
///      In production `owner` is a Safe, not an EOA, and the deploy is executed
///      by the multi-sig rather than a single key.
contract Deploy is Script {
    uint16 internal constant US = 840;
    uint16 internal constant GB = 826;

    /// @dev Circle's USDC on Base Sepolia.
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    uint256 internal constant MAX_SUPPLY = 1_000_000e18;
    uint64 internal constant CLAIM_WINDOW = 30 days;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address usdc = vm.envOr("USDC", BASE_SEPOLIA_USDC);

        vm.startBroadcast(pk);

        IdentityRegistry registry = new IdentityRegistry(owner);
        Compliance compliance = new Compliance(owner, registry);
        PropertyToken token = new PropertyToken("123 Example Street SPV", "EX123", MAX_SUPPLY, owner, compliance);
        compliance.setToken(token);

        DistributionVault vault = new DistributionVault(owner, token, IERC20(usdc), CLAIM_WINDOW);
        token.setDistributor(address(vault));

        // Deployer acts as both issuers on testnet. In production these are
        // Fractal ID or Blockpass for KYC, and a dedicated accreditation
        // verifier as a separate trusted issuer (ADR-003).
        registry.setIssuer(owner, true, true);

        compliance.setCountryAllowed(US, true);
        compliance.setCountryAllowed(GB, true);

        vm.stopBroadcast();

        console.log("IdentityRegistry  ", address(registry));
        console.log("Compliance        ", address(compliance));
        console.log("PropertyToken     ", address(token));
        console.log("DistributionVault ", address(vault));
        console.log("Currency (USDC)   ", usdc);
    }
}
