# Executable Rules

Four executables: `admin` (CLI), `interaction-api` (8082), `query-api` (8083), `attest-sync` (8084).
Sources in `src/exe/<name>/`.

## Admin CLI

- Single `Main.hs` with `Command` sum type, optparse-applicative `hsubparser`, `executeCommand` dispatch.
- **Context**: `Either ProviderCtx TxBuildingContext` — `Left` for deploy/blueprint/limited queries,
  `Right` for full tx-building.
- **Tx commands**: Convert CLI args → `ActionType` → `runPalmaresActionWithPK txBuildingCtx signKey actionType Nothing`.
- **Read-only commands**: `runQuery providerCtx (runReaderT lookupFn deployedScriptsCtx)` — no signing.
- **Parsing**: Use `maybeReader` for asset classes (JSON-decode) and custom parsers for enums. Share
  parsers (e.g. `profileDataParser`, `assetClassParser`, `claimedPeriodParser`, `outputIdParser`) across commands.
- **New command**: Add `Command` constructor + `*Args` → parser with `command "kebab-name"` → conversion to
  `ActionType` → case in `executeCommand`.

## HTTP API Servers (interaction-api, query-api)

- **Startup**: Write Swagger JSON → load config → `withCfgProviders` → build app context → `runSettings`.
- **App monad**: `*AppContext` record + `newtype *AppMonad a = *AppMonad (ReaderT *AppContext Handler a)`.
  Hoist with `hoistServerWithContext`.
- **RestAPI module**: API types with `Summary`/`Description`. Include `ProbeAPI` + Swagger UI. Full server =
  swagger :<|> probe :<|> private (auth-protected).
- **WAI app**: `mkPalmaresApp corsCfg ctx = mkCorsMiddleware corsCfg . provideOptions proxyPublicAPI $ serveWithContext ... basicCtx ...`
  with `basicAuthServerContext`.
- **Error handling**: Map `TxBuildingException` to HTTP status. Use `throwError (err404 { errBody = ... })`.
- **New endpoint**: Route type in RestAPI → handler in app monad → wire in server → `ToSchema` for Swagger sync.

## Build-tx vs Submit

- **Build-tx**: Receive used addresses + change address + optional collateral → run builder → return
  **unsigned** tx body CBOR. Do not sign in server.
- **Submit**: Receive unsigned body + witness → add witness → submit via provider.
- **Multi-address wallets**: Accept **list** of used addresses + change address.
- **Collateral**: Use frontend-provided collateral when valid; otherwise framework picks UTxO.
- **Provider config**: Atlas core config (`config_atlas.json`) includes `coreProvider`, `networkId`, and
  optional `logging`/`logTiming`. Servers run inside `withCfgProviders`.

## Query API Specifics

- `QueryAppContext` = auth + `ProviderCtx` + **one** PostgreSQL `ConnectionPool` — db-sync's own database,
  which holds both the `palmares` views and the `palmares_attest` tables. There is no second pool.
- **Two query families, kept apart**:
  - **Governance** (`Query/Gov.hs`): raw SQL over the `palmares` schema. No Persistent entities for
    db-sync's tables — the views are the interface, and a view's column list is its contract.
  - **Attestations** (`Query/Projected.hs`): Persistent/esqueleto over `palmares_attest`.
  - Shared helpers in `Query/Common.hs`. There is no `liveprojection` flag and no `Query.Live`: governance
    data has no "live" alternative to a view, and attestation reads come from projections only.
- **`Query/Views.hs`**: embeds `sql/*.sql` with `file-embed` and applies it at boot, so a fresh database is
  brought to the current view set by starting the service. Idempotent — every statement is
  `CREATE OR REPLACE` / `CREATE ... IF NOT EXISTS`.
- **`Query/Refresh.hs`**: the one materialized view's `REFRESH ... CONCURRENTLY` loop, interval from
  `PALMARES_VIEW_REFRESH_SECONDS`.
- **`Query/Metrics.hs` + `Metrics/Catalog.hs`**: serve `/metrics/formulas` from the embedded
  `resources/metrics/*.sql`. The SQL file is the single source of truth for a metric; the catalog only
  names and groups it.
- **`Query/ServiceStatus.hs`**: `/status` and `/ready`. Readiness is db-sync lag, not process liveness:
  red above `PALMARES_READY_MAX_LAG_SECONDS`, amber above `PALMARES_AMBER_LAG_SECONDS`.

## attest-sync

- Startup: port/env → PG pool → load config → derive Kupo match pattern → schema-version/policy probe →
  wipe (if stale) → migrations → local tip used as-is (empty cursor syncs from origin) → `SyncMetrics` MVar →
  fork probe server → `forever` sync loop.
- Sync loop: get tips → `evaluateChainSyncState` (UpToDate|Behind|Ahead|UpToDateButDifferentBlockHash) →
  Behind fetches then updates tip to the bound fetched; Ahead/UpToDateButDifferentBlockHash roll back by a
  bounded margin (`rollbackTo` wipes and replays projections) and let the loop heal forward.
- Probe server: separate module, `mkServiceProbeApp`, returns 503 when not synced.
- This service owns **only** `palmares_attest`. It must never write to the `palmares` schema or to any
  db-sync table.

## Shared Conventions

- **Config**: `Constants` for defaults. `decodeConfigEnvOrFile`. `getPortFromEnvOrDefault`.
- **Auth**: `getBasicAuthFromEnv` + `basicAuthServerContext`. `BasicAuth "user-realm" AuthUser :>` for
  private routes. **query-api's read surface is public** (rate-limited, no Basic auth) — that is a product
  requirement, not an oversight; only write and admin routes are protected.
- **CORS**: `mkCorsMiddleware` (from env `CORS_ALLOWED_ORIGINS`) as outermost middleware. Empty allowlist
  denies all cross-origin: fail-closed.
- **Swagger**: Written to `docs/generated/swagger/` on startup. Do not edit by hand.
