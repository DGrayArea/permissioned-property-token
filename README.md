# Permissioned Property Token

A compliance-gated ERC-20 representing beneficial interest in an SPV that holds
one property, with rental income distributed against a record date.

Proof of concept. Not production, not a T-REX fork.

## Quick start

Submodules matter here, so clone recursively:

```bash
git clone --recursive https://github.com/DGrayArea/permissioned-property-token
cd permissioned-property-token
forge test
```

Deploy to Base Sepolia:

```bash
PRIVATE_KEY=0x... forge script script/Deploy.s.sol \
  --rpc-url https://sepolia.base.org --broadcast --verify
```

It prints four addresses. Feed three back in to seed the deployment with
investors, an issuance and a distribution:

```bash
export REGISTRY=0x... TOKEN=0x... VAULT=0x...
forge script script/Seed.s.sol --rpc-url https://sepolia.base.org --broadcast
```

Distribution needs testnet USDC. Without it the seed still issues tokens and
reports what it skipped.

## Contracts

| Contract | What it does |
| --- | --- |
| `IdentityRegistry` | Maps wallets to identity records. KYC and accreditation are separate claims. |
| `Compliance` | The transfer gate. Returns a `Denial` reason rather than a bare bool. |
| `PropertyToken` | ERC-20 routed through the gate, with balance checkpoints. |
| `DistributionVault` | Pull-based pro-rata claims against a snapshot. |

## Design notes

**KYC and accreditation are separate claims.** Different issuers, different
expiries. They establish different facts and lapse on different clocks, so a
single "verified" flag can't stand for both.

**The token can't be listed on an open venue.** `transferFrom` checks the
recipient against the registry, and a marketplace buyer has no identity, so it
reverts. `test_OpenMarketplace_CannotSettle_ToUnverifiedBuyer` covers it.
Whitelisting the venue doesn't help either, since the venue isn't the
destination — there's a test for that too.

**Distribution pays against a record date.** Balances move between
distributions, so paying live balances would pay someone who already sold. Each
distribution opens a snapshot and entitlements read that instant. OpenZeppelin
dropped `ERC20Snapshot` in v5, so `PropertyToken` carries a minimal replacement.

**Dust carries forward.** Integer division leaves a remainder every time, and
some holders never claim. Both roll into the next pool when the claim window
closes. `undistributed()` keeps the figure visible rather than letting it sit
in the contract unaccounted for.

**Two policies are parameters, not hard-coded rules.** Whether a holder whose
KYC has lapsed can still send, and the lockup end date. Those are legal calls,
so the contract holds the mechanism and takes the answer as a parameter.

## Tests

79 tests across four unit suites and one invariant suite.

```bash
forge test
forge coverage --no-match-contract VaultInvariantTest --report summary
```

Five invariants, each held across 128,000 randomised calls over arbitrary
interleavings of distributions, claims, transfers, closes and time jumps:

- the vault never pays out more than it took in
- its balance equals deposits minus payments
- per-distribution `claimed` sums to the global total
- no distribution overspends its own pool
- supply is conserved across every gated transfer

Coverage is 87% lines, 89% branches, 93% functions. The gaps are a burn path no
entry point reaches and a holder-cap branch that only runs before the token
address is bound.

Access control is tested against every caller that shouldn't hold a role,
including the other issuer: the accreditation issuer can't attest to identity,
the KYC issuer can't attest to accreditation, and the owner who appoints both
can't write claims directly.

## Not included

Governance, document registry, redemption and valuation. Governance is mostly
OpenZeppelin assembly. Redemption and valuation are the highest-severity part
of a full system, since anyone who can move NAV can extract money, and they
need more care than a proof of concept gives them.

The compliance module set is minimal — jurisdiction, holder cap, lockup, pause.
A production build would use the ERC-3643 module system instead, mainly for the
audit economics.
