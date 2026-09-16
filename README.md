# Permissioned Property Token — proof of concept

A working slice of the Phase 1 architecture: a compliance-gated ERC-20
representing beneficial interest in a single-property SPV, with rental income
distributed against a record date.

This is not a T-REX fork and it is not a candidate for production. It exists to
make three arguments concrete enough to test, rather than leaving them as
assertions in a document. The reasoning behind each is in the accompanying
architecture decision records.

| Claim | Where it is demonstrated |
|---|---|
| The token cannot be listed on an open venue, by construction | `test_OpenMarketplace_CannotSettle_ToUnverifiedBuyer` |
| KYC and accreditation are separate claims with separate expiries | `test_Issue_RevertsFor_VerifiedButNotAccredited` |
| Distribution must pay against a record date, not live balances | `test_RecordDate_SellerKeepsEntitlement_BuyerGetsNothing` |
| Dust and unclaimed funds carry forward and stay visible | `test_Dust_IsCarriedForward_NotStranded` |

## Contracts

**`IdentityRegistry`** — wallets to identity records. Each record carries two
independent claims, KYC and accreditation, each with its own trusted issuer and
its own expiry. No personal data is written on chain: a claim records only that
an issuer attested and when the attestation lapses.

**`Compliance`** — the transfer gate. Returns a `Denial` reason rather than a
bare boolean, so a rejected transfer says why. Primary issuance and secondary
transfer are deliberately different checks. Two policies are parameters rather
than hard-coded rules — whether a holder whose KYC has lapsed may still send,
and the lockup end date — because those answers belong to counsel and the
contract's job is to express whichever one comes back.

**`PropertyToken`** — ERC-20, fixed maximum supply, every movement of value
routed through the gate. Balances are checkpointed so a distribution can read
them as they stood at a past instant. OpenZeppelin removed `ERC20Snapshot` in
v5, so this carries a minimal equivalent, kept small enough to audit by reading.

**`DistributionVault`** — takes rental income in a stablecoin, opens a snapshot
as the record date, and lets holders pull their pro-rata share. The remainder
from integer division and the balance left by holders who never claim are the
same problem, and take the same path: when the claim window closes, whatever is
left rolls into the next distribution. Nothing is swept to the issuer, and
`undistributed()` keeps the figure visible.

## Running it

```bash
forge test
```

```bash
forge test --match-test test_RecordDate -vvv
```

Deploy to Base Sepolia — one chain, per ADR-001:

```bash
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
```

## What the tests establish

**The venue problem.** A marketplace holding a valid unlimited approval still
cannot settle to an arbitrary buyer, because the buyer is the destination and
the buyer has no verified identity. Registering the venue itself changes
nothing — there is a test for that too. The same venue settling between two
verified holders succeeds, which is what a permissioned matching venue would
do. This is the mechanical basis for the claim that Ethereum L1's liquidity is
unreachable for this asset class.

**The record date.** Alice exits her entire position the day after a
distribution opens. She is still owed the income for the period she held it;
Bob, who bought after the record date, is owed nothing for it. Paying against
live balances would get this backwards, and getting it backwards is a dispute
with an investor rather than a rounding error.

**Dust.** Seven units split across holders of 5:3:2 pays 3, 2 and 1 — six units
out of seven. The seventh is not stranded and not swept. After the window
closes it appears in `undistributed()` and joins the next pool, and there is a
test showing carry alone can fund a distribution.

**The invariants.** Five properties held across 128,000 randomised calls per
run, over arbitrary interleavings of distributions, claims, transfers, closes
and time jumps:

- the vault never pays out more than it took in
- its balance always equals deposits minus payments
- per-distribution `claimed` figures sum to the global total
- no distribution overspends its own pool
- supply is conserved across every gated transfer

The first is the one that matters. Every rounding decision, every carry-forward
and every repeat-claim attempt has to respect it.

**Access control.** Each privileged role is tested against every caller that
should not hold it — including the other issuer. The accreditation issuer
cannot attest to identity, the KYC issuer cannot attest to accreditation, and
the owner, who appoints both, cannot issue claims directly. Separating *who may
appoint an attestor* from *who may attest* is the reason a trusted-issuer
registry exists at all, and a privileged action reachable from an unexpected
caller is the failure mode that drains systems shaped like this one.

## Coverage

79 tests across four unit suites and one invariant suite.

| | Lines | Branches | Functions |
|---|---|---|---|
| `IdentityRegistry` | 100% | 100% | 100% |
| `Compliance` | 100% | 60% | 100% |
| `DistributionVault` | 92% | 100% | 88% |
| `PropertyToken` | 92% | 81% | 92% |
| **Total** | **87%** | **89%** | **93%** |

The gaps are honest ones. `PropertyToken` carries a burn path that no entry
point currently reaches, and `Compliance` has a holder-cap branch that only
executes before the token address is bound. Neither is on a critical path, and
both would be either covered or removed before an audit.

```bash
forge coverage --no-match-contract VaultInvariantTest --report summary
```

## Deliberately absent

Governance, the document registry, redemption and the valuation attestation
pipeline. Governance is assembled from audited OpenZeppelin components and
proves nothing here. Redemption and valuation are the highest-severity part of
the full system — anyone who can move NAV can extract money — and deserve more
care than a proof of concept can give them.

The compliance module set is minimal: jurisdiction, holder cap, lockup, pause.
A production build would use the ERC-3643 module system rather than this, for
the audit economics rather than the feature set.
