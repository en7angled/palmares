# Palmares

Cardano governance reputation and track-record registry. Four libraries with strict layering; three HTTP
services + admin CLI. Governance facts come from `cardano-db-sync` through read-only SQL views; only the
attestation protocol has state of our own.

## Environment

- **Toolchain**: Nix + direnv. Run `direnv allow` before building (loads GHC 9.6.6, Cabal, HLS via the devx flake).
- **Build**: `cabal build all` from repo root. No Stack, no `package.yaml`.
- **Test**: `cabal test`.
- **REPL**: `cabal repl` (e.g. `cabal repl exe:admin`).
- **Clean**: `cabal clean`.
- **Config**: `config/config_atlas.json` (provider; `config_atlas.example.json` is the committed template),
  `config/config_palmares_validators.json` (deployed validators), `operation.prv` (admin key, never commit).
- **`.env`**: Local overrides sourced by direnv. Never committed. See `.env.example` for every name.

## Architecture

**Two data paths, and they must not be confused.**

1. **Governance (read-only, no state of ours)**: `cardano-node` → `cardano-db-sync` (`preset: only_governance`,
   ledger enabled) → PostgreSQL. Our layer is the `palmares` schema: read-only views, one materialized view,
   one SQL function. No projection service, no ingestion, no re-derivation of ledger math. If a governance
   number is wrong, the fix is a view, not a pipeline.
2. **Attestations (our own state)**: on-chain validators → Kupo → `attest-sync` → `palmares_attest` schema.
   This is the only path with stored state, migrations and rollback handling.

**Library layering** (inner → outer): `onchain-lib` + `chainsync-lib` → `offchain-lib` → `webapi-lib`.
Dependencies only point inward. `webapi-lib` has **no** project-library dependencies (HTTP, auth, CORS,
CSV only). `onchain-lib` must never import off-chain deps (no Aeson, Servant, Swagger).

**Executables**: `admin` (CLI), `interaction-api` (8082), `query-api` (8083), `attest-sync` (8084).
Sources in `src/exe/<name>/`. Executables depend on `offchain-lib` + `webapi-lib`; `attest-sync` also
depends on `chainsync-lib`.

**Three conceptual flows**:
1. **Type hierarchy**: Transfer (API DTOs) → Domain (`Core/Types.hs`, `Core/Actions.hs`) → Onchain
   (`Protocol/Types.hs`). Conversions bridge onchain↔domain.
2. **Interactions → Transactions**: Interaction → `interactionToTxSkeleton` → Operations (Skeletons +
   Lookups) → `GYTxSkeleton` → `interactionToTxBody` → tx. Do not bypass.
3. **Onchain events → projections** (attestations only): Kupo matches → `projectChainEvent` (Ingestion) →
   `putMatchAndProjections` (Storage) → rows in `palmares_attest`.

**File reference** — where to change what (paths under `src/lib/<lib>/` or `src/exe/<exe>/`):

| Change | Files |
| --- | --- |
| New on-chain type | `Onchain/Protocol/Types.hs`, `.cabal` |
| New deterministic token name | `Onchain/Utils.hs` (`nameFromTxOutRef`), `Onchain/CIP68.hs` (`generateRefAndUserTN` applies the CIP-67 prefixes) |
| New validator | `Onchain/Validators/<Name>Validator.hs`, `Onchain/Protocol.hs`, `TxBuilding/Validators.hs`, `TxBuilding/Context.hs`, `TxBuilding/Transactions.hs`, `.cabal` |
| New minting redeemer | `Onchain/Validators/MintingPolicy.hs` |
| New off-chain domain type | `DomainTypes/Core/Types.hs`, `DomainTypes/Core/Actions.hs` |
| New governance identifier | `DomainTypes/Core/Ids.hs` (CIP-129 / CIP-105) + its golden test |
| New tx operation | `TxBuilding/Operations.hs`, `TxBuilding/Lookups.hs`, `TxBuilding/Interactions.hs`, `TxBuilding/Conversions.hs` |
| New error type | `TxBuilding/Exceptions.hs` |
| **New governance metric** | `resources/metrics/<name>.sql` + the catalog in `query-api/Metrics/Catalog.hs`. The `.sql` file is the single source of truth: it is embedded at compile time, served at `/metrics/formulas`, and `docs/metrics.md` is generated from it. Never write the formula twice. |
| **New governance view** | `sql/*.sql` (applied at service boot by `Query/Views.hs`) + a check in `sql/checks/` |
| New governance query endpoint | `query-api/RestAPI.hs`, `Query/Gov.hs` (raw SQL over schema `palmares`); response DTOs in `offchain-lib/DomainTypes/Transfer/QueryResponses.hs`, filters + `*FromParams` in `Transfer/Filters.hs`, sort enums in `Transfer/OrderBy.hs`; aggregates in `Query/Aggregates.hs`, pages in `Query/Pages.hs` |
| New attestation query endpoint | `query-api/RestAPI.hs`, `Query/Projected.hs`; shared helpers in `Query/Common.hs` |
| New attestation projection | `Storage.hs`, `Ingestion.hs` |
| New admin command | `src/exe/admin/Main.hs` |
| New fee type | `Onchain/Protocol/Types.hs` (FeeConfig), `Onchain/Protocol/Lookup.hs` (`feeFor`), `TxBuilding/Operations.hs`, `Onchain/Validators/MintingPolicy.hs` |
| Updating oracle format | `Onchain/Protocol/Types.hs` (requires migration/redeployment) |
| New test | `UnitTests.hs`, `TestRuns.hs`, `UnitTests/<Topic>.hs` |

## Haskell Style

- **Naming**: PascalCase types, camelCase functions/fields. `mk` smart constructors, `unsafe` prefix,
  `is`/`has`/`check` predicates. `derive`/`generate` for ID derivation. Avoid redundant record field
  prefixes.
- **Formatting**: Max 120 chars, 2-space indent, no tabs. One blank line between top-level declarations.
- **Haddock**: Module-level documentation required; prefer `-- |` on exports in new code and library
  surfaces; `-- ^` on record fields where helpful.
- **Types**: Records for 4+ fields. Small record/newtype for 4+ similar-typed args.
- **JSON**: `deriving-aeson` with `StripPrefix` + `CamelToSnake` for snake_case API fields.
- **Errors**: Use `TxBuildingException`; map to HTTP via `txBuildingExceptionToHttpStatus`. No raw strings.

## Workflow

- **After implementing a plan**: Run `cabal build all` then `cabal test` before considering work done.
- **Config loading**: `decodeConfigEnvOrFile "ENV_VAR" defaultPath`. Ports: `getPortFromEnvOrDefault`.
- **Swagger**: Auto-generated on API startup to `docs/generated/swagger/`. Do not edit by hand.
- **Blueprint**: Generated by `admin write-blueprint`. Do not edit by hand.
- **Metrics doc**: Generated by `admin write-metrics-doc`. Do not edit by hand.
- **Published formulas are a contract**: every metric the API or UI shows must be re-derivable from the
  SQL served at `/metrics/formulas`. No composite scores, no undocumented filtering, no inferred intent.
- **Scripts** (`scripts/`): Maintained tooling. Update when changing admin CLI, config, or test flows.
- **New concept**: Follow phase order: onchain types → validator → minting → domain types → tx building →
  API → chain-sync → admin → tests → deployment. See `src/lib/offchain-lib/CLAUDE.md` for the full checklist.
