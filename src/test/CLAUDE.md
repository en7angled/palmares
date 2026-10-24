# Testing Rules

## Test Layout

- **Unit tests**: `UnitTests.hs` + `UnitTests/<Topic>.hs`
- **Integration**: `TestRuns.hs`
- **Property tests**: `PropertyTests.hs` — these pin on-chain logic to its off-chain mirror. When a rule
  exists in both places, the property test is what keeps them equal.
- **Fixtures/helpers**: `Test/Fixtures.hs`, `Test/Helpers.hs`
- **Run**: `cabal test` from repo root.

## Atlas Unified Testing

- **Backends**: Same operations run on **CLB emulator** (fresh ledger, fast) or **privnet** (shared network).
  - Emulator: `mkTestFor`
  - Privnet: `mkPrivnetTestFor` inside `withPrivnet`
- **Test environment**: `TestInfo` provides `testWallets :: Wallets`. Each `User` has `userPaymentSKey`,
  `userAddresses`, `userChangeAddress`, `userCollateral`. Wallets are pre-funded.

## Test Runners

Use `GYTxGameMonad`:
```haskell
asUser user $ do
  skeleton <- myOperation ...
  buildTxBody skeleton >>= signAndSubmitConfirmed
```
Add a runner for every new operation that should be tested end-to-end.

## Assertions

- **Balance checks**: `withWalletBalancesCheckSimple [wallet := valueDelta] $ do ...` (framework accounts
  for fees). `withWalletBalancesCheck` for finer control.
- **Negative tests**: Emulator: `mustFail`. Privnet: `handleError` and match the expected exception (e.g.
  `GYBuildTxException GYBuildTxBodyErrorAutoBalance {}`).
- **Every inherited fix gets a test that fails on the old behaviour.** A fix without such a test is not a
  fix, it is a hope.

## SQL and governance data

The governance layer is views, not Haskell, so its tests are SQL:

- `sql/checks/*.sql` run `ASSERT`s against a real preprod db-sync and are the authority on view
  correctness. They pin exact values measured on-chain; when one fails, first ask whether the chain moved
  before assuming the view broke.
  CI runs the same files against the empty skeleton through `scripts/check_sql_checks.sh`, which
  rewrites each condition to `TRUE OR <condition>` so the block runs to the end: that proves every
  identifier in all 135 conditions still resolves against the schema, and proves nothing about any
  number. The against-preprod run is still the one that signs them.
- `test/fixtures/dbsync-skeleton.sql` creates empty stand-ins for the db-sync tables the views read, so the
  suite needs only an **empty PostgreSQL** rather than a synced db-sync — not no database at all: 85 cases
  connect to one, and without `PALMARES_TEST_PG_CONN_STR` they fail in 14 seconds looking like a broken
  checkout. It is a **shape** fixture only: it catches a renamed column, not a wrong number.
- Never pin a count that a live preprod can change without also pinning the as-of epoch in the predicate.
  An assertion whose truth depends on when it ran is a flake with extra steps.
