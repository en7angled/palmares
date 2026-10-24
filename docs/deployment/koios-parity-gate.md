# The Koios parity gate

F1 check 6. **Koios runs on cardano-db-sync too. It is a completeness check, never a source of
truth, and never a fallback when our own sync is behind.** Every number this API serves comes from
our own views over our own db-sync; this gate only says where two independent readings of the same
chain disagree, and which of those disagreements somebody has already explained.

## Running it

```bash
PALMARES_API=https://gov.cardano.vip/api ./scripts/reconcile_koios.sh
```

The wrapper prints the per-row table and **propagates the exit code**. The nightly workflow runs the
same script against the published `admin` image, by overriding `PALMARES_ADMIN_CMD`.

## The four exit codes

| code | meaning | what to do |
| --- | --- | --- |
| **0** | every row ok, or divergent only where a waiver explains it | nothing |
| **1** | at least one **unexplained** divergence | read `out/divergences.json`, then fix the code or add a waiver with a reason |
| **2** | **transport or decode failure** on either side | check that both services answer; this is not a parity finding |
| **3** | **R10 aborted** — our epoch and Koios's differ by more than 1, or our lag is over the bound | wait for db-sync to catch up; neither a pass nor a fail |

2 is the one code the executable decides itself, and the distinction it makes is the point: *"Koios
did not answer"* and *"Koios answered something different"* are different events. A nightly that
could not tell them apart would either page someone over a network blip or ignore a real divergence
as one.

3 is reached only through a **skipped row**. `reconcileAll` emits `R10` divergent plus
`RowSkipped` for R1–R9, and `mkReport` turns any skipped row into `aborted` — so a run that could
not compare something can never report a pass, and there is no abort branch anywhere to get wrong.

## The release gate

Not the nightly's status — the **artifact**. Download `koios-divergences` from the latest
`reconcile` run and check:

```bash
jq -e '.status=="ok" and .unexplained==0
       and ([.rows[].row]|sort)==["R1","R10","R2","R3","R4","R5","R6","R7","R8","R9"]' \
  out/divergences.json
```

The row-set clause is not decoration. A run whose `rows` are short is a run that skipped something,
and `status=="ok"` alone would not catch a report that compared six rows and liked all six.

## Why the nightly is warn-only

The job needs a live, caught-up stack on **both** sides. As a merge gate it would block every pull
request whenever the Pi is re-syncing or Koios is having a bad night, and a gate that is red for
reasons nobody on the PR can fix teaches people to ignore it.

What *does* gate a pull request is the **replay test**: `cabal test` reconciles the committed
snapshot pair under `test/fixtures/snapshot/` with **no network at all**. So an upstream outage can
never fail a PR, and a PR can never break the reconciliation unnoticed.

## When the nightly does diverge

1. Download the artifact. `out/divergences.json` names the row, the key, the field, and what each
   side said — enough to chase one transaction rather than re-run anything.
2. Re-record the pair at that moment, so the evidence survives the chain moving on:
   ```bash
   PALMARES_API=https://gov.cardano.vip/api cabal run -v0 admin -- reconcile-koios \
     --dump-snapshots test/fixtures/snapshot
   ```
   The replay test then reproduces the finding offline, forever, and the fix has a failing test to
   land against.
3. If it turns out to be a difference we keep, add it to `config/reconcile-exceptions.yaml` with a
   reason, a date and an owner — all three are required. A waiver **explains** a divergence; it does
   not hide it. The report still shows it under `explained`, and the day it stops matching anything
   the report says `stale_exceptions`, which is also the only signal that a divergence was fixed.

## What the first full run found

Seven of the ten rows were clean cold: R1 (294 DReps), R3 (968 power points, exact lovelace), R4
(five per-epoch totals at **zero** tolerance, both reserved ledger options included), R5 (131
actions, the whole lifecycle), R7 (170 vote-history rows), R8, R10.

The first divergence the fixtures ever found was **ours** and was **fixed, not waived**:
`palmares.live_delegation` compared de-registration *epochs* where it had to compare certificates,
and 55 live delegations were missing.

Three differences are waived, and all three are **definitional** — one fact about one field, not a
fact about the rows that happen to show it. That is what `key: "*"` in the waiver file is for:

| row / field | ours | Koios | why ours stands |
| --- | --- | --- | --- |
| R6 tally counts | counts a cast vote as cast | drops votes by **retired** DReps | a tally that shrank as DReps retire would rewrite what an action's vote looked like when it was decided |
| R2 `delegator_count` | delegations **in force** | delegators with **stake** | a delegator with no stake still chose that DRep |
| R2 `active_until_epoch` / `status` | `null`, so `status` is **`unknown`** | computes the deadline itself | db-sync records the ledger's deadline only in `drep_distr`, and 90 of 294 registered DReps have never had a row there |

The last one **was** the only open question, and it is settled: owner decision 2026-10-21, the API
publishes a third status. Before it, `status` fell back to `inactive`, which was right for 69 of
those 90 and **wrong for 21**. Flipping "unknown deadline means active" was implemented, measured and
**reverted** — it would be wrong for 69 to fix 21 — and deriving the deadline was measured and
rejected: a naive `max(last cert, last vote) + drep_activity` is off by up to 5 epochs, because
CIP-1694 does not count **dormant** epochs toward inactivity.

**Read the waiver's new shape before you read its count.** All 90 now report `unknown` while Koios
still reports its own computed answer, so **more** keys diverge than before — 90 rather than 21 — and
**none of them states anything false**. A parity count that went up is the right outcome here: the
divergence is now a difference in what the two sides claim to know, not a difference in what they
claim. `koiosDRepStatus` is deliberately **not** widened to absorb our uncertainty, because mapping
Koios's answer into our own gap would be putting words in the reference's mouth.

The information was always complete on the wire — `active_until_epoch` has always been published and
always been nullable, so those 90 were already identifiable. Only the label above them was a guess.
That is why the fix cost nothing in SQL.

## The committed snapshot is stale (2026-10-24)

`test/fixtures/snapshot/palmares/dreps.json` holds 294 rows whose statuses are only `inactive` (277)
and `active` (17), with 90 rows carrying `active_until_epoch: null`. That is exactly the population
which now reads `unknown`, so the pair **predates the owner decision of 2026-10-21** and the replay
test asserts zero unexplained divergences over a world that no longer exists.

`GV-02`'s live half is fixed: the reconciler no longer sends a status filter, so all 294 registered
DReps are on our side of the comparison and the 90 false `membership` divergences are gone. The
replay test still passes because it exercises the reconciler's LOGIC, which is unchanged by the
relabel — but it no longer certifies anything about today's statuses.

Re-recording needs live Koios and a live query-api, which is why it is not done here:

```
cabal run exe:admin -- reconcile-koios --dump-snapshots test/fixtures/snapshot
```

After it, `dreps.json` should contain `unknown` rows, and the replay assertion becomes a statement
about the current status vocabulary again.
