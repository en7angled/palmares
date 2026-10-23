# Offchain Library Rules

Domain types, tx building pipeline, storage/ingestion for attestations, and Atlas conventions.

## Pipeline

Interactions → Transactions via Operations. Do not bypass this flow.

1. `interactionToTxSkeleton` (Interactions): dispatches `Interaction` (action + user addresses) to Operations
2. Operations build `GYTxSkeleton` by composing **Skeletons** (ref inputs, validity, CIP-68) and **Lookups**
   (UTxO/datum queries)
3. `interactionToTxBody` (Transactions): runs skeleton through builder to produce tx

Output order in skeleton `mconcat` must match on-chain redeemer indices. Document output layout in comments.

## Atlas Conventions (GYTxSkeleton)

- **Specify-what-you-want**: Declare inputs, outputs, ref inputs, validity, signatories. Framework handles
  change, min ADA, collateral, balancing. No manual change/min-ADA logic.
- **Monad hierarchy** (least to most capability): `GYTxQueryMonad` → `GYTxUserQueryMonad` →
  `GYTxBuilderMonad` → `GYTxMonad` → `GYTxGameMonad`. Use the least capable that suffices.
- **Skeleton helpers**: `mustHaveOutput`, `mustHaveInput`, `mustHaveRefInput`, `mustBeSignedBy`,
  `isInvalidBefore`/`isInvalidAfter`, `mustMint`. Compose with `mconcat`.
- **Scripts**: `scriptFromPlutus` → `GYScript v`. Reference: `GYBuildPlutusScriptReference refScript script`.
  Inlined: `GYBuildPlutusScriptInlined script`.
- **Lookups**: `utxoDatum'` for one UTxO's datum. `utxosDatums` when filtering invalid datums at an address
  where anyone can create UTxOs.
- **Authenticate before you trust**: a UTxO found at a protocol address is not proof of anything. Check that
  it carries the NFT its datum names (`authenticateStateUTxO`) before reading it. The Belt System's
  unguarded lookups are inherited fix #3.

## Context

- **DeployedScriptsContext**: Validator refs + oracle. `MonadReader` in Operations/Lookups/Interactions.
- **TxBuildingContext**: Deployed scripts + provider. For `runTx`, `interactionToTxBody`,
  `runPalmaresActionWithPK`.
- New validator → new field in Context, JSON config, `deployReferenceScripts`, and
  `config_palmares_validators.json` after deploy.
- **OracleNFTPolicy is NOT in DeployedScriptsContext** — inlined in oracle-mint tx only.

## Onchain Functions Used Offchain

Do **not** call on-chain functions directly off-chain: they can `traceError`, which in a server process is
an uncatchable crash rather than a 4xx. Any on-chain predicate reused off-chain gets a wrapper that
pre-validates and throws a dedicated `TxBuildingException` constructor mapped to an HTTP status. This rule
outlived the Belt System's `SafeOnchainLogic` module — the module is not extracted, the discipline is. A
negative test in the Belt System found exactly this crash reachable from `interaction-api`; do not
reintroduce it.

## Identifiers

Governance identifiers are a correctness surface, not string formatting. `DomainTypes/Core/Ids.hs` owns
CIP-129 (`drep1…`, `cc_hot1…`, `cc_cold1…`) and CIP-105 (legacy, bare) forms, both directions, with a
golden test over real preprod values. The API accepts either form on input and echoes the canonical CIP-129
form on output. Never hand-roll a bech32 prefix at a call site.

## Storage, Ingestion & Chain-Sync (attestations only)

Governance data has **no** ingestion path — it is read from db-sync views. Everything in this section is
about the `palmares_attest` schema.

- **Flow**: Kupo matches → `projectChainEvent` (Ingestion, maps datum to `ChainEventProjection`) →
  `putMatchAndProjections` (Storage, dispatches to `put*Projection`)
- **New projection**: Extend `ChainEventProjection`, add case in `projectChainEvent`, add Persistent entity
  + `put*` in Storage, **add a `deleteWhere` for it in `rollbackTo`'s wipe step** (rollback rebuilds all
  projections by replaying the surviving raw-match log, so every projection table must be wiped before
  replay), **add table to `chainSyncTableNames`** (for `wipeChainSyncTablesRaw`, the pre-migration
  schema-version-gated wipe)
- **Idempotence**: Use `upsertByUnique` with `Unique*` constraint
- **Backfill**: When projection B depends on A and A can arrive after B, implement backfill logic
- **Time**: projections record **chain time** derived from the slot, never `insertedAt` wall clock — a
  replay must reproduce the same rows (inherited fix #5)

## New Concept Checklist

When adding a new validator, token kind, projection, or API surface:

**On-chain**: datum type (`Types.hs`, stable indices, `HasBlueprintDefinition`) → ID derivation
(`CIP68.hs`; `Id.hs` was deleted and is not where a new one goes) →
redeemer/validator → minting redeemer (exact mint, oracle pause gate, `feeFor`) → `INLINEABLE` pragmas →
cabal `exposed-modules`

**Off-chain**: domain type (`Core/Types.hs`, JSON/Swagger) → action (`Core/Actions.hs`) → conversions
(`Conversions.hs`) → lookups (`Lookups.hs`) → errors (`Exceptions.hs`) → operation (`Operations.hs`) →
interaction mapping (`Interactions.hs`) → validator accessor/context/deployment if new validator → output
index consistency

**Storage**: event type (`Ingestion.hs`) → Persistent entity + put function (`Storage.hs`) →
`putMatchAndProjections` → `rollbackTo` → `chainSyncTableNames`

**API/CLI**: query endpoints → admin command → Swagger metadata

**Tests/docs**: unit tests → architecture docs → blueprint regenerated → test scripts updated → test runner
in `GYTxGameMonad`

### Common Pitfalls

- Output index mismatch: `mconcat` order must match redeemer indices
- Missing exact mint check: every minting redeemer needs `mintValueMinted == expectedTokens`
- Forgetting oracle reference input: use `getOracleRefInputSkeleton`
- Constructor index collision: stable, unique, never reordered
- Missing rollback/wipe handling for new projections
- Reading a protocol UTxO without authenticating its NFT
- Off-chain deps in onchain-lib: forbidden
- Missing `INLINEABLE` on cross-module onchain functions
- Forgetting ProtocolParams: update `ProtocolParams` and redeploy minting policy if new validator hash needed
- Not checking opPaused: check pause gate if concept involves minting
- Missing CurrencySymbol validation: validate referenced AssetClasses with `isProtocolRefToken`, which
  checks the symbol AND the reference prefix — `hasCurrencySymbol` accepts a user token too
- Datum type confusion: use wrapper sum type for multiple datum types at same validator
- Incomplete skeleton: include all required ref inputs (e.g. oracle), validity range when the contract
  checks time, `mustBeSignedBy` when the contract expects signatories
- Inconsistent JSON naming: use `deriving-aeson` with `StripPrefix` + `CamelToSnake` for API types
- Writing a governance number anywhere but a `resources/metrics/*.sql` file
