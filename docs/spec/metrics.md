# Metric definitions — what each published number means, and what settled it

**Why this file exists.** `/metrics/formulas` serves the expression, the denominator, the null
condition and the SQL of every published metric, and `docs/metrics.md` renders them. What none of
that carries is the *decision*: why this denominator and not the obvious other one, and what number
settled it. Each catalog entry's `spec` field pointed at a design document that was never committed,
so a reviewer could not tell a requirement from a rationalization — finding `DC-43`.

Each section below is the target of one catalog entry's `spec` field. Where the shipped code departs
from what was decided, a **`[Changed: …]`** note says so and why, with the measurement; the original
decision stays. **A reader comparing the SQL against this file is doing the review this file exists
for, so the two must be allowed to disagree visibly.**

Every metric is computed **as of a pinned epoch** — exposed on every response as `as_of_epoch`.
Without it the numbers are not reproducible, because the denominator grows every epoch. That is
success criterion S2 of [the specification](protocol.md#1-objective-and-success-criteria).

## participation_rate_v1

> Of the governance actions this DRep was eligible to vote on and whose voting window has closed, the
> fraction it actually voted on.

```
participation_rate(d, E) = |A_voted(d, E)| / |A_eligible(d, E)|          null if |A_eligible| = 0

A_eligible(d, E) = { a ∈ actions :
      drep_votable(a)                        -- the phase + type rule (Conway bootstrap)
   ∧  a.last_votable_epoch < E               -- the window has already closed
   ∧  ∃ i ∈ drep_interval(d) :               -- registration overlaps the window
          i.from_epoch <= a.last_votable_epoch
       ∧ (i.to_epoch IS NULL OR i.to_epoch >= a.proposed_epoch) }

A_voted(d, E)    = { a ∈ A_eligible(d, E) : a drep_vote row exists for (d, a) }   -- DISTINCT actions
```

**Decision — the denominator is distinct governance actions**, not votes, not vote rows, not epochs.
`eligible_actions` and `votes_cast` are both published next to the rate so the fraction is auditable.

**Decision — eligibility comes from registration intervals, never from `drep_distr` membership**
(`D-2`): `drep_distr` is the stake distribution, so using it would silently drop every DRep with zero
delegated stake out of its own denominator.

**Decision — a still-open action is not a missed vote.** Actions whose window has not closed are
excluded from the denominator and reported separately as `open_actions_unvoted`, because a count of
them is what stops the question "why is 14% not 16%" and is exactly the input a triage tool needs.

**The re-vote measurement that matters here.** One preprod (DRep, action) pair has **20** vote rows,
and 69 pairs have more than one. Both sides of the fraction therefore collapse to distinct actions.
This is also where the implementation actually drifted: the materialized view counted vote ROWS in
the denominator, inflating 23 of 809 preprod DReps by up to 90 actions and understating one
credential's published rate by 34 points (finding `GV-03`, fixed; the agreement is now asserted by
`UnitTests.MetricAgreement`).

## rationale_rate_v1

> Of the actions this DRep voted on, the fraction where its final vote carried a metadata anchor whose
> content was retrieved and whose hash matched.

**Decision — validity is "a row exists in `off_chain_vote_data`", not `is_valid = true`.** db-sync
writes a row there only when the blake2b-256 hash matched; mismatches and unreachable URLs go to
`off_chain_vote_fetch_error` instead. `is_valid` then grades the *body*: `TRUE` = valid JSON
conforming to CIP-100, `FALSE` = valid JSON that does not conform, `NULL` = not JSON at all. Using
`is_valid` as the headline test would punish an honest rationale for a schema nit and would be
indistinguishable from "db-sync has not fetched it yet". The on-chain commitment is the `(url, hash)`
pair, so hash-verified retrievable content is the reproducible fact; schema conformance ships as a
separate, non-headline counter (`rationale_cip100_valid`).

**Decision — the counters are published, so the rate is auditable.** The grades partition the final
votes and sum to `votes_cast` for every row, which is asserted over the whole corpus by
`sql/checks/070_drep_metrics.sql`.

**[Changed: the denominator excludes what could not be assessed.]** As decided, four counters summed
to `votes_cast` and the rate divided by `votes_cast`. The shipped grades are five — `verified`,
`inline`, `unverified`, `pending`, `absent` — and the rate is
`(verified + inline) / (verified + inline + absent)`. Both `unverified` and `pending` are out of both
sides. The reason is a measurement: on preprod, dividing by `votes_cast` published **our indexer's**
inability to fetch `ipfs://` as 36 authors' negligence. `inline` was added for the same honesty: a
`data:` URL carries its rationale on chain, which is stronger than a fetched one, not weaker.
`rationale_pending > 0` means the number is provisional.

## age_days_v1

> Days this DRep has been registered — chain time, gaps excluded.

```
age_days(d, E) = ( Σ_{i ∈ drep_interval(d)} ( min(i.end_time, as_of_time) − i.from_time ) ) / 86400
   where i.end_time = the block time of the retirement certificate, or as_of_time if still registered
```

**Decision — `as_of_time` is the block time of the cursor's block.** Chain time, never `now()` and
never `insertedAt` (inherited fix #5, and `F-09`'s sibling in the same family of inherited defects).

**Decision — a gap is not credited.** A DRep that registered, retired for 50 epochs and re-registered
does not get the gap. The gap itself is visible in `/drep/{id}` → `updates[]`, so there is no extra
field.

**Decision — null, not zero, for a credential that never registered** (`D-17`). It exists in
`drep_hash` only because something delegated to it, so there is no interval to sum. Seven such
credentials on preprod; the invariant is asserted in check 070.

## delegator_retention_rate_v1

> Of the delegators this DRep had 10 epochs ago, the fraction still delegating to it now.

```
D(d, e) = { s ∈ stake_address :
      latest_vote_delegation(s, e).drep_hash_id = d   -- latest as of the end of epoch e
   ∧  stake_credential_registered(s, e) }             -- de-registration kills the delegation

delegator_count(d, E)          = |D(d, E)|
delegator_retention_rate(d, E) = |D(d, E) ∩ D(d, E−W)| / |D(d, E−W)|   null if |D(d, E−W)| = 0
delegators_joined(d, E)        = |D(d, E) \ D(d, E−W)|
delegators_left(d, E)          = |D(d, E−W) \ D(d, E)|
```

**Decision — `W = 10` epochs** (50 days on both networks): one real governance cycle, and longer than
`govActionLifetime`, which preprod has held at **6 epochs** in every Conway epoch (163–321,
`epoch_param.gov_action_lifetime`, and live `/status.epoch_params.gov_action_lifetime`), so a churn
figure spans at least one full action. It is `retentionWindowEpochs` in one place, **bound as a
parameter** rather than written into the SQL, and echoed on the response so a reader never has to
guess the window. A test sets the window to zero and asserts that "previous" equals "today", which is
only true if the parameter really is bound.

**Decision — no projection table in v1.** The interval SQL answers both numbers on demand off two
indexes. The ceiling is recorded: if `/drep/{id}` p95 exceeds 500 ms on preprod, promote the two CTEs
to a materialized view refreshed with the others — a `CREATE MATERIALIZED VIEW` plus one `REFRESH`,
not Haskell.

**This is the one formula the server executes verbatim.** `Query.Gov.delegatorStatsQuery` runs the
catalog's own embedded bytes, because the first implementation here derived it differently — "every
address that ever delegated before epoch N" — and measured 26 previous delegators and a rate of 0.42
where the published formula gives 11 and 1.0.

## vote_latency_median_hours_v1

> Median hours between an action being proposed on chain and this DRep's **first** vote on it.

```
latency_hours(d, a)            = ( first_vote(d, a).cast_at − a.proposed_at ) / 3600
vote_latency_median_hours(d,E) = median over a ∈ A_voted(d, E)      null if |A_voted| = 0
vote_latency_p90_hours(d, E)   = the 90th percentile of the same sample
vote_latency_sample(d, E)      = |A_voted(d, E)|
```

**Decision — hours from the proposal's block time**, not from the start of the epoch and not as a
fraction of the window.

**Decision — the first vote, not the final one.** Latency is about when the DRep showed up.

**Decision — the sample size ships with the number**, because a median over two votes is not a median.
Both percentiles come from `percentile_cont` in one pass: interpolated, not nearest-sample, which the
epoch-319 fixture pins (its median is not a member of the sample, so `percentile_disc` would fail).

## votes_by_type_v1

> For each of the 7 Conway action types: how many this DRep was eligible for, how many it voted on, and
> the Yes/No/Abstain split of the final votes.

**Decision — all 7 types are always emitted**, including rows with `eligible_actions = 0` and
`participation_rate: null`. Omitting them would make a DRep look as though it has no NoConfidence
record when the truth is that preprod only ever had one such action.

**Why it is published at all**: the type-level rates carry the nuance the headline rate flattens. The
fixture DRep reads 14% overall but 38% on InfoActions and 7.6% on TreasuryWithdrawals, because preprod
is dominated by 79 treasury-withdrawal test actions.

## gov_action_state_v1

> A governance action's outcome: proposed, ratified, enacted, expired or dropped.

**Decision — the arms are ORDERED, because db-sync's lifecycle columns are not mutually exclusive.**
An enacted action also carries `ratified_epoch`, and most expired actions also carry `dropped_epoch`.
The view's arm order is therefore part of the definition, not a style choice.

**Decision — state and votability are different questions.** An action whose `expired_epoch` equals
the current epoch reads as `expired` while its window is still open, so `palmares.action_window` —
never this value — decides whether a vote is still possible. `last_votable_epoch` is
`LEAST(expiration − 1, ratified, expired, dropped − 1)`: the ledger's last legal vote epoch is
`expiration − 1`, because db-sync writes `expiration = proposed + lifetime + 1`. All three statements
are asserted against the real corpus in `sql/checks/`.

This paragraph said `LEAST(expiration, …)` while the sentence beside it said `expiration − 1`, and
the view implemented the formula rather than the sentence. Measured before the fix: 4 of 131 actions
were published as votable in the epoch they expired in, `actions_in_flight` read 11 against a true 7,
and 462 of 809 DReps carried a wrong participation denominator. The corpus is unambiguous — of the 96
actions that ever received a DRep or SPO vote, 19 reach exactly `expiration − 1` and none reaches
`expiration`.

## tally_cast_votes_v1

> Per governance action and voter role: the stake that voted Yes/No/Abstain, the threshold that
> applies, and the ratio against it.

**Decision — the (role, action type) → threshold column mapping is a static table with its own test**
(`D-25`). It is ledger law (the Conway ratification rules), it changes only with a hard fork, and the
API echoes `threshold_param` so a client can look the number up itself.

**Decision — the NULLs in that table are informative, and each has its own reason**: the
Constitutional Committee ratifies by a quorum of its members rather than by a stake fraction; an
InfoAction is never ratifiable, so no threshold applies and a missing vote on one must not be read as
a failure to reach quorum; the committee does not vote on its own replacement; SPOs vote on neither
NewConstitution nor TreasuryWithdrawals; and for a DRep on a ParameterChange the threshold is the
maximum over the parameter groups the proposal actually touches, so it is not a single column at all.

**Decision — an SPO's vote on a ParameterChange counts only when the proposal touches the ledger's
security group.** `votingStakePoolThresholdInternal` returns a threshold only when
`any isSecurityRelevant (modifiedPPGroups ppu)`; otherwise the ledger both rejects the vote at GOV and
forces the threshold to zero in RATIFY. So a published `threshold_param = pvtpp_security_group` on a
non-security ParameterChange would name a bar the ledger never set, for a voter it would not have let
vote.

**Decision — the vote-sequence window partitions by `voter_id_hash`** (`D-27`), which is the COLD
credential for the Constitutional Committee. Partitioning by the hot key would count each hot-key
rotation as a separate voter; on preprod that is 648,766 hot keys against 43 cold ones.
