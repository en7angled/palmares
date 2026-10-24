# ADR 0008 — The level-1 anchor is a reserved metadata key, not a datum field

Status: accepted 2026-10-24, builder's decision under the owner's standing authorization
Date: 2026-10-24

## The stance

An attestation's optional **level-1 anchor** — the `(gov_action_id, stake_address)` of the treasury
withdrawal, or the governance action alone, that the attestation comments on — is carried as **two
reserved keys in `otherMetadata`**:

| key | value | meaning |
| --- | --- | --- |
| `palmares:level1_gov_action` | CIP-129 `gov_action1…` | the action this attestation concerns |
| `palmares:level1_stake_address` | bech32 `stake…` | the address paid by that action's withdrawal |

The first key alone anchors to an action. Both together anchor to a **treasury withdrawal**, which is
the pair `palmares.treasury_withdrawal` is keyed by. The second key alone is meaningless and is
refused by the write API.

There is **no new datum field and no redeploy.** The write API refuses to build a malformed anchor;
the read API resolves it against `palmares.treasury_withdrawal` (or `palmares.gov_action`) and
publishes, explicitly, whether the pointer resolves.

## Why a typed field buys nothing here

The specification requires the anchor (§2, §4.3) and the F1 acceptance list's check 11 cannot be
satisfied without it. It is tempting to read "the attestation's datum optionally carries the
`(gov_action_id, stake_address)`" as *a field in the datum*. But the same paragraph decides the thing
that makes a field pointless:

> The validator does not check that the on-chain fact exists — it is a pointer, confronted at read
> time with `palmares.treasury_withdrawal`, and the API marks explicitly whether the pointer
> resolves. **(call)**: the alternative — on-chain verification through a reference input — would
> require the withdrawal to be an addressable UTxO, which it is not, so read-time verification it is.

So the anchor is, by the spec's own decision, **unvalidated on chain**. A typed field would therefore
carry exactly the same amount of truth as a metadata key — zero — while costing:

* **a new registry.** Changing any datum type changes a validator hash, which changes
  `ProtocolParams`, which changes the minting policy, which changes the currency symbol of every id.
  ADR 0007 is explicit that this is allowed and that it is a *new registry*: every existing profile,
  attestation and dispute stops being updatable. Paying that for a field nothing validates is the
  worst trade in the protocol.
* **a wider datum for ever**, on every attestation including the ones with no anchor.

## Why the carrier is already the right carrier

`otherMetadata` is not an unchecked bag. `validateOtherMetadata` (`Palmares.Onchain.CIP68`) already
enforces, **on chain**, exactly the properties an anchor needs:

* at most 16 entries, counted before anything quadratic runs;
* keys at most 64 bytes, values at most 256;
* no duplicate keys — so an attestation cannot carry two different `palmares:level1_gov_action`
  values and mean whichever one a given decoder happens to read first;
* no collision with `name`, `description` or `image`.

A CIP-129 governance action id is 65 characters and a bech32 stake address is 64, so both values sit
well inside the 256-byte limit, and the anchor spends two of sixteen entries. The off-chain refusal
of reserved-key collisions already exists too (`AttestationOtherMetadataReservedKeys`).

And the **projection already stores it**: `attestation_projection.other_metadata` is a JSON column
written from the datum verbatim. The anchor is therefore already indexed, already served, and needs
no schema version bump — which matters more than it sounds, because a schema bump wipes and re-syncs
the chain-sync tables (ADR 0007).

## What this costs, stated plainly

**The key namespace is a convention, not a guarantee.** Nothing on chain reserves
`palmares:level1_gov_action` for this purpose; another issuer may use the same key for something
else, and nothing stops an attestation from carrying one whose value is nonsense or names a
withdrawal that does not exist.

That is not a new weakness — it is the weakness the spec already accepted when it chose read-time
resolution, and it is why the requirement is phrased as *"the API marks explicitly whether the
pointer resolves"* rather than *"the API shows resolved anchors"*. What the off-chain layers add:

* the **write API** refuses to build a transaction whose anchor does not parse, so the common case
  never reaches the chain;
* the **read API** parses at read time as well, because a hand-built transaction skips the write API
  entirely. An anchor that does not parse, or that resolves to nothing, is published as
  **unresolvable** — never hidden, and never silently dropped, which would make an attestation look
  unanchored when it carries a bad pointer.

## What is deliberately not built

* **A typed `anchor` field in the datum.** Per the above. If a future redeploy happens for an
  unrelated validator fix, promoting the pair to a typed field is then nearly free — and the
  migration is a read-layer union, because the keys remain readable under the old policy.
* **On-chain existence verification.** Impossible, and already recorded as such by the spec: a
  treasury withdrawal is not an addressable UTxO, so there is no reference input to check against.
* **An anchor → withdrawal index.** Resolution is a join on two indexed columns at read time. A
  materialised view of anchors would be a second place for the mapping to be stale, for a feature
  whose row count is currently in the single digits.
* **Anchors on profiles or disputes.** The spec puts the anchor on attestations. A dispute already
  points at the attestation it concerns, which points at the anchor.

## Consequences

* **F1 check 11 becomes satisfiable** without touching the deployed protocol: an attestation can be
  issued with and without an anchor, and the API shows the corresponding withdrawal from
  `palmares.treasury_withdrawal` for the one and marks the other as unanchored — while a deliberately
  bogus anchor is marked unresolvable rather than hidden.
* **The key names are API surface, versioned with the API.** They belong in the OpenAPI description
  and the use-case documents, not in the blueprint — the blueprint describes what the validators
  check, and the validators do not check these.
* **Anything that reads `other_metadata` sees the anchor keys.** A client rendering raw metadata will
  show them twice unless it filters the two reserved keys; the read API therefore publishes the
  anchor as its own field *and* leaves the keys in place, because removing them from
  `other_metadata` would make the API disagree with the datum.
