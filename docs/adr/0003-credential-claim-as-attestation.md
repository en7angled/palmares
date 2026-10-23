# ADR 0003 — A credential claim is an attestation, not a field

Status: accepted 2026-10-23, owner's decision, replacing D-E as it was built (commit `800a39d`)
Date: 2026-10-23

## Decision

A profile's binding to a Cardano credential stops being a mutable field on the profile datum and
becomes **two append-only attestations**:

* `CredentialClaim` — a __self-issued__ attestation (`attestationIssuer == attestationSubject`)
  carrying the credential, mintable only when the profile's own user NFT is spent __and__ the
  credential proves control of the transaction.
* `CredentialWithdrawal` — a later attestation naming the same credential, mintable on the
  credential's proof alone.

`OnchainProfile.profileCredential` is removed. `Mp3` is removed. The `RevokeCredential` arm added
for D-E is removed. The read layer keeps publishing `profile_credential`, but derives it: the latest
`CredentialClaim` for that subject with no later `CredentialWithdrawal` naming the same credential.

**Nothing is ever deleted or rewritten.** That is the whole point, and it is the rule the rest of
this protocol already follows: a contested attestation is shown *beside* its dispute and never
hidden, because "the record of a claim and the record of its being contested are both facts".

## Why

D-E shipped a revocation that cleared `profileCredential` in place. An independent audit found that
this made the remedy more dangerous than the problem it was built for:

* The proof a revocation needs is the one a claim needed — `checkCredentialControl`. For a **script**
  credential that proof is "the transaction spends some UTxO at the script's address", so a single
  member of a 1-of-N multisig, or anyone after a timelock, satisfies it.
* The clearing was **irreversible**. `profileCredential` was written in one place and cleared in one
  place; no redeemer set it again. Nothing in this protocol burns, so a re-claim mints a *new*
  `profileId`, while every existing attestation still names the old one. One revocation severed a
  credential from its entire track record, permanently.
* And the asymmetry: abusing the original weakness (`Mp3`) is **additive** — a bogus second profile
  appears and the real one is intact, which the read layer can show. Abusing the revocation was
  **subtractive and unrecoverable**.

The owner's instruction was the cleanest variant rather than the cheapest. The cheapest was a
re-claim arm restoring reversibility; the cleanest removes the destructive operation from the
protocol altogether, because an append-only log has no delete button to design.

## What this buys, beyond fixing the audit finding

* **A malicious withdrawal destroys nothing.** It appends a statement. The profile and the credential
  can append a new claim afterwards, and a reader sees the whole sequence with its dates — which is
  more honest than a field that silently reads `null`.
* **The history is legible.** "Bound since March, withdrawn in October, re-bound in November" is a
  fact pattern the registry can publish. A mutable field could only ever show the last state.
* **Disputes already apply.** A dispute points at an attestation, so a bogus credential claim is
  contestable through machinery that already exists, with a deposit behind it.
* **It removes on-chain surface.** `Mp3` and the profile datum's credential field both go, and with
  them `checkCredentialControl` leaves the minting policy's profile path.

## Costs, stated

* **Two transactions to register a credentialled profile** instead of one: create the profile, then
  claim. Accepted. Four of the six profile kinds — Organization, Community, Vendor, Auditor —
  correspond to no on-chain credential at all and are unaffected.
* **One `Maybe Credential` field on every attestation datum.** `Nothing` for the five existing kinds,
  which is a constructor and a few bytes, not the ~65 that D-C's `AssetClass` cost per record.
* **The read layer gains a derivation** where it had a column. The published API field keeps its name
  and type, so a consumer sees no break.
* **Validator hashes move again.** Free today — the registry is empty — and the reason this is being
  done now rather than after the first deploy.

## Alternatives considered

* **A re-claim arm (option A).** Keeps the field, makes clearing reversible: the profile's user NFT
  plus the credential's consent can restore a claim, so neither party can permanently destroy the
  other's position. Cheaper (~300 bytes, one arm) and sound. Rejected only because it keeps a
  destructive primitive in a protocol that otherwise has none.
* **A stronger proof for revocation** — a per-purpose proof such as a vote by the credential in the
  same transaction. Rejected: it does not fix the 1-of-N case, because a vote by a 1-of-N script is
  still available to any one member, and it taxes every honest victim to do so.
* **A separate record type for bindings**, like disputes are separate from attestations. Rejected as
  more surface for the same property: a binding would need its own validator address, its own mint
  rules, its own projection and its own dust sweep, where an attestation already has all four.
* **Ship D-E as built.** Rejected on the audit's finding.

## What is NOT decided here

* Whether a `CredentialWithdrawal` should also be mintable by the PROFILE (so a profile can disown a
  claim it made). The claim needs both parties; the withdrawal currently needs only the credential,
  on the argument that the credential is the party being named. If the profile should be able to
  withdraw too, that is one more disjunct in the mint rule and no change to the shape.
* Whether the read layer should surface the full claim history or only the current state. The
  projection will carry both; which one the API publishes is a read-surface decision with no on-chain
  consequence.
