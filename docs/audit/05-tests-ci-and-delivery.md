# 05 — Tests, CI/CD, build reproducibility, containers and operational scripts

> **Reconciled 2026-10-23 against `main` @ `2bf5bde`.** Every finding below has been re-judged; the per-finding verdicts, with current `path:line`, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md). Line references in this file are as of `4eb9117` and several have moved.

Audit of `mariusgeorgescu/palmares` at `4eb9117` (main, 2026-10-22). Static reading only: no
Haskell toolchain, no Docker and no network were used, so every "runs/passes" statement below is
what the files say, not what was executed. 94 commits, first on 2026-10-20; no tags exist.

Severity scale: Critical / High / Medium / Low / Info. Effort: S (< half a day), M (1–3 days),
L (> 3 days). Every claim cites `path:line`.

## 0. Executive summary

The test suite is unusually deliberate for a two-day-old repository: 537 `testCase`s, 60 CLB
emulator cases, 8 fixture-gated cases, and — the most valuable part — every negative emulator
case that names a trace code really asserts it (`src/test/Test/Helpers.hs:44-49`), while two
hand-built-`ScriptContext` modules pin 25 more conjuncts as valid/broken pairs. The CI gates the
generated artefacts (metrics doc, two Swagger files, packaging, vocabulary, secrets) and the
comments are mostly honest about what each job proves.

The delivery side is weaker than the test side. The five most important findings:

1. **TD-01 (High)** `.dockerignore` does not exclude `config/config_atlas.json` or
   `config/config_palmares_validators.json`, and every service Dockerfile does `COPY config ./config`
   twice — once into the builder, once into the runtime image. A local `scripts/build-images.sh`
   bakes the provider token into the image. ADR 0002 claims the opposite.
2. **TD-02 (High)** `compose.yaml` has no `attest-sync` service and its `interaction-api` service
   sets no `BASIC_USER`/`BASIC_PASS`, which the binary dies without. The `write` profile cannot
   start as written, and nothing in any profile feeds `palmares_attest`, so the seven attestation
   routes the query API serves are empty on a compose stack.
3. **TD-03 (High)** CI caches `dist-newstyle` across runs while commit `43ab998` documents that a
   `ghc-options` change "does not reliably force cabal to recompile … a fresh checkout is never
   affected, so CI and Docker were always fine". With the cache, CI is not a fresh checkout.
4. **TD-04 (Medium)** 22 of 63 on-chain trace codes have no validator-level test; two of them
   (`Mp6`, `O6`) were added on 2026-10-22 as security fixes and shipped without a test, against the
   repo's own rule in `src/test/CLAUDE.md:36-37`.
5. **TD-05 (Medium)** Three toolchains build the code (Nix/devx locally, haskell-actions on Ubuntu
   glibc in CI, `benz0li/ghc-musl` static in images). The binary CI tests is never the binary that
   ships, and the image base is a floating tag with unpinned `apk add` and an unchecksummed
   libsodium tarball.

## 1. Test coverage map

### 1a. On-chain negative tests — trace code → coverage

Legend. **E** = emulator case asserting the code with `mustFailWith (failedWithTrace "X")`;
**L** = pure lambda-level pair (an otherwise-valid `ScriptContext` that must give `True`, and a
one-field mutation that must give `False`) — behaviour pinned, code string not asserted;
**F** = only the helper function is tested, not the validator conjunct that calls it;
**U** = no validator-level test. Line numbers are in `src/lib/onchain-lib/Palmares/Onchain/`
for the code and `src/test/UnitTests/` for the test unless stated.

`failedWithTrace` (`src/test/Test/Helpers.hs:44-49`) splits the rendered exception at
`dpfExecutionLogs = ` and looks for `show code` in the next 200 characters. The quotes added by
`show` are what stop `"D1"` matching inside `"Md1"`. The claim in commit `c0b270d` that the codes
"are a fiction" was true under `remove-trace`; `palmares.cabal:94-95` now passes
`preserve-logging` + `optimize` and no `remove-trace`, so the codes exist in every build. Two
stale `-- {-# OPTIONS_GHC … remove-trace #-}` pragmas survive at
`Validators/AttestationsValidator.hs:6` and `Validators/ProfilesValidator.hs:8`.

| Code | Script (site) | Rule | Cov. | Where |
|---|---|---|---|---|
| U0 | Utils.hs:63 | context parses | U | — |
| U1 | Utils.hs:332 | own input found by ref | U | — |
| U2 | Utils.hs:421 | state NFT at expected address | U | — |
| U3 | Utils.hs:427 | output has inline datum | U | — |
| M0 | MintingPolicy.hs:174 | not paused | L | MutationGuards.hs:150 |
| M1 | MintingPolicy.hs:185 | minting purpose | U | — |
| Mq | MintingPolicy.hs:243 | date inside validity window | E+F | Attestation.hs:354; OracleRules.hs:62-139 |
| Mm | MintingPolicy.hs:244 | metadata byte limits | L | MetadataLimits.hs:118 |
| Mn | MintingPolicy.hs:245 | otherMetadata bounded, unique | E+F | Attestation.hs:340; MintInputs.hs:92-120 |
| Mf | MintingPolicy.hs:246 | issuer user NFT spent | E | Attestation.hs:377 |
| Mg | MintingPolicy.hs:247 | subject/issuer are REF tokens | F | MintInputs.hs:44-73 (no validator case) |
| Mh | MintingPolicy.hs:248 | seed spent | L | MutationGuards.hs:605 |
| Mj | MintingPolicy.hs:249-251 | mint exactly one NFT, no burn | L | DisputeRules.hs:716-737 |
| Mk | MintingPolicy.hs:252 | lock at attestations address | L (stake variant only) | MetadataLimits.hs:169 |
| Mp1 | MintingPolicy.hs:285 | seed spent | L | MutationGuards.hs:600 |
| Mp2 | MintingPolicy.hs:286-288 | mint exactly ref+user | E | Profile.hs:256, 283 |
| Mp3 | MintingPolicy.hs:289 | credential control proven | E+F | Profile.hs:164, 209, 234; Claim.hs |
| Mp4 | MintingPolicy.hs:290 | metadata byte limits | L | MetadataLimits.hs:123-132 |
| Mp5 | MintingPolicy.hs:291 | lock at profiles address | L (stake variant only) | MetadataLimits.hs:171 |
| Mp6 | MintingPolicy.hs:315 | user token not locked with state | **U** | added 2026-10-22 (ScriptSize.hs:156), no test |
| Md1 | MintingPolicy.hs:400 | seed spent | L | MutationGuards.hs:610 |
| Md2 | MintingPolicy.hs:401-403 | mint exactly dispute NFT | L | DisputeRules.hs:573-594 |
| Md3 | MintingPolicy.hs:404 | opener user NFT spent | L | DisputeRules.hs:597-621 |
| Md4 | MintingPolicy.hs:405 | target/opener are REF tokens | E+F | Dispute.hs:387; MintInputs.hs |
| Md8 | MintingPolicy.hs:406 | deposit address spent from | E | Dispute.hs:363 |
| Md5 | MintingPolicy.hs:407 | lock at disputes address | L (stake variant only) | MetadataLimits.hs:173 |
| Md6 | MintingPolicy.hs:408 | open date in window | L | DisputeRules.hs:628-639 |
| Md7 | MintingPolicy.hs:409 | metadata byte limits | L | MetadataLimits.hs:136 |
| A0 | AttestationsValidator.hs:98,100 | datum present/parses | U | — |
| A1 | AttestationsValidator.hs:131-139 | re-lock accepted at same address | L | MutationGuards.hs:203 |
| A2 | AttestationsValidator.hs:146 | spending purpose | U | — |
| A3 | AttestationsValidator.hs:119 | not already accepted | E | Attestation.hs:167 |
| A4 | AttestationsValidator.hs:96 | cleanup refuses backed state | E | Cleanup.hs:179 |
| A5 | AttestationsValidator.hs:142 | subject user NFT spent | L | MutationGuards.hs:216 |
| A6 | AttestationsValidator.hs:145 | own input holds attestation NFT | L | MutationGuards.hs:223 |
| N0 | OracleNFTPolicy.hs:38 | seed spent | U | — |
| N1 | OracleNFTPolicy.hs:42 | minting purpose | U | — |
| N2 | OracleNFTPolicy.hs:39-41 | mint exactly oracle NFT | E | Oracle.hs:319, 323 |
| K1 | Protocol/Lookup.hs:73-75 | oracle readable | L (exception, code not assertable) | MutationGuards.hs:799 |
| K2 | Protocol/Lookup.hs:126 | fee paid | L+F | MutationGuards.hs:1035-1076; Fees.hs |
| K3 | Protocol/Lookup.hs:51-52 | profile ref input readable | U | — |
| D0 | DisputesValidator.hs:105,107 | datum present/parses | U | — |
| D1 | DisputesValidator.hs:153 | admin signed | E | Dispute.hs:281 |
| D2 | DisputesValidator.hs:154-167 | resolved re-lock, NFT backing | L | DisputeRules.hs:392-449 |
| D3 | DisputesValidator.hs:152 | not already resolved | E | Dispute.hs:298 |
| D4 | DisputesValidator.hs:183 | deposit returned | L | DisputeRules.hs:454-487 |
| D5 | DisputesValidator.hs:185 | spending purpose | U | — |
| D6 | DisputesValidator.hs:184 | one dispute per tx | E+L+F | Dispute.hs:413; MutationGuards.hs:853-856; Satisfaction.hs |
| D7 | DisputesValidator.hs:146 | not paused | E | Pause.hs:114 |
| D8 | DisputesValidator.hs:103 | cleanup refuses backed state | E | Cleanup.hs:188 |
| P0 | ProfilesValidator.hs:93,95 | datum present/parses | U | — |
| P1 | ProfilesValidator.hs:131 | spending purpose | U | — |
| P2 | ProfilesValidator.hs:153 | own value holds ref NFT | U | — |
| P3 | ProfilesValidator.hs:154 | user NFT spent | L | MutationGuards.hs:286 |
| P4 | ProfilesValidator.hs:155 | metadata byte limits | L | MetadataLimits.hs:143-145 |
| P5 | ProfilesValidator.hs:156 | re-lock updated profile | U (baseline only, MetadataLimits.hs:113) | — |
| P6 | ProfilesValidator.hs:129 | not paused | E | Pause.hs:93 |
| P7 | ProfilesValidator.hs:91 | cleanup refuses backed state | E | Cleanup.hs:170 |
| O0 | OracleValidator.hs:74 | oracle datum parses | U | — |
| O1 | OracleValidator.hs:84 | admin signed | E | Oracle.hs:203, 272, 281 |
| O2 | OracleValidator.hs:85 | oracle returned at index with computed datum | L (+E positive, Oracle 0.8) | DisputeRules.hs:788-826 |
| O3 | OracleValidator.hs:94 | spending purpose | U | — |
| O4 | OracleValidator.hs:77 | redeemer parses | U | — |
| O5 | OracleValidator.hs:86 | incoming admin signed on handover | E | Oracle.hs:300 |
| O6 | OracleValidator.hs:92 | params well-formed | **U** | added 2026-10-22 (ScriptSize.hs:149), no test |

Totals: 63 codes; 19 E, 25 L (several both), 22 U. Fourteen of the 22 untested are structural
arms (wrong purpose, unparseable datum/redeemer, `U0`–`U3`) whose deletion would not compile or
would break every positive test; the eight that matter are `Mp6`, `O6`, `P2`, `P5`, `N0`, `K3`,
`Mg` and `U2`/`U3`. See TD-04.

Observed brittleness: `failedWithTrace` only inspects the first 200 characters of the log list
(`Helpers.hs:47`), so a case that emits more than ~20 traces before the one asserted would fail
for the wrong reason; today no validator emits that many. Comments in `Helpers.hs:37`,
`Oracle.hs:23` and `ScriptSize.hs:201` still call `preserve-logging` a cabal *flag* that is "on by
default"; `palmares.cabal:92-93` says it is deliberately no longer a flag. `@Ml@` is referenced in
`Attestation.hs:16,345,349`, `TestRuns.hs:476,654,681`, `MetadataLimits.hs:318` but the code is
now `Mq` (`MintingPolicy.hs:240-243`).

### 1b. Property tests (`src/test/PropertyTests.hs`)

Pinned: `applyAdminAction` ≡ `applyOracleAdminAction` for every constructor on two base states
(:73-104); the constructor-index table is exhaustive and fails on a seventh action (:86-87); the
redeemer applies the named change (:91-93); `toBuiltinData`/`fromBuiltinData` round-trips for
every enum and datum type, including the CIP-68 wrapper (:125-156). There are no generators —
the module explains (:23-29) that the input spaces are finite sums and tables are the property;
`hedgehog`/`QuickCheck` are not dependencies (`palmares.cabal:546-587`).

Mirrors that exist without a property:

- Off-chain id derivation `gyGenerateRefAndUserAC`/`gyDeriveUserFromRefAC`
  (`src/lib/offchain-lib/Palmares/TxBuilding/Skeletons.hs:21-35`) against on-chain
  `generateRefAndUserTN`/`deriveUserFromRefAC`. Only implicitly pinned: an emulator mint would fail
  `Mp2`/`Mk` if they diverged. A direct equality test over random `TxOutRef`s would localise it.
- The off-chain validity width vs `maxDateWindow` is pinned (`OracleRules.hs:103-108`), as are
  CIP-67 prefixes (`MintInputs.hs`), metadata bounds (`Test/Fixtures.hs:141-167`,
  `MetadataLimits.hs`), CIP-129/105 codec (`GovIds.hs`), domain↔on-chain enums
  (`Conversions.hs:105-110`). `feeFor` and `resolveDispute` have one implementation used by both
  layers (`Lookup.hs:100-103`, `Operations.hs:58`), so no mirror exists — good.

### 1c. Emulator / integration (`src/test/TestRuns.hs`, 60 `mkTestFor` cases)

Runners exist for profile, dispute, protocol (cleanup) and admin interactions plus a two-signature
admin rotation (`TestRuns.hs:307-400, 1075-1100`), all through `interactionToTxSkeleton`, and
twelve malicious builders (`TestRuns.hs:222-1062`). **Privnet is not used anywhere**
(`grep mkPrivnetTestFor|withPrivnet` → nothing), although `src/test/CLAUDE.md:14-16` describes it
as a backend. **`withWalletBalancesCheck` is not used anywhere** (`CLAUDE.md:32-33` prescribes
it); balance deltas are only *logged* via `withBalance` (`TestRuns.hs:309, 338, 361, 383`), and
one Dispute case reads a delta (`Dispute.hs`, 1 use). Bare `mustFail` remains in 12 places, all
documented as off-chain refusals (`Attestation.hs:21-24`).

Inherited fixes #1–#5 each have a test that the module says fails on the old behaviour:
#1 `Fees.hs:34-45` + `MutationGuards.hs:1035-1076`; #2 `OracleRules.hs:36`, `Oracle.hs:229-230`;
#3 `ChainSyncReplay.hs:99-116`, `Projections.hs:304` ("fails on the old behaviour: before the fix
it projected a profile"); #4 `OracleRules.hs:62,91`, `Attestation.hs:83`, `DisputeRules.hs:628-639`;
#5 `ChainSyncReplay.hs:152-155`, `Projections.hs:353-373`. The promise holds.

### 1d. Hand-built `ScriptContext` suites

- `MutationGuards.hs` (1155 lines): M0, A1/A5/A6, P3, Mp1/Mh/Md1, K1, K2, D6 — every case a
  `(True, False)` pair differing in one field (:20-26). Brittle points: fixtures bake
  `opMinUTxOValue = 2_000_000` and output index 0 conventions; the `K1` case can only observe an
  exception (:783-789).
- `DisputeRules.hs` (832 lines): D2, D4, Md2, Md3, Md6, Mj, O2 with a positive control per arm.
- `MetadataLimits.hs`: Mm/Mp4/Md7/P4 at the byte boundary; Mk/Mp5/Md5 *only* for the
  staking-credential variant of the address (:167-173) — a wrong script hash is not exercised.
- `OracleRules.hs`, `MintInputs.hs`, `Satisfaction.hs`, `Claim.hs`, `Fees.hs`: predicate level.
- `Cleanup.hs`, `Pause.hs`: emulator. `ScriptSize.hs:237-241` pins exact sizes (MintingPolicy
  12276); `palmares.cabal:81-82` still says "says 12296" — stale.

Duplication: `MutationGuards.hs:340-565` and `DisputeRules.hs:105-262` each define their own
`ProtocolParams`, oracle reference input, `TxInfo` builder, `inlineOut`/`txOut`, addresses and
hash constants; `MetadataLimits.hs` has a third copy. Three fixture kits that must agree on the
same conventions (index 0 = state, `opFeeConfig = Nothing`) is where a future drift will hide.

### 1e. Database tests

`Test/Pg.hs:46-53` **dies** when `PALMARES_TEST_PG_CONN_STR` is unset — locally and in CI alike;
the CI comment (`ci.yml:114-115`) is accurate. Each `withScratchDb` creates `palmares_test_<pid>`
(`Pg.hs:74-88`), applies the embedded `dbsync-skeleton.sql`, and drops `WITH (FORCE)`. 35 call
sites across Views (4), AttestSchema (10), Refresh (5), Activity (6), Anchor, ThresholdMap,
MetricCatalog, AttestRead, Projections (2 each). Isolation is per test but **the database name is
per process**, so two tests running concurrently (tasty `--num-threads`, or a `-threaded` RTS)
would drop each other's database; today the suite is single-threaded only because the test-suite
has no `-threaded` flag. `MetricFixture.hs:238-250` behaves differently: without
`PALMARES_FIXTURE_PG_CONN_STR` its 8 cases print `SKIPPED` to stderr and **pass** — in CI they are
permanently green and never run.

README §10 (`README.md:104-111`) tells a contributor to run `cabal test` with no mention of
PostgreSQL or either variable; `.env.example` does not list them. On a laptop without Postgres
~35 tests fail. See TD-14.

### 1f. Golden / fixture tests

- `GovIds.hs`, `GovDto.hs`: byte-for-byte vectors from one preprod DRep — stable.
- `Reconcile.hs:125-178` pins preprod population counts (294 DReps, 131 proposals, 195 power
  rows) from `test/fixtures/koios/*.json`; refresh procedure is in `test/fixtures/koios/README.md:10-27`
  and would *change the pinned counts*, i.e. a refresh is a deliberate multi-file edit.
- `test/fixtures/snapshot/` pair is regenerated by `admin reconcile-koios --dump-snapshots`
  (`docs/deployment/koios-parity-gate.md:63-69`); `Reconcile.hs:821` replays it offline.
- `test/fixtures/preprod-epoch-320-metrics.json` (closed epoch) is the right kind of pin.
- `test/fixtures/dbsync-skeleton.sql:1-14` is `pg_dump --schema-only` of db-sync 13.7.1.0 with
  constraints stripped; nothing in the repo regenerates it, so a db-sync upgrade silently stales
  it until `sql/checks` (not in CI) catch the drift.
- `scripts/smoke_query_api.sh` hard-codes ~80 preprod magnitudes (`:117-118, :419, :428, :456,
  :481, :551`) that will move with the chain; the script says so (`:8-9`) but there is no as-of
  epoch guard, which `src/test/CLAUDE.md:49-50` forbids for Haskell tests.

### 1g. Untested areas by module

| Area | Evidence | Coverage |
|---|---|---|
| `webapi-lib` Auth/CORS | `ApiHardening.hs:34-64` | pure helpers yes; `getBasicAuthFromEnv` `die` path and middleware wiring no (`ApiHardening.hs:3-4` admits it) |
| `chainsync-lib` `KupoClient`/`KupoAtlas` | no test imports them (`grep` → none) | HTTP client, pagination, checkpoint parsing untested |
| `attest-sync` `Main.hs:143-170` loop, `ChainSyncLogic` | no test module | state machine (Behind/Ahead/UpToDateButDifferentBlockHash), wipe-on-version-change (`Main.hs:96-110`) untested |
| `interaction-api` `ServiceHandlers` | `InteractionApi.hs` pins schema/encoding only | no handler-level test with a fake provider; `smoke_interaction_api.sh` needs a live stack |
| `admin` CLI | `SignTx.hs` only | optparse parsers, `deploy-reference-scripts`, `apply-roles`/`apply-indexes` (`Main.hs:663-720`) untested |
| `query-api` `RestAPI.hs` routes | `QueryHardening.hs`, `AttestRead.hs` | SQL builders yes; servant wiring only via smoke scripts |
| `sql/checks/*.sql` | `scripts/verify_views.sh` | never run in CI (needs synced preprod) |
| `Query/Projected.hs`, `Pages.hs`, `Aggregates.hs` | `palmares.cabal:359-367` commented out | dead code, not compiled, excluded from `check_vocabulary.sh:32` |

## 2. CI (`.github/workflows/ci.yml`)

Job graph: `haskell`, `determinism`, `secrets` — independent, all on `ubuntu-24.04-arm`
(`:12, :194, :235`); no `needs`, no `permissions:` block (default token scope). Concurrency group
`ci-${{ github.ref }}` with `cancel-in-progress: true` (`:6-8`) applies to pushes to `main` as
well, the exact starvation pattern `images.yml:7-13` describes for the images workflow.

- Timeout 350 min (`:13`) with no build-time measurement recorded; a cold run compiles the whole
  Cardano tree. Open question: what does a cached run cost today?
- Cache (`:102-108`): key = os/arch/ghc + `hashFiles(freeze, cabal.project)`, restore-keys by
  prefix. A freeze bump restores the previous store (partial hit) then saves a new entry — good.
  `dist-newstyle` is in the cached path: see TD-03. The cabal store alone is multi-GB against
  GitHub's 10 GB/repo cache; eviction behaviour is unmeasured.
- `cabal test all --test-show-details=direct` (`:112`) runs the single suite, emulator groups
  included (`UnitTests.hs:89-96`). Duration unknown.
- Drift gates: metrics doc (`:124-128`), both Swaggers (`:165-170`), `check_swagger.sh` (`:177`),
  `check_vocabulary.sh` (`:184`), packaging first (`:40-41`), exit-code contract (`:140-148`).
- Lines 150-151 are orphaned instructions pasted into the workflow ("in the existing `haskell`
  job (keep one blank line …)") — harmless, stale.
- `determinism` (`:193-232`) runs every metric statement twice over an **empty** skeleton. It
  proves the SQL parses and the placeholder plumbing works; with zero rows a plan-order
  nondeterminism cannot manifest, only a `now()` would. The comment (`:186-189`) says exactly this.
- `secrets` (`:234-270`): full-history checkout, the pre-push hook, then gitleaks 8.30.1 via
  `curl | tar` with **no checksum** (`:255-257`), then the allowlist self-test. blst in `haskell`
  is `git clone --depth 1 --branch v0.3.15` (`:68`) — a tag, not a commit.
- Required-status semantics: nothing is `push`-only, so every job can gate a PR; whether branch
  protection requires them is not visible from the repo (open question).
- `images.yml`: tags + `workflow_dispatch` only (`:3-5`); `linux/arm64` only (`:74, :116`);
  bases pushed to GHCR by `:sha` and consumed by `:sha` (`:79, :120-121`) — correct; services
  tagged `:sha` and `:latest` (`:122-124`); `:latest` is also written by a dispatch from any ref.
  No image is ever built from a PR, so a Dockerfile regression is found at release time.
- `reconcile.yml`: nightly, `continue-on-error: true` (`:25`), artifact upload, **no issue, no
  notification** on exit 1/2/3; pulls `palmares-admin:latest` by floating tag (`:58`).

## 3. Build reproducibility

- Local: `.envrc:31` pins devx by rev and nix-direnv by sha256 (`:22`); but `:26` and `:41-42`
  evaluate `nixpkgs#xz.dev` from the **unpinned flake registry** on every load.
- CI: `haskell-actions/setup@v2` GHC 9.6.6 / cabal 3.10 on Ubuntu 24.04 glibc with apt
  libsodium/secp256k1 (`ci.yml:57-59`); images: `benz0li/ghc-musl:9.6.6` (floating tag,
  `Dockerfile.base:4`), libsodium 1.0.19 from source, secp256k1 v0.3.2, blst v0.3.15. Three
  toolchains, three C-library sets — TD-05.
- `cabal.project:17-22` pins both index-states; four `source-repository-package`s are commit +
  `--sha256` pinned (`:25-29, :41-53, :59-63`); `cabal.project.freeze` is committed (30 KB);
  `-Wunused-packages` in `common-options` (`palmares.cabal:44`). `tests: true` globally
  (`cabal.project:14`), so `cabal install <exe>` in the images also plans the test component.
- Plugin flags (`palmares.cabal:64-95`): `defer-errors`, `target-version=1.1.0`,
  `preserve-logging`, `optimize`; comment block is accurate except the stale "12296".
- `hie.yaml` is `cradle: cabal:` (implicit) — fine, but `src/exe/query-api` is in two components
  (`palmares.cabal:482`), so HLS may pick the test component for `Query/*.hs`.
- `.justfile:10-11` runs `cabal run . -- …` which is ambiguous with four executables, and
  `|| true` hides the error. `link-hls` is invoked from `.envrc:38` so `just` is a hard dependency
  of the dev shell without being documented.

## 4. Containers

- Base pinning: `benz0li/ghc-musl:9.6.6` and `alpine:3.20` by tag, no digest (`Dockerfile.base:4`,
  `Dockerfile.runtime-base:5`); `apk add` without `--no-cache` and without versions in the builder
  (`Dockerfile.base:8-47`, with eight packages listed twice); libsodium tarball fetched without a
  hash (`Dockerfile.base:50`, `runtime-base:24`); secp256k1/blst cloned by tag.
- Layering: builder caches dependencies on `*.cabal + cabal.project + freeze` (`Dockerfile.base:89-91`),
  services copy `src`, `config`, `LICENSE NOTICE licenses sql test/fixtures resources`
  (`Dockerfile.admin:21-37`) — matches `extra-source-files` and `check_packaging.sh` enforces it.
- Runtime: **no `USER`** in any Dockerfile (processes run as root), no `HEALTHCHECK` instruction
  (compose supplies one). `Dockerfile.runtime-base:22-57` installs `build-base`/`git` as virtual
  packages in three separate `RUN` layers and deletes them in a **fourth** layer (`:57`), which
  does not shrink the image; the static binaries do not need `postgresql-libs`, `libsodium`,
  `libsecp256k1` at runtime at all.
- `COPY ./config /app/config` in the runtime stage of all four images (`Dockerfile.*:51`) plus
  `COPY config ./config` in the builder (`:22`) — TD-01. `Dockerfile.attest-sync:54-57` bakes
  `PG_CONN_STR` with `password=postgres` as an image default.
- `.dockerignore` misses `config/config_atlas.json`, `config/config_palmares_validators.json`,
  `.cabal/` (the local cabal store `.envrc:35` places inside the repo — potentially gigabytes of
  build context), `out/`, `experiments/`, `.vscode/`.
- Image size: static binaries plus `bash curl postgresql-client` and the undeleted build deps;
  debug symbols are not stripped (`cabal install` has no `--enable-executable-stripping`
  override, and `-optl=-static` keeps symbols unless stripped).

## 5. `compose.yaml`

- Profiles `chain`, `app`, `write` (`:33, :70, :107, :170, :234, :264`). Kupo **is** present,
  under `write` (`:169-225`). `attest-sync` is **absent** from every profile — TD-02. The
  `write` profile's `interaction-api` has no `BASIC_USER`/`BASIC_PASS` (`:236-245`), which
  `Auth.hs:54-62` dies without.
- Pinning: node, postgres, db-sync by digest (`:34, :71, :108`); `cardanosolutions/kupo:v2.12.0`
  by tag (`:171`); the four palmares images by `${TAG:-latest}` (`:235, :265`). The header
  "every image is pinned by its multi-arch INDEX digest" (`:18-19`) is false for five of seven.
- Header says "arm64 and amd64 both work" (`:2`); `images.yml` publishes `linux/arm64` only, so
  on amd64 the `app` profile pulls an image that cannot execute.
- Ports bind to all interfaces: `5432` with default password `devonly` (`:75, :96`), `1442`,
  `8082`, `8083`. No `127.0.0.1:` prefix.
- Resource limits: only db-sync (`:145-150`, 6144M). ADR 0001 measured the node at 2.88 GiB
  against a **3.5 GiB cap** with 59,697 reclaim events (`docs/adr/0001:64, :90-91`) — that cap and
  Postgres's 2048M (`experiments/dbsync-preprod/compose.yaml:69-71, :122-124`) were dropped in the
  promotion, so the root compose does not reproduce the measured conditions.
- Healthchecks and `restart: unless-stopped` on every service — good. `deploy/dbsync/db-sync-config.yaml`
  is single-sourced (`:22-23`); the "ConfigMap generated by one sed" lives outside this repo and
  cannot be verified. `deploy/node-config/SOURCES.sha256:3` says "verify with shasum -c"; only
  `experiments/dbsync-preprod/run.sh:10` does, and nothing runs it for `deploy/` (no CI step).

## 6. Scripts (`scripts/*.sh`, 14 files, all `+x`, `bash -n` clean)

| Script | Purpose | Defects / notes | In CI |
|---|---|---|---|
| build-images.sh | builds 2 bases + 4 services for the host arch, `--load` | `PUSH=true` refused by design (`:27-33`); tags only by short SHA; no digest output | no |
| check_determinism.sh | run each metric twice, compare hashes; exit 0/1/2 | solid; python3 `-I`; portable digest (`:45-48`); references a runbook that does not exist (`:24-26`) | yes (`ci.yml:229`) |
| check_gitleaks_allowlist.sh | plants secrets, asserts the allowlist is value-scoped | **exit 0 when gitleaks is absent** (`:40-44`) — a local run with no binary reports success | yes (`ci.yml:270`) |
| check_packaging.sh | extra-source-files ⊆ Dockerfile COPYs | only checks the four service Dockerfiles; cannot see `.dockerignore` exclusions | yes (`ci.yml:41`) |
| check_roles.sh | privilege separation assertions | hard-coded `kubectl --context minirack-lan -n cardano-preprod` default (`:21`); `set -e` with `$PSQL` unquoted word-split by design | no |
| check_swagger.sh | 29 paths, 24 error codes, parameter rules | counts must be edited by hand on every route change (`:49`) — intended | yes |
| check_vocabulary.sh | bans inherited BJJ vocabulary; StripPrefix and FeeConfig invariants | `DORMANT` list (`:32`) still excludes five **live** test modules; `TestRuns.hs:16` contains the banned word "promotion" and is not caught | yes |
| measure_substrate.sh | ADR 0001 numbers | hard-coded cluster defaults (`:21-22`); `docker exec` paths from the experiment | no |
| reconcile_koios.sh | wrapper propagating 4 exit codes | correct; `rm -f out/divergences.json` first (`:25`) | nightly |
| smoke_attest_flow.sh | claim→attest→dispute end to end | comment `:33-34` "this repo ships no signer" contradicts `admin sign-tx` (`docs/deployment/attest-flow-smoke.md:51-60`); relies on `date -u` (portable) | no |
| smoke_interaction_api.sh | status/auth/admin-refusal checks | fine; needs live stack | no |
| smoke_query_api.sh | ~250 value assertions | preprod magnitudes without as-of guard (§1f); SIGPIPE handling documented (`:162-165`) | no |
| smoke_views.sh | schema object counts, matview populated | `--watch-refresh` sleeps interval+30 s | no |
| verify_views.sh | runs `sql/checks/*.sql` | correct `nullglob`; the *authority* on view correctness, never run by CI | no |

All use `set -euo pipefail` except `check_vocabulary.sh:16` (`-uo`, deliberate for grep) and
`experiments/dbsync-preprod/measure.sh:9`. No secrets are echoed; `reconcile_koios.sh` passes
`KOIOS_API_TOKEN` through the environment only. macOS portability is handled where needed
(`check_determinism.sh:45-48`, `measure.sh:23-25`).

## 7. Secrets hygiene

- Pre-push hook (`.githooks/pre-push`): ignore-set check (`:11-13`), a regex for
  `ed25519_sk1…` and `maestro|blockfrost…key|token` with a 16+ char value (`:20`), tracked-file
  check (`:25`). It scans the tracked tree at HEAD, not history or the staged diff; CI re-runs the
  same hook (`ci.yml:243`), so the two cannot disagree. Hooks are opt-in (`README.md:86-90`).
- `.gitleaks.toml`: `useDefault = true` (`:6-7`) plus four `[[allowlists]]` all scoped to
  `targetRules = ["generic-api-key"]` (`:43-46, :60-65, :92-96, :124-128`); three are value-shaped,
  one is path-scoped to `test/fixtures/*.json`. The "rule-scoped, not path-scoped" claim holds and
  `check_gitleaks_allowlist.sh` tests both halves.
- `.gitleaksignore:20-21`: two fingerprints on commit `2baed8c`, verified to be gitleaks' own
  synthetic AWS id and a public `keyHash` in the first version of the allowlist test. **Nothing
  real was ever committed to this repository**: `git log -S maestroToken` finds only
  `REPLACE_ME` in the example config and the hook's own regex; `-S ed25519_sk` finds only the
  regex. "Leak #2 was a token COMMITTED" (`ci.yml:239`) refers to the inherited Belt System
  history, which is not in this clone. History is clean, not merely allowlisted.
- `.env.example` vs `README.md:141-156` vs code:
  - `BATCH_SIZE` is documented in both and set by `Dockerfile.attest-sync:56`, but **no code reads
    it** (`grep BATCH_SIZE src` → only `FETCH_BATCH_SIZE`).
  - `FETCH_BATCH_SIZE` code fallback is 10,000,000 (`attest-sync/Main.hs:114`); README says 100000.
  - `BASIC_USER/BASIC_PASS` "used by interaction-api, admin" — admin never reads them.
  - `ATLAS_CORE_CONFIG`/`DEPLOYED_VALIDATORS_CONFIG` listed for interaction-api and admin, but
    `attest-sync/Main.hs:81-84` dies without both.
  - Undocumented in README: `PALMARES_PG_OWNER_CONN_STR` (`.env.example:15`, `query-api/Main.hs:100`),
    `PALMARES_NETWORK_NAME` (`Query/Gov.hs:382`), `PALMARES_ADMIN_CONN_STR`,
    `PALMARES_OWNER_PASSWORD`, `PALMARES_RO_PASSWORD` (`admin/Main.hs:706-707, :863-868`),
    `PALMARES_API`, `KOIOS_API`, `KOIOS_API_TOKEN` (`admin/Reconcile.hs:91-93, :403`),
    `PALMARES_TEST_PG_CONN_STR`, `PALMARES_FIXTURE_PG_CONN_STR`.

## 8. Repository hygiene

- `extraction-keep.txt`: a manifest from the extraction; lists `AchievementsValidator.hs` (`:15`),
  `src/exe/chain-sync/*` (`:54-57`), `UnitTests/Achievement.hs` (`:67`) and un-namespaced paths
  that no longer exist. Stale.
- `libblst.pc` at the root is used by both base Dockerfiles (`Dockerfile.base:67`,
  `runtime-base:43`) but says `Version: 0.3.10` and `prefix=/usr/local` (`:1, :9`) while the
  Dockerfiles build v0.3.15 into `/usr`. It works only because `/usr/lib` is a default path.
- `experiments/dbsync-preprod/`: README §6 says experiments are "deleted once their numbers land
  in an ADR" (`README.md:71`); the numbers landed (`docs/adr/0001`), the directory remains and
  explains why (`experiments/dbsync-preprod/README.md:131-143`) — the README rule is now false.
  The node-config set is duplicated byte-for-byte under `deploy/` and `experiments/` (diff clean).
- `docs/generated/.gitkeep` coexists with committed Swagger; `README.md:70` and `CLAUDE.md`
  ("Blueprint: generated by admin write-blueprint") say the CIP-57 blueprint is committed — it is
  not, and `admin/Main.hs:670-675` says so explicitly. `Constants.hs:27` targets
  `docs/generated/palmares-blueprint.json`.
- `palmares.cabal:19-21` ("the SQL and metric-catalog globs below are deliberately commented
  out") and `:97-99` ("every exposed-modules list is comment-prefixed") describe a skeleton that
  no longer exists; `:40-41` is a leftover duplicate; `:354-356` names Plan B as future while
  `Query.Attest` already landed; `:358, :364` comment out `Metrics.Catalog`/`Query.Metrics`, files
  that do not exist under `src/exe/query-api`. `Query/Projected.hs`, `Pages.hs`, `Aggregates.hs`
  exist on disk, are not compiled, and still contain the banned vocabulary (10 hits of
  "practitioner" in `Projected.hs`).
- 0 of 121 Haskell files carry a copyright/SPDX header (Apache-2.0 recommends, does not require).
- `version: 0.1.0` (`palmares.cabal:3`); Swagger versions are `1.0.0` and `3.0.0`
  (`docs/generated/swagger/*.json`); no tag, no CHANGELOG, no release notes.

## 9. Release and operations

- Versioning: images at `:sha` and `:latest`; compose consumes `${TAG:-latest}`; no `v*.*.*`
  tag has ever been pushed, so every published image came from a `workflow_dispatch`. There is no
  mapping from a deployed image to a cabal version or a changelog.
- Rollback: redeploy an older `:sha`. For `palmares_attest` the "migration" strategy is
  **wipe-and-reproject** on any schema-version or policy change (`attest-sync/Main.hs:96-110`);
  a downgrade (`storedVersion > currentSchemaVersion`) is not handled and would run `migrateAll`
  against a newer table shape. The `palmares` schema is `DROP SCHEMA … CASCADE` + reapply on every
  query-api boot (`Views.hs:24`, `check_roles.sh:85-87`), so views need no migration but a boot
  takes a lock (bounded per commit `89398f8`).
- Runbooks present: `docs/deployment/attest-flow-smoke.md`, `koios-parity-gate.md`. Missing:
  deploy/rollback procedure, `preprod-dbsync-sync.md` (promised at `check_determinism.sh:24-26`),
  admin key rotation (the CLI supports it, nothing documents the ceremony), Kupo re-sync and the
  "UTxO before `--since` is invisible forever" footgun (`compose.yaml:196-202`), Postgres
  backup/restore, incident response for a dead projector (only `attest-flow-smoke.md:133-142`).

## 10. Findings

### TD-01 — High — Provider config and deployed-validator config can be baked into images
- Location: `.dockerignore:1-24`; `Dockerfile.{admin,query-api,interaction-api,attest-sync}:22, :51`;
  `docs/adr/0002-write-path-provider.md:28-29`; `CLAUDE.md` Environment section.
- What: `.dockerignore` excludes `.env*`, `*.prv`, `*.skey`, `*.vkey`, `config/*.prv` but not
  `config/config_atlas.json` (holds `maestroToken`) or `config/config_palmares_validators.json`.
  Every service Dockerfile copies the whole `config/` directory into both stages.
- Why: a developer with a real `config/config_atlas.json` (the documented location,
  `CLAUDE.md`) runs `scripts/build-images.sh` and the token lands in a runtime layer of all four
  images; a `docker push` or a shared tarball leaks it. ADR 0002 states the token is "excluded by
  both `.gitignore` and `.dockerignore`" — false for `.dockerignore`.
- Fix: add `config/config_atlas.json`, `config/config_palmares_validators.json`, `.cabal/`,
  `out/`, `experiments/`, `.vscode/` to `.dockerignore`; in the runtime stage copy only
  `config/config_atlas.example.json` and the two reconcile files explicitly; extend
  `check_packaging.sh` to assert every `.gitignore` secret pattern also appears in `.dockerignore`.
- Effort: S.

### TD-02 — High — The compose stack cannot serve attestations and the `write` profile cannot boot
- Location: `compose.yaml:233-261` (interaction-api), whole file (no `attest-sync`);
  `src/lib/webapi-lib/Palmares/WebAPI/Auth.hs:54-62`; `README.md:50-53, :113-119`.
- What: no service runs `attest-sync`, so `palmares_attest` is never populated and the seven
  `/profiles*`, `/attestations*`, `/disputes` routes return empty pages; `interaction-api`'s
  `environment:` lacks `BASIC_USER`/`BASIC_PASS`, and the binary `die`s on boot without them.
- Why: `docker compose --profile write up` restart-loops `interaction-api`; `smoke_attest_flow.sh`
  step 2 would time out at "the issuer profile is projected" against any compose deployment.
  README §8 promises a contributor can "reproduce the whole dataset locally".
- Fix: add an `attest-sync` service (profile `write`, `depends_on: kupo`, `PG_CONN_STR`,
  `KUPO_URL=http://kupo:1442`, `DEPLOYED_VALIDATORS_CONFIG`, same `ATLAS_CORE_CONFIG` as
  interaction-api); add `BASIC_USER: ${BASIC_USER:?}` / `BASIC_PASS: ${BASIC_PASS:?}` to
  interaction-api so the failure is at `compose config` time; add a `docker compose config -q`
  step to CI for each profile.
- Effort: S–M.

### TD-03 — High — `dist-newstyle` cache defeats the "CI is a fresh checkout" assumption
- Location: `.github/workflows/ci.yml:102-108`; commit `43ab998` body; `palmares.cabal:64-95`.
- What: the cache path includes `dist-newstyle`; the key hashes only `cabal.project*`, so source
  and `ghc-options` changes restore a build tree from an earlier commit.
- Why: the project already observed that changing plugin flags "does not reliably force cabal to
  recompile … deleting the component's build tree was [needed]" and concluded CI was safe because
  it is a fresh checkout. With the restored tree, a future flag change (e.g. re-adding
  `remove-trace`, bumping `target-version`) can test a stale `onchain-lib` and still go green;
  `ScriptSize`'s pinned table would not notice a build that did not rebuild.
- Fix: cache only `${{ steps.setup.outputs.cabal-store }}`; or include
  `hashFiles('palmares.cabal')` in the key and drop `dist-newstyle` on any cabal-file change;
  add a `cabal build all --enable-tests -v1 | grep -c Compiling` sanity line is optional.
- Effort: S.

### TD-04 — Medium — 22 trace codes have no validator-level test; two security fixes from 2026-10-22 ship untested
- Location: §1a table; `MintingPolicy.hs:315` (`Mp6`), `OracleValidator.hs:92` (`O6`),
  `ProfilesValidator.hs:153, :156` (`P2`, `P5`), `OracleNFTPolicy.hs:38` (`N0`),
  `Lookup.hs:51-52` (`K3`); `src/test/CLAUDE.md:36-37`.
- What: `Mp6` ("user token must not be locked with the state", the hole that let strangers rewrite
  profiles — `MintingPolicy.hs:292-300`) and `O6` (`oracleParamsAreWellFormed`) have no case; `P2`,
  `P5`, `N0`, `K3`, `Mg` (validator level) likewise.
- Why: the repo's own rule is that a fix without a test "is a hope"; `MutationGuards.hs:4-11`
  records that an earlier mutation run deleted two conjuncts and only `ScriptSize` noticed.
- Fix: one `(True, False)` pair per code in `MutationGuards`/`DisputeRules`: `Mp6` — move the
  user token into output 0; `O6` — each malformed field; `P2` — own input without the ref NFT;
  `P5` — wrong address / lower value; `N0` — re-point the seed; `K3` — profile ref input missing
  or hash datum; `Mg` — subject id with the user prefix.
- Effort: M.

### TD-05 — Medium — Three toolchains; the tested binary is never the shipped binary
- Location: `.envrc:26-42`; `ci.yml:53-99`; `Dockerfile.base:4-91`; `Dockerfile.runtime-base:5`.
- What: Nix/devx locally, haskell-actions + apt on glibc in CI, ghc-musl static in images; base
  images by tag, `apk add` unpinned, libsodium tarball unchecksummed, blst/secp256k1 by tag.
- Why: a libsodium/secp256k1/blst behavioural difference (e.g. the VRF or BLS12-381 paths used
  by `cardano-crypto-class`) would pass CI and fail only in the image, at release time; a tag
  moved upstream changes the image silently; `cabal test` is never run inside the builder.
- Fix: pin `benz0li/ghc-musl` and `alpine` by digest; pin apk versions or at least `--no-cache`;
  verify the libsodium sha256; clone blst/secp256k1 by commit; add a CI job that runs
  `cabal test` inside `palmares-builder` on PRs that touch `Dockerfile.*`/`cabal.project*`
  (even if only on `workflow_dispatch` for cost).
- Effort: M.

### TD-06 — Medium — `check_vocabulary.sh`'s DORMANT exclusion hides five live test modules
- Location: `scripts/check_vocabulary.sh:24-32`; `palmares.cabal:486-536`; `src/test/TestRuns.hs:16`.
- What: the exclusion list says the emulator modules are "comment-prefixed out of the test-suite";
  all five are compiled today. `TestRuns.hs:16` contains "promotion-acceptance attack", a banned
  word, and CI is green.
- Fix: delete the five test paths from `DORMANT` (keep the three `Query/*.hs`), fix the one hit.
- Effort: S.

### TD-07 — Medium — No alerting on nightly parity failure; floating `latest` in the nightly
- Location: `.github/workflows/reconcile.yml:25, :55-59, :62-66`; `docs/deployment/koios-parity-gate.md:35-47`.
- What: `continue-on-error` keeps the workflow green; the only signal is an artifact somebody
  downloads; the admin image is `:latest`.
- Why: an exit-1 divergence (the class that found the 55 missing delegations) is invisible until
  the next release gate reads the artifact by hand.
- Fix: a final step `if: steps.parity.outcome == 'failure'` that opens/updates a GitHub issue
  (`gh issue create`/`peter-evans/create-issue-from-file`) with the row table; pin the image by
  digest or by the last release `:sha`.
- Effort: S.

### TD-08 — Medium — Compose claims that are false: digest pinning, amd64 support, measured limits
- Location: `compose.yaml:2, :18-19, :171, :235, :265, :145-150`; `images.yml:74, :116`;
  `experiments/dbsync-preprod/compose.yaml:69-71, :122-124`; `docs/adr/0001:64, :90-91`.
- What: Kupo and the four palmares images are not digest-pinned; palmares images are arm64-only;
  node and Postgres caps from the measurement rig were dropped.
- Fix: pin Kupo by digest; either build `linux/amd64` in `images.yml` (multi-arch manifest) or
  change the header; restore `cpus`/`memory` for node and Postgres from the experiment file or
  state that they were removed.
- Effort: S (header) / M (multi-arch).

### TD-09 — Medium — Postgres and service ports published on all interfaces with a default password
- Location: `compose.yaml:75, :96, :214, :251, :274`.
- Why: a laptop on a shared network exposes `cexplorer` as `postgres/devonly` and the write API
  with whatever `CORS_ALLOWED_ORIGINS` is empty.
- Fix: `"127.0.0.1:${POSTGRES_PORT:-5432}:5432"` and the same for the others; `POSTGRES_PASSWORD:
  ${POSTGRES_PASSWORD:?set it}` for the `write` profile.
- Effort: S.

### TD-10 — Medium — Unpinned third-party downloads in CI and workflow actions by major tag
- Location: `ci.yml:255-257` (gitleaks `curl | tar`), `:68` (blst by branch), `:29, :96, :102`
  (`actions/*@v4`, `haskell-actions/setup@v2`, `docker/*@v3/v6`); no `permissions:` in `ci.yml`.
- Fix: record the gitleaks tarball sha256 and `sha256sum -c`; clone blst by commit; pin actions by
  SHA (Dependabot can keep them fresh); add `permissions: contents: read` to `ci.yml`.
- Effort: S.

### TD-11 — Medium — Runtime images run as root, keep build toolchains in layers, ship unstripped binaries
- Location: `Dockerfile.runtime-base:22-57`; `Dockerfile.*:47-53` (no `USER`); `Dockerfile.attest-sync:54-57`.
- Fix: do the `apk del` inside each `RUN` that added the virtual package; drop `postgresql-libs`,
  `libsodium`, `libsecp256k1`, `curl` from the runtime (static binaries; busybox `wget` serves the
  healthchecks); `strip` the binary in the builder; `RUN adduser -D -u 10001 palmares` + `USER
  palmares`; remove the baked `PG_CONN_STR` default password.
- Effort: S–M.

### TD-12 — Medium — No image is ever built from a pull request
- Location: `images.yml:3-5`; `check_packaging.sh` header.
- Why: the packaging check catches one class of image-only failure; linker flags, musl
  incompatibilities (`-optl=-static` against a `--disable-static` libsodium, `Dockerfile.base:53`)
  and a changed `COPY` are found only at a tag or a manual dispatch.
- Fix: a weekly scheduled or `paths:`-filtered PR job that builds one service image
  (`admin`, the smallest) from the cached GHCR builder base without pushing.
- Effort: M.

### TD-13 — Low — Scratch databases are named per process, not per test
- Location: `src/test/Test/Pg.hs:76-77`.
- Why: tasty with `--num-threads >1` or a `-threaded` test binary would race `DROP DATABASE … WITH
  (FORCE)` between concurrent cases; the header's "neither share rows nor depend on ordering"
  is only true sequentially.
- Fix: suffix a per-call counter/UUID; or set `TASTY_NUM_THREADS=1` in `cabal.project`'s
  `test-options`.
- Effort: S.

### TD-14 — Low — `cabal test` as documented fails on a clean laptop
- Location: `README.md:104-111`; `.env.example`; `Test/Pg.hs:46-53`; `MetricFixture.hs:238-250`.
- Why: ~35 cases die without `PALMARES_TEST_PG_CONN_STR`; the 8 fixture cases are permanently
  "OK" in CI because a skip is a pass.
- Fix: document the two variables and a `docker run postgres:17-alpine` one-liner in README §10
  and `.env.example`; make the fixture skip visible by emitting it through `tasty`'s
  `ignoreTest`/a custom result rather than a passing `testCase`, and count skips in the summary.
- Effort: S.

### TD-15 — Low — Stale or false comments that steer maintainers wrong
- Location: `palmares.cabal:19-21, :40-41, :81-82, :97-99, :354-367`; `README.md:70-71`;
  `ci.yml:150-151`; `scripts/smoke_attest_flow.sh:33-34`; `Test/Helpers.hs:37`; `Oracle.hs:23`;
  `AttestationsValidator.hs:6`; `ProfilesValidator.hs:8`; `@Ml@` references (§1a);
  `README.md:143-152` (`BASIC_*`/admin, `BATCH_SIZE`, `FETCH_BATCH_SIZE` default).
- Fix: one sweep; delete `extraction-keep.txt`; make `BATCH_SIZE` either read or removed.
- Effort: S.

### TD-16 — Low — `.gitleaks`/pre-push cover history and tree but the local allowlist self-test can silently pass
- Location: `scripts/check_gitleaks_allowlist.sh:40-44`.
- Fix: exit 2 with a clear message when no binary is found, or download the pinned binary.
- Effort: S.

### TD-17 — Low — Dev-shell reproducibility: unpinned `nixpkgs#xz.dev`, hidden `just` dependency
- Location: `.envrc:26, :38, :41-42`; `.justfile:10-11`.
- Fix: pin `nixpkgs` via the devx flake inputs or `--inputs-from`; guard `just link-hls` with
  `command -v just`; fix `cli` to `cabal run exe:admin --`.
- Effort: S.

### TD-18 — Low — `SOURCES.sha256` is never verified for `deploy/node-config`
- Location: `deploy/node-config/SOURCES.sha256:3`; `experiments/dbsync-preprod/run.sh:10`.
- Fix: a one-line CI step `(cd deploy/node-config && shasum -a 256 -c SOURCES.sha256)` plus the
  same for `experiments/`.
- Effort: S.

### TD-19 — Low — `attest-sync` schema downgrade path undefined; no runbooks for deploy/rollback/key rotation
- Location: `src/exe/attest-sync/Main.hs:96-110`; `docs/deployment/`.
- Fix: refuse to start when `storedVersion > currentSchemaVersion` with a message naming the
  image to roll forward to; write the three runbooks listed in §9.
- Effort: M.

### TD-20 — Info — Determinism job runs on zero rows
- Location: `ci.yml:186-232`; `check_determinism.sh:21-27`.
- Note: honest about itself. Seeding the skeleton with the `Activity.hs`/`Anchor.hs` seed rows
  would let a plan-order nondeterminism surface in CI at near-zero cost.
- Effort: S.

## 11. Reviewed and not an issue

- `failedWithTrace` genuinely matches the code string, and `remove-trace` is gone from every
  build (`palmares.cabal:94-95`); the suite would fail loudly, not vacuously, if it came back.
- CHaP root keys in `cabal.project:6-12` are public verification keys; the allowlist entry is
  correct and documented.
- `.gitleaksignore` entries are synthetic test strings; nothing to rotate.
- `images.yml` consuming bases by `:sha` and logging in with `GITHUB_TOKEN` only is correct.
- `check_packaging.sh` as a first, sub-second step is the right ordering.
- `reconcile.yml` being warn-only as a PR gate is a sound decision (`koios-parity-gate.md:49-57`);
  the missing piece is notification (TD-07), not gating.
- `Test.Pg` dying rather than skipping is the right behaviour and is accurately described in CI.
- `-Wunused-packages`, `index-state` pins, `--sha256` on every `source-repository-package`,
  committed freeze file: reproducible as far as cabal can make it.
- Inherited fixes #1–#5 each have a test that fails on the old behaviour (§1c).
- Twelve bare `mustFail`s are all documented off-chain refusals, and the module headers say which
  trace code they deliberately do not name.
- `hie.yaml` implicit cabal cradle is valid.
- All 14 scripts pass `bash -n`, are executable, and (bar one deliberate exception) use
  `set -euo pipefail`.

## 12. What is done well

- Negative tests name the guard: `mustFailWith (failedWithTrace …)` plus malicious builders for
  every check the production path cannot reach (`TestRuns.hs:469-477`), and the Oracle `O1` story
  (`Oracle.hs:9-16`) is the right lesson, written down.
- Pure `ScriptContext` pairs with a positive control per arm (`MutationGuards.hs:20-26`,
  `DisputeRules.hs:13-19`) — mutation-resistant by construction.
- Generated artefacts are gated by regeneration + `git diff --exit-code` (metrics doc, both
  Swaggers) and by value (`check_swagger.sh`), so documentation cannot drift from code.
- `ScriptSize.hs` pins exact bytes and the comment block is a dated changelog of every size move.
- Secrets gate: a self-testing allowlist, fingerprints rather than path exclusions, full-history
  scanning, and a clean history.
- Exit-code contracts are specified and tested (`reconcile-koios` 0/1/2/3, `check_determinism`
  0/1/2, `smoke_attest_flow` 0/1/2), including a CI assertion that transport failure is 2 not 1.
- `compose.yaml` and `db-sync-config.yaml` carry provenance, measured numbers and the reason for
  every non-default (`NETWORK: ""`, `:ro` mounts, `working_dir`).
- Test modules explain what they do *not* cover and why (`Pause.hs`, `MetadataLimits.hs`,
  `MutationGuards.hs`), which made this map possible.

## 13. Open questions for the owner

1. Is branch protection on `main` requiring `haskell`, `determinism` and `secrets`? Nothing in the
   repo shows it.
2. How long does a cached `haskell` job take today, and how much of that is the 60 emulator cases?
3. Does the static link actually succeed against the `--disable-static` libsodium
   (`Dockerfile.base:53`)? The images workflow reportedly succeeded once (`reconcile.yml:43-44`);
   is `libsodium.a` coming from `benz0li/ghc-musl` itself?
4. Where does the Kubernetes ConfigMap generation live (`compose.yaml:22-23`), and is it tested?
5. Is `experiments/dbsync-preprod` still holding the only synced database, i.e. should the README
   §6 rule be rewritten rather than the directory deleted?
6. Is `BATCH_SIZE` meant to exist, or should the three places that mention it be removed?
7. Will `attest-sync` ever run outside Kubernetes? If yes, TD-02's compose service is required; if
   no, `README.md:113-119` should say the compose `app` profile serves governance only.

## 14. Improvement backlog (ranked)

| ID | Severity | Effort | Action |
|---|---|---|---|
| TD-01 | High | S | Exclude `config/config_atlas.json`, validators config, `.cabal/` from the Docker context; stop copying `config/` into runtime images |
| TD-02 | High | S–M | Add `attest-sync` to compose; require `BASIC_USER`/`BASIC_PASS` in the `write` profile; `compose config` in CI |
| TD-03 | High | S | Stop caching `dist-newstyle` (or key it on `palmares.cabal`) |
| TD-04 | Medium | M | Pure pairs for `Mp6`, `O6`, `P2`, `P5`, `N0`, `K3`, `Mg` |
| TD-05 | Medium | M | Digest-pin base images, checksum libsodium, commit-pin blst/secp256k1; run `cabal test` in the builder on Dockerfile changes |
| TD-06 | Medium | S | Remove the five live test modules from `DORMANT`; fix `TestRuns.hs:16` |
| TD-07 | Medium | S | Open an issue on nightly exit ≠ 0; pin the nightly admin image |
| TD-08 | Medium | S/M | Pin Kupo by digest; multi-arch or correct the header; restore node/Postgres caps |
| TD-09 | Medium | S | Bind compose ports to `127.0.0.1`; require a password in `write` |
| TD-10 | Medium | S | Checksum gitleaks, pin actions by SHA, add `permissions:` |
| TD-11 | Medium | S–M | Non-root user, strip binaries, delete build deps in-layer, drop runtime libs |
| TD-12 | Medium | M | Build one image from PRs touching Dockerfiles/cabal files |
| TD-13 | Low | S | Unique scratch-DB names |
| TD-14 | Low | S | Document Postgres for `cabal test`; make fixture skips visible |
| TD-15 | Low | S | Comment/README sweep; delete `extraction-keep.txt`; settle `BATCH_SIZE` |
| TD-16 | Low | S | Allowlist self-test must fail without a gitleaks binary |
| TD-17 | Low | S | Pin `nixpkgs` in `.envrc`; fix `.justfile cli` |
| TD-18 | Low | S | Verify `SOURCES.sha256` in CI |
| TD-19 | Low | M | Downgrade guard in `attest-sync`; deploy/rollback/key-rotation runbooks |
| TD-20 | Info | S | Seed the determinism skeleton |
