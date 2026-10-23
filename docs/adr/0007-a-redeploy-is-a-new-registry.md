# ADR 0007 — A redeploy is a new registry

Status: accepted 2026-10-24, owner's decision, closing audit finding `OC-09`
Date: 2026-10-24

## The stance

**A redeploy is a new registry.** Fixing any validator produces a new minting policy and therefore a
new namespace of ids. The records minted under the previous policy **stay in the database, stay
readable, and stop being updated.** The read layer unions deployments by policy id. There is no
migration redeemer and no id is ever re-minted under a new policy.

This is option (a) of `OC-09`. The alternative, (b) — a `protocolVersion` field plus a
`MigrateProfile` redeemer in the next policy that accepts an old-policy user token — is not taken.

## Why the stance has to be chosen before the first kept deployment

The minting policy's hash is a function of all three validator hashes plus the oracle token
(`ProtocolParams`, the policy's compile-time parameter). So:

* fixing any validator changes its hash,
* which changes `ProtocolParams`,
* which changes the policy,
* which changes the currency symbol of **every** id.

`Mg` and `Mf` then refuse the old ids and the old user tokens under the new policy. Nothing in any
datum said which deployment it belonged to, and `attest-sync` **wiped its projections** when it
noticed the policy had changed. So the first validator fix after launch had no path at all, and the
question is not "how do we migrate" but "are we allowed to fix a validator". That is a decision, and
it is cheapest to make while there is nothing to migrate.

## Why not the version field the audit proposed

`OC-09`'s option (b) opens with a `protocolVersion :: Integer` in `ProtocolParams`, described as free
because it is a compile-time parameter. It is nearly free and it is also nearly redundant:

* `ProtocolParams` was **embedded in every profile datum**, so every profile already carried a
  deployment fingerprint — three validator hashes and an oracle token. ADR 0006 removed it precisely
  because nobody read it.
* The policy id distinguishes deployments on its own, and it is **already in every projection row**:
  each id is stored as a `GYAssetClass`, which is `policy.name`. A reader unions deployments for
  free, with no column to add and no migration to run.
* The migration redeemer that would give the field a job lives in the **next** policy and takes the
  previous policy id as its own parameter. It does not need a field in this one.

So the field buys a shorter fingerprint than the one that already exists, in exchange for a datum
that is wider for ever. The decision that actually matters is the sentence at the top, and that
sentence costs nothing on chain.

## What had to change, and it was one condition

The stance was **false in the one place that could falsify it.** `attest-sync` computed:

```haskell
needWipe = storedVersion < currentSchemaVersion || storedPolicy /= policyHexText
```

— so a redeploy dropped every chain-sync table. "The old records remain readable" would have been a
sentence in a document contradicted by the first line of the service that holds the records.

`needWipe` now reads the **schema version alone**. A schema bump still wipes, and that is a different
question: those tables would need an in-place `ALTER` Postgres rejects (`varchar`→`bigint`,
`ADD COLUMN NOT NULL`), so a fresh `CREATE` is the only safe path and the records are re-indexed from
the chain afterwards. A policy change wipes nothing.

`chain_sync_config.policy_hex_text` now holds a **comma-separated history, newest first** — same
column, same type, **no migration**, because a row holding a single id parses as a one-element
history. That matters more than it sounds: bumping the schema version to add a history column would
have wiped the very rows this ADR exists to keep.

The service logs the history on boot, naming the earlier registries whose records it is keeping and
no longer updating.

## What is deliberately not built

**Indexing more than one policy at a time.** `attest-sync` follows one Kupo pattern,
`<policy>.*`, and after a redeploy it follows the new one. A dispute resolved on the **old** registry
after the cutover is therefore not indexed: the old registry is frozen at the moment of the
redeploy, which is what "a redeploy is a new registry" means.

This is off-chain and does not freeze at deployment, so it waits for the first deployment that has a
predecessor worth following — which is after mainnet. Building it now would be a second Kupo request
per tick to serve a case that cannot yet occur. When it is built, the shape is already decided: the
history column names the policies, and each row already says which one it belongs to.

## Consequences

* **A validator fix after launch is allowed, and it is a new registry.** Users keep their records
  under the old policy and mint fresh ids under the new one. Nobody's identity carries across, and
  the README's self-hosting claim should say so rather than implying continuity.
* **`query-api` needs no change** to honour this: it reads rows, and the rows already carry their
  policy.
* **An operator can see what a database holds.** The boot line names the policy history, so "which
  registries are in here" is answerable without reading ids.
* **The cost of being wrong is bounded and visible.** If migration turns out to be wanted later, the
  redeemer that implements it lives in a future policy and takes the previous policy id as a
  parameter; nothing decided here forecloses it. What this ADR forecloses is pretending the old
  records were migrated when they were not.
