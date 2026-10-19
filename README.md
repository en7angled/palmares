# Palmares

**A public, verifiable track record for Cardano governance.**

Palmares derives every DRep's complete governance history — votes, vote delegations, rationale anchors,
per-epoch voting power, committee and treasury activity — directly from the chain, publishes it through a
free public API and explorer, and lets organizations issue **countersigned attestations** (a claim is only
recorded once its subject accepts it) about delivery, audits and affiliations.

Built for the Cardano community. No token, no protocol fees, no paywall.

## 1. Why you can trust the numbers

Every figure Palmares shows is **re-derivable by anyone, from genesis, using open-source software only**:
`cardano-node` + `cardano-db-sync` + this repository. We add no ledger math of our own — the governance
state comes from db-sync's replay of the Haskell ledger rules, and our layer is a set of read-only SQL
views over it. Koios is used as an independent cross-check, never as a source.

Two rules follow from that, and they are not negotiable:

- **Published formulas.** Every metric ships with the exact SQL that computes it, served at
  `/metrics/formulas` and rendered next to the number. `docs/metrics.md` is generated from that catalog,
  so the documentation cannot drift from the code.
- **No opaque scores.** Palmares reports facts with pinned denominators. It does not rank DReps by a
  composite rating, does not infer intent, and does not tell you who to delegate to.

## 2. Two doors, honestly labelled

- **The read path is fully self-hostable.** Node, db-sync, the API and the explorer need no account, no
  API key and no paid service. If you do not trust our instance, run your own and compare.
- **The write path needs one key of your own.** Submitting an attestation transaction is built through a
  chain provider; you supply your own token. We never hold your keys — transactions are built unsigned
  and signed in your wallet (CIP-30 / CIP-95).

## 3. What it is not

Not a voting tool, not a wallet, not a forum, not a KYC service, and not a replacement for
[GovTool](https://gov.tools). It is the missing memory layer: what each actor actually did, over time,
provably.

## 4. Status

Early development. The first milestone runs the complete product on **preprod**; mainnet follows once the
substrate and validators have soaked. See `docs/adr/` for the decisions and their measurements.

## 5. Architecture

```
cardano-node ──▶ cardano-db-sync (preset only_governance, ledger enabled) ──▶ PostgreSQL
                                                                                 │
                          palmares.* read-only SQL views + one materialized view ┤
                                                                                 ▼
   attestation validators ──▶ Kupo ──▶ palmares_attest.* ──▶ query-api (public) ──▶ explorer / API clients
```

Four Haskell libraries (`onchain-lib`, `offchain-lib`, `chainsync-lib`, `webapi-lib`) and four binaries
(`admin`, `query-api`, `interaction-api`, `attest-sync`). On-chain validators are PlutusTx/Plinth; the
transaction-building stack is Atlas.

## 6. Repository layout

| Path | What lives there |
|---|---|
| `src/lib/` | the four libraries, dependencies pointing inward only |
| `src/exe/` | the four executables |
| `src/test/` | unit, property and emulator tests |
| `sql/` | the schema, the views and the metric SQL, applied at service boot |
| `resources/metrics/` | one `.sql` per metric, embedded at compile time — the single source of truth |
| `docs/adr/` | decision records, each carrying the measurements behind it |
| `docs/generated/` | generated Swagger and CIP-57 blueprint — committed, never hand-edited |
| `experiments/` | throwaway measurement rigs, deleted once their numbers land in an ADR |

## 7. Governance data provenance

The substrate is `cardano-db-sync` with `preset: only_governance` and the ledger **enabled**. The sync is
run **from genesis**, deliberately: db-sync documents that pre-upgrade `drep_distribution` values are not
well defined and can differ between executions, and recomputing from genesis is the documented remedy.
A snapshot restore is therefore not an acceptable shortcut for this data. See
`docs/adr/0001-governance-data-substrate.md`.

## 8. Contributing

Issues and pull requests are welcome. The read path is designed so that a contributor can reproduce the
whole dataset locally; `compose.yaml` brings up node + db-sync + Postgres + the API.

Enable the pre-push checks once per clone — git never propagates hooks:

```bash
git config core.hooksPath .githooks
```

## 9. Licence

Apache-2.0 (`LICENSE`). Portions are derived from the author's own MIT-licensed
[Decentralized Belt System](https://github.com/en7angled/Decentralized-Belt-System); see `NOTICE` and
`licenses/`.

## 10. Quick start

```bash
git config core.hooksPath .githooks        # enable the pre-push checks
docker compose --profile chain up -d       # node + db-sync + Postgres (first sync takes a while)
cabal build all && cabal test              # the Haskell side (needs the Nix/direnv shell)
```
