# Palmares API → Screen Map

**The wire contract.** Every route both backends serve, organised by the screen that consumes it, plus
everything a client has to get right to call them. Written for a React/TypeScript developer who has
never seen this codebase and does not read Haskell.

Two other documents cover *what the product does* (the attestation protocol; the governance read
surface). This one covers *what the HTTP looks like*.

## Provenance

Everything below was measured against the live services on **2026-10-24** unless marked
`UNVERIFIED:`. Where a shape is quoted it is real trimmed output from the running service, not an
example from the schema.

| Service | Base URL | Auth | Swagger document | Version | Routes |
| --- | --- | --- | --- | --- | --- |
| `query-api` | `http://127.0.0.1:8083` | **none — fully public** | `GET /swagger-api.json` | `1.4.0` | **29** |
| `interaction-api` | `http://127.0.0.1:8082` | HTTP **Basic** (`smoke` / `smoke-devonly` in dev) | `GET /swagger-api.json` (public) | `3.3.0` | **15** |
| `attest-sync` | `http://127.0.0.1:8084` | none | *none* | `1.0.0` | **2** |

> **Trap, first five minutes.** The read API's document is at **`/swagger-api.json`**, not
> `/swagger-api.json`'s more obvious sibling: `GET http://127.0.0.1:8083/swagger.json` returns
> **404**. Both services also serve a browsable UI at `/swagger-ui/` (200 on both).

The two version numbers are independent of each other and of the app version.

---

# 1. Complete route inventory

## 1.1 `query-api` — 29 routes, all `GET`, all public

Auth column omitted: **no route on this service requires authentication.** `ErrorCode` carries no
401 and no 403 by design (`src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs:112`).

| Path | What it is for | Screen(s) |
| --- | --- | --- |
| `/health` | Liveness. Always 200 while the process runs. | *none* — orchestrator only |
| `/ready` | Readiness. 503 when the data cannot be answered honestly. | Global status chip (poll) |
| `/status` | Chain point, lag, epoch protocol params, both projectors' state. | Global status chip; Methodology |
| `/metrics/formulas` | The 8 published metric formulas, with SQL and spec refs. | Methodology / "how is this computed" |
| `/dreps` | DRep list. 19 filters, 8 sorts. CSV. | DRep list, Dashboard, Search fallback |
| `/drep/{drep-id}` | One DRep's whole record in one call. | DRep detail — **BROKEN, see §5.1** |
| `/pages/drep/{drep-id}` | *Identical handler to the above.* | DRep detail — **same breakage** |
| `/drep/{drep-id}/power` | Voting power epoch by epoch. Gaps are real, not zero-filled. | DRep detail (power chart) |
| `/drep/{drep-id}/delegators` | That DRep's delegators. CSV. | DRep detail (delegator table) |
| `/drep/{drep-id}/updates` | Certificate history (registered / updated / retired). | DRep detail (timeline) |
| `/pages/drep-explorer` | `/dreps` page **+ 4 sidebar facet counts**, one transaction. | DRep list (**use this, not `/dreps`**) |
| `/gov-actions` | Governance action list. 15 filters, 6 sorts. CSV. | Gov action list, Dashboard |
| `/gov-action/{gov-action-id}` | One action: lifecycle, tallies, thresholds, withdrawals, param changes, proposer, CIP-108 anchor. | Gov action detail |
| `/pages/gov-action/{gov-action-id}` | *Identical handler to the above.* | Gov action detail |
| `/votes` | Every vote. 13 filters, 5 sorts. CSV. 3.24M rows on preprod. | Votes explorer, DRep detail, Action detail |
| `/delegations` | Vote-delegation events. CSV. | Delegation explorer, DRep detail |
| `/spos` | Stake pools in the voting-power distribution. CSV. | SPO list, Dashboard |
| `/committee` | The constitutional committee in force, with quorum. | Committee screen |
| `/treasury-withdrawals` | Treasury withdrawals, requested and enacted. CSV. | Treasury screen, Dashboard |
| `/activity` | Governance activity feed. **Cursor-paged, not offset-paged.** | Activity feed, Hub |
| `/search` | Command-palette search across 6 entity kinds in one call. | Search / ⌘K palette |
| `/pages/dashboard` | Every headline figure in one request. | Dashboard (**one call, whole screen**) |
| `/profiles` | Attestation-protocol profiles. | Profile list |
| `/profiles/{profile-id}` | One profile by asset class. | Profile detail |
| `/profiles/{profile-id}/attestations` | What others have attested **about** this profile. | Profile detail (track record) |
| `/profiles/by-credential/{credential}` | **The verify direction**: which profiles claim this credential. | Verification widget |
| `/attestations` | Attestation list. Filter by subject, issuer, kind, accepted, date. | Attestation list |
| `/attestations/{attestation-id}` | One attestation **with its disputes inline** (max 50). | Attestation detail |
| `/disputes` | Disputes against attestations. | Dispute list |

### Routes no screen needs

| Route | Why |
| --- | --- |
| `/pages/drep/{drep-id}` | Swagger: *"Identical to GET /drep/{drep-id}: same handler, same response."* Pick one path and stay on it. Two URLs for one resource just splits your cache keys. |
| `/pages/gov-action/{gov-action-id}` | Same — identical to `/gov-action/{gov-action-id}`. |
| `/health` | Liveness only. `/status` answers everything a UI wants and `/ready` answers the yes/no. |

### `/dreps` vs `/pages/drep-explorer`

Build the DRep list screen on **`/pages/drep-explorer`**. It accepts every parameter `/dreps`
accepts and returns `/dreps`' own rows and total, plus the four facet arrays the sidebar needs — in
one transaction, so the counts cannot disagree with the list. `/dreps` remains the route for CSV
export and for a list with no sidebar.

## 1.2 `interaction-api` — 15 routes

Everything that builds or submits a transaction is behind Basic auth. The three probe/status routes
and the swagger document are public (`src/exe/interaction-api/RestAPI.hs:298-314`).

| Method | Path | Auth | What it is for | Screen(s) |
| --- | --- | --- | --- | --- |
| `GET` | `/health` | — | Liveness. | *none* |
| `GET` | `/ready` | — | 503 unless all five reference scripts resolve on chain. | Write-flow gate |
| `GET` | `/status` | — | Provider family, network, `deployed_scripts`, `oracle_paused`. | Write-flow gate, banner |
| `POST` | `/build-tx` | **Basic** | Generic: build from an `Interaction` body. | *none* — prefer the typed routes |
| `POST` | `/submit-tx` | **Basic** | Takes `{tx_unsigned, tx_wit}`, submits, returns the tx id. | **Every** write flow |
| `GET` | `/tx-status/{txId}` | **Basic** | `{tx_id, confirmed}`. Poll after submit. | **Every** write flow |
| `POST` | `/claim-profile` | **Basic** | Mint a profile. Claims no credential. | Create profile |
| `POST` | `/update-profile` | **Basic** | Change description + image. Name is immutable. | Edit profile |
| `POST` | `/claim-credential` | **Basic** | Bind profile ↔ governance credential. Needs **both** parties. | Claim credential |
| `POST` | `/withdraw-credential` | **Basic** | End a binding. Authorised by the **credential alone**. | Withdraw credential |
| `POST` | `/issue-attestation` | **Basic** | Issue a pending attestation about a subject. | Issue attestation |
| `POST` | `/accept-attestation` | **Basic** | Counter-sign. Only the subject's wallet. | Attestation inbox |
| `POST` | `/open-dispute` | **Basic** | Contest an attestation, locking a deposit. | Open dispute |
| `POST` | `/resolve-dispute` | **Basic** | Settle. Returns a tx **for the oracle admin to sign**. | Admin console |
| `POST` | `/expire-dispute` | **Basic** | Close an undecided dispute past its deadline. Needs **no authority**. | Dispute detail (anyone) |

`/build-tx` exists but no screen needs it: the nine typed routes cover every action and give you
typed request bodies and specific refusals. `/build-tx` takes an untyped `Interaction` and will hand
you generic failures.

## 1.3 `attest-sync` — 2 routes

| Method | Path | What it is for |
| --- | --- | --- |
| `GET` | `/health` | Always 200 + `SyncMetrics`. |
| `GET` | `/ready` | 200 when `UpToDate` or `Behind False`; **503 otherwise**. |

```json
// GET http://127.0.0.1:8084/health
{"service":"chain-sync","version":"1.0.0","timestamp":"2026-10-24T06:15:31Z",
 "status":{"blockchain_tip":137139240,"local_tip":137139240,
           "chain_sync_state":{"tag":"UpToDate"},
           "db_ready":true,"migrations_complete":true,
           "last_sync_time":"2026-10-24T06:14:05.507182Z"}}
```

`/status` and `/swagger-api.json` are **404** on this service — it has probes and nothing else.

> A browser client should **not** call `attest-sync` at all. Everything it reports is republished,
> better, inside `query-api`'s `/status.attestation` block and the `X-Attest-*` headers. Treat it as
> infrastructure.
>
> **Error-contract exception:** `attest-sync`'s 503 body is a Haskell `show` of the status record,
> not JSON (`src/exe/attest-sync/ChainsyncAPI.hs:63`). `JSON.parse` on it will throw.
> `UNVERIFIED:` I could not force the 503 — the projector was healthy throughout — so this is read
> from source, not measured.

## 1.4 Screen needs with no route

| Screen need | Status |
| --- | --- |
| "Which profile does **my connected wallet** own?" | **No route.** Nothing on either service accepts a wallet address or stake address as a lookup key. §5.2 |
| "What will opening this dispute cost me?" | **No route.** The deposit lives in the oracle datum; nothing publishes it. §5.3 |
| Verify a **committee** credential (`cc_cold1…` / `cc_hot1…`) | **Refused.** The write side accepts committee credentials; `/profiles/by-credential/` is DRep-only and answers `400 invalid_drep_id`. §5.4 |
| One dispute by id | **No route.** `/disputes` is a list; `/attestations/{id}` inlines up to 50. No `/disputes/{id}`. §5.5 |
| One vote by id | No route. Filter `/votes` instead. Low impact. |
| Attestations **issued by** a profile | **Exists:** `GET /attestations?issuer=<asset-class>`. |
| A profile's on-chain transaction history | No route. `slot` + `block_hash` on the profile row are all you get. |

---

# 2. Screen list

Derived from what the API can actually serve. For each screen: the exact calls, their order, what
renders from the first response, what needs a second call, and the N+1 risks.

## 2.1 Global — status chip (every screen)

**Calls:** `GET /status` on mount, then poll every 30–60 s. Read the `X-*` headers off *any*
response you already make instead when you want the chip to track the page you are looking at.

```json
// GET /status  (epoch_params elided)
{"network":"preprod",
 "governance":{"epoch":321,"slot":137140009,"block_time":"2026-10-24T06:26:49Z",
               "lag_seconds":43,"is_ready":true,"source":"cardano-db-sync"},
 "attest_lag_seconds":0,
 "attestation":{"slot":137140009,"kupo_tip_slot":137140009,"lag_seconds":0,
                "state":"following","last_sync_at":"2026-10-24T06:27:22.960784Z",
                "is_ready":true,
                "policy_id":"648c6a732aa55efec29815bdd25cf65c565cf92619aadde1d31496d3",
                "last_error":null,"source":"attest-sync/kupo"},
 "drep_distr_epoch":321,"amber_lag_seconds":120,"ready_max_lag_seconds":300,
 "metrics_as_of_epoch":321}
```

Renders from the one response: network badge, epoch, lag, green/amber/red state, "metrics as of
epoch N", and the protocol parameters the Methodology screen needs. **No second call.**

`attestation` is `null` on a governance-only deployment. Do not assume the object exists.

## 2.2 Hub / landing

**Calls, in parallel:**
1. `GET /pages/dashboard?top_limit=5&closing_soon_limit=5&epochs=6`
2. `GET /activity?limit=10`

Both are self-contained. No N+1.

## 2.3 Dashboard

**One call.** `GET /pages/dashboard?top_limit=10&closing_soon_limit=5&epochs=20`

```
epoch: 321
total_dreps: 204          active_dreps: 17      inactive_dreps: 187   retired_dreps: 523
power_epoch: 321
drep_power_lovelace: 505754377083269
always_abstain_lovelace: 432909247919877
always_no_confidence_lovelace: 330754812982
total_actions: 131        actions_in_flight: 11
actions_by_type:   [["hard_fork_initiation",4], …]        (7 pairs)
actions_by_state:  [["dropped",6], …]                     (5 pairs)
treasury_requested_lovelace: 656466092110010
treasury_enacted_lovelace: 0
closing_soon:            [5]  full gov-action rows (14 fields each)
top_dreps_by_power:      [10] full DRep rows (22 fields each)
participation_by_epoch:  [20] {epoch, dreps_with_power, dreps_voted, votes_cast, participation_rate}
```

Everything renders from this one response: counts, both leaderboards, both chart series, the
treasury pair. **No second call, no N+1.** The rows embedded here are `/dreps`' and `/gov-actions`'
own row shapes, so they link straight to the detail routes without a refetch.

Three things to get right:

- **`power_epoch` is its own field** because the ledger writes the DRep stake distribution one epoch
  behind the tip. The three `*_lovelace` figures are from a different moment than everything else.
  Label them with `power_epoch`, not `epoch`.
- **The treasury is two numbers on purpose.** 83 withdrawals are recorded on preprod and none has
  been enacted. A single "withdrawn" field would be either `0` (true, and reads as *no treasury
  activity*) or the requested total (a lie about the word).
- **`actions_in_flight` is `last_votable_epoch >= epoch`, not `state = 'proposed'`.** Measured 11
  here against 12 for the other definition — the difference is an action whose state already reads
  `expired` while its voting window is still open.

> **`total_dreps` here does not equal `/dreps`' `total`.** Measured: dashboard `total_dreps` = 204 =
> active(17) + inactive(187). `/dreps` with no `status` filter returns `total` = **294** =
> active(17) + inactive(187) + **unknown(90)**. The swagger description for `/pages/dashboard`
> claims `total_dreps` "is the universe /dreps lists by default" — **that is wrong as deployed.**
> If you put the dashboard number next to a link that opens the list, a user will count 90 rows that
> the headline said were not there. Either filter the link to `?status=active&status=inactive`, or
> label the dashboard figure "registered (excl. unknown)".

## 2.4 DRep list

**One call.** `GET /pages/drep-explorer?limit=50&offset=0&order_by=voting_power&sort_order=desc`

```
items:  [50]  the /dreps row shape
total:  294   limit: 50   offset: 0
epoch:  321
status_facets:   [["active",17],["inactive",187],…]        (4 pairs)
anchor_facets:   [["unreachable",51],["valid",50],…]       (4 pairs)
language_facets: [["en-us",50],["",4]]                     (2 pairs)
power_buckets:   [{"lo":0,"hi":1,"count":109},{"lo":1,"hi":1000000000,"count":28},…]  (6)
```

Renders from the one response: the table, the pager, every sidebar count. **No N+1** — each row
carries all 22 fields, including every metric, so nothing in the table needs a per-row fetch.

**The three enumerated facets do not sum to `total`.** Each one is counted over the applied filter
set **with that facet's own predicate removed**, so the sidebar can offer `Retired (523)` while
`status=active` is applied. They sum to every registered credential (805 at the time the swagger was
written). `power_buckets` is **not** a facet in that sense — it is a range control, follows the
filter as applied, and its counts *do* sum to `total`. Rendering a percentage from a facet count
over `total` will produce numbers above 100%.

`reserved` never appears among the statuses: the two reserved ledger options (`always_abstain`,
`always_no_confidence`) hold stake but no credential, and are published by `/pages/dashboard` as
`always_abstain_lovelace` / `always_no_confidence_lovelace` instead.

## 2.5 DRep detail — **cannot be built on the route meant for it**

The intended design is **one call**: `GET /drep/{drep-id}`, which the swagger describes as "One
DRep's whole public record in a single request".

**It returns 503 after 30 s, every time.** Measured five times across all three id forms, both
under contention and serially with nothing else running:

```
/drep/{id}                 503  30.27s  {"code":"db_unavailable","message":"Service temporarily unavailable"}
/drep/{id}  (retry)        503  30.38s
/drep/{id}  (CIP-105 id)   503  30.87s
/drep/{id}  (raw hex id)   503  30.38s
/pages/drep/{id}           503  30.29s
```

30 s is the `statement_timeout` this service pins on every read
(`src/exe/query-api/Query/Gov.hs:250-270`); any read that exceeds it surfaces as `503
db_unavailable`. See §5.1.

**The three sub-resources are fine** — measured serially:

```
/drep/{id}/power?limit=3        200  6.59s
/drep/{id}/updates?limit=3      200  0.39s
/drep/{id}/delegators?limit=3   200  2.26s
```

**Workaround that works today — 4 calls:**

| # | Call | Gives you |
| --- | --- | --- |
| 1 | `GET /dreps?limit=1&q=<id-or-name>` *(or reuse the row from the list you navigated from)* | All 22 identity + metric fields |
| 2 | `GET /drep/{id}/power?limit=200` | The power series |
| 3 | `GET /drep/{id}/updates?limit=50` | The certificate timeline |
| 4 | `GET /drep/{id}/delegators?limit=50&order_by=lovelace&sort_order=desc` | The delegator table |

Fire 2–4 in parallel after 1. Best practice is to pass the row you already have from the list
screen in router state so call 1 disappears entirely.

**What the workaround cannot give you:** the CIP-119 metadata block (`given_name` and `image_url` are
on the list row, but the full off-chain document is not), and the delegator-base movement series.
Those exist only inside `/drep/{drep-id}`.

Add the DRep's votes with `GET /votes?voter_id=<id>&limit=50&order_by=cast_at&sort_order=desc` — a
fifth call, and the right one, because votes are paged and a detail route could not embed them all.

`/drep/{id}/power` deliberately has **gaps**. An epoch missing from the series is an epoch the
ledger's stake distribution did not include this DRep. Zero-filling it turns an absence into a
measurement — render the gap as a gap.

## 2.6 Gov action list

**Call:** `GET /gov-actions?limit=50&order_by=proposed_at&sort_order=desc`

```json
{"items":[{"id":"04f23439…8593f44#0",
           "bech32":"gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v",
           "type":"parameter_change","title":null,"abstract":null,
           "anchor_status":…,"proposed_at":…,"expires_epoch":…,"last_votable_epoch":…,
           "lifecycle":…,"deposit":…,"return_address":…,"treasury_amount":…,"votes_cast":…}],
 "total":131,"limit":1,"offset":0,"next_cursor":null}
```

Renders from the one response: the whole table including vote counts. **No N+1.**

**This route is slow.** Measured serially, nothing else running: **18.9 s, 23.4 s, 13.8 s, 21.8 s,
24.6 s**. Against a 30 s statement timeout that is not headroom — under any concurrency it tips over
into `503 db_unavailable` (observed repeatedly during parallel probing, and on the CSV variant).
Narrowing helps a lot: `?state=proposed&limit=1` came back in **6.8 s**. See §5.6.

Each row carries **both** id forms. Link with `bech32` — see §3.5.

## 2.7 Gov action detail

**One call.** `GET /gov-action/{bech32}` — measured 8.3 s (bech32) / 4.2 s (`%23` form).

```
action:        {id, bech32, type, title, abstract, anchor_status, proposed_at,
                expires_epoch, last_votable_epoch, lifecycle, deposit,
                return_address, treasury_amount, votes_cast}
tallies:       [{role, epoch, yes_power, no_power, abstain_power,
                 yes_count, no_count, abstain_count, ratio, threshold,
                 threshold_param, basis, formula_id}]
withdrawals:   []                      (populated for treasury_withdrawals actions)
param_changes: [{param, group}]        (populated for parameter_change actions)
proposer:      {stake_address, actions_count}
anchor_content: null                   (CIP-108 body — only when the anchor hash verified)
```

Renders from the one response: header, lifecycle, every tally with its threshold, the payment table,
the parameter diff, the proposer's track record, and the metadata body. **No second call, no N+1** —
the tallies are inline for the same reason the attestation route inlines disputes.

`basis` on every tally is `cast_votes_only`: the ratio is over votes **actually cast**, while the
ledger compares against total active voting power. It is an observation, never a prediction.
`lifecycle` is the authoritative outcome — render that as the verdict, and the ratio as a chart.

`anchor_content: null` means the anchor hash did **not** verify (or was never fetched). A document
that does not match its on-chain commitment is not the proposer's statement — do not render it.
Cross-check `anchor_status` for which case it is.

Add the vote list with `GET /votes?gov_action_id=<id>&limit=50`.

## 2.8 Votes explorer

**Call:** `GET /votes?limit=50&order_by=cast_at&sort_order=desc`

```json
{"items":[{"gov_action_id":"04f23439…8593f44#0",
           "gov_action_bech32":"gov_action1qner…dc2a6v",
           "gov_action_type":"parameter_change","gov_action_title":null,
           "voter_role":"drep",
           "voter_id":"drep1yvvgfghlljws2wj0xqxrnals8devtvdzw8hx85ytyhg3jhsjdg36n",
           "voter_hot_hash":"1884a2fffc9d053a4f300c39f7f03b72c5b1a271ee63d08b25d1195e",
           "voter_name":null,"verdict":"abstain",
           "cast_at":{"slot":137136095,"epoch":321,"time":"2026-10-24T05:21:35Z",
                      "tx_hash":"64eda20d…818df99b"},
           "latency_hours":184.0661111111111,
           "is_final":true,"is_first":true,"revote_count":1,
           "anchor":null,"voting_power":null,"voting_power_epoch":null}],
 "total":3244723,"limit":1,"offset":0,"next_cursor":null}
```

**Denormalised on purpose: no N+1.** Each row already carries the action's id, bech32, type and
title, and the voter's id, hot hash and name. You never need a per-row fetch to render the table.

`voting_power` is **nullable** and was `null` on this row — do not assume a number.

3.24M rows on preprod. `voter_role=constitutional_committee` unfiltered is the query that motivated
the statement timeout in the first place (the source notes a page over 3,243,802 committee votes was
still running after 166 s). **Always send a narrowing filter.**

## 2.9 Delegation explorer

**Call:** `GET /delegations?limit=50&order_by=at&sort_order=desc`
Row: `{stake_address, target, target_name, lovelace, at, is_current}` — `total` 2023.

`target_name` is denormalised, so no N+1. `is_current=true` narrows to live delegations.

## 2.10 SPO list

**Call:** `GET /spos?limit=50&order_by=voting_power&sort_order=desc` — fast (0.18 s), `total` 511.
Row: `{pool_id, ticker, voting_power, voting_power_epoch, delegator_count, votes_cast, participation_rate}`.
`ticker` is nullable (was `null` on every measured row). Fall back to a truncated `pool_id`.

## 2.11 Committee

**One call.** `GET /committee` — not paged, returns an object:

```json
{"quorum_numerator":2,"quorum_denominator":3,
 "established_by":"bbfa303aa35d19919934fb5fe36b174609a0c1dfb47a546ccd6ea58aa752e2aa#0",
 "epoch":321,
 "members":[{"cold_hash":"615b54137e73f090d2dddb04317bee41624f4013e5cfe4a5efa76d76",
             "cold_bech32":"cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu",
             "hot_hash":"5bfa7d850280c54110534065fa91a3635bbcc0eadc69c5c792c35e1e",
             "expiration_epoch":372,"status":"active","votes_cast":6,
             "authorized_at":…,"resigned_at":…}]}
```

Whole screen from one response, 3 members. **No envelope** — no `items`/`total`/`limit`. Do not run
it through your generic page parser.

Committee votes are keyed by the **cold** credential. A `cc_hot1…` passed to `/votes?voter_id=` is
accepted and resolves to the hot hash, which **will not match any vote row** — see §3.5.

## 2.12 Treasury withdrawals

**Call:** `GET /treasury-withdrawals?limit=50&order_by=amount&sort_order=desc` — `total` 83.
Row: `{gov_action_id, gov_action_title, beneficiary, amount, enacted_epoch, enacted_at, paid_heuristic}`.

`gov_action_title` is denormalised — no N+1. `paid_heuristic` is a heuristic; label it as one.

## 2.13 Activity feed — the only cursor-paged route

**Call:** `GET /activity?limit=20` then `GET /activity?before=<next_cursor>&limit=20`.

```json
{"items":[{"cursor":"137136153:1:1:0",
           "event_type":"drep_retired","source":"governance",
           "at":{"slot":137136153,"epoch":321,"time":"2026-10-24T05:22:33Z",
                 "tx_hash":"44344d2b…ab96a3"},
           "actor_id":"76810b3e971a94939711c8a8c1e0090a8e497b5de92bdfa0e7aa292b",
           "target_id":null}],
 "total":null,"limit":2,"offset":0,
 "next_cursor":"137136153:0:1:0"}
```

Full cursor semantics in §3.2. For the screen:

- **`total` is always `null`.** Render "load more", never "page 3 of 47".
- **Stop when `next_cursor` is `null`.** Measured: a filter with 11 total rows returned
  `items: 11, next_cursor: null`; a filter with none returned `items: 0, next_cursor: null`.
- `since=<cursor>` polls **forward** for new events — that is your live-feed poll.
- `actor_id` is a **bare 28-byte hex hash**, not a bech32 id. To link it you must encode it
  yourself — see §3.5.
- **N+1 risk, real:** the feed carries no actor name. A feed of 20 rows naively becomes 20 DRep
  lookups. Batch instead: collect the distinct `actor_id`s and issue **one**
  `GET /votes?voter_id=<a>&voter_id=<b>&…` (the parameter repeats) or one `/dreps` page, then join
  client-side on the hash. Do not loop.

## 2.14 Search / ⌘K palette

**One call.** `GET /search?q=<text>&limit_per_group=5`

```json
{"query":"drep","total":22,
 "dreps":{"total":21,"items":[
    {"id":"drep1ygnshajy8m7cjpafmen4fnwuwmsdgcz0htxr484sujuqensu7y5sz",
     "title":"Demo DRep Ada",
     "subtitle":"270bf6443efd8907a9de6754cddc76e0d4604fbacc3a9eb0e4b80cce",
     "badges":[],"status":"unknown",
     "target":{"kind":"drep","id":"drep1ygnshajy8m7cjpafmen4fnwuwmsdgcz0htxr484sujuqensu7y5sz"}}]},
 "gov_actions":{"total":1,"items":[
    {"id":"ccb27f6b…6ae56522#0","title":"Hard Fork to Protocol Version 10",
     "subtitle":"We propose to upgrade the Cardano PreProd test environment…",
     "badges":["hard_fork_initiation"],"status":"enacted",
     "target":{"kind":"gov_action","id":"ccb27f6b…6ae56522#0"}}]},
 "spos":{"total":0,"items":[]},
 "committee_members":{"total":0,"items":[]},
 "profiles":{"total":0,"items":[]},
 "attestations":{"total":0,"items":[]}}
```

Six fixed groups, **always present** even when empty. Every item is already
`{id, title, subtitle, badges, status, target}` — a uniform render shape with a
`target: {kind, id}` you route on directly. **No second call, no N+1.** This is the best-designed
route on the service; build the palette straight onto it.

**Bounds (measured):** `q` is **required** (omitted → `400 invalid_parameter`); < 2 chars after trim
→ `400 query_too_short` (including `q=`, i.e. empty, and whitespace-only); > 100 chars →
`400 query_too_long`. **Debounce and gate on `length >= 2` client-side** or your palette will fire a
400 on the user's first keystroke.

## 2.15 Profile list and detail

**List:** `GET /profiles?limit=50` → `total` 1 on preprod today.
**Detail:** `GET /profiles/{asset-class}` (fast, 0.06 s).

```json
// GET /profiles/648c6a73….000643b0405c1b171a74ffd59115d5ce40426061538507809345dd523dc05ba0
{"id":"648c6a732aa55efec29815bdd25cf65c565cf92619aadde1d31496d3.000643b0405c1b171a74ffd59115d5ce40426061538507809345dd523dc05ba0",
 "name":"palmares-smoke-20261024T062204Z-subject",
 "description":"subject profile for smoke-20261024T062204Z",
 "image_uri":"ipfs://palmares-smoke-placeholder",
 "kind":"person_d_rep",
 "credential":null,"credential_is_script":null,
 "slot":137139877,
 "block_hash":"422f3ab5f51388d4a762983f00f2421d7b3c070630015fc77797060f97507a11"}
```

**Then** `GET /profiles/{id}/attestations?limit=50` for the track record (second call, unavoidable —
it is paged).

- `credential` is a **claim, not a proof.** Nothing on chain checks that the claimant controls it,
  and the same credential may be claimed by more than one profile. Never render it as verified.
  `credential_is_script` is **decoded from the CIP-129 header byte**, never inferred: a key
  credential and a script credential can share a hash and are not the same actor.
- `slot` is the only time a projection row carries, published raw. There is no wall-clock timestamp
  and no slot-to-time conversion on this service — do your own, or show the slot.
- The track record is ordered **accepted first, then newest**, and has **no `order_by`**.
  `sort_order` flips only the accepted/unaccepted grouping; within a group rows stay newest-first.
  An unaccepted attestation is a claim the subject has not acknowledged — sorting those to the top
  would make a page of unacknowledged claims look like a record. Render the two groups distinctly.
- `/profiles/{id}` 404s `profile_not_found` for an id that exists on chain but is **not yet
  projected**. That is indistinguishable from "never existed" — see §4.6.

## 2.16 Attestation list and detail

**List:** `GET /attestations?limit=50&order_by=date&sort_order=desc` → `total` **0** on preprod.
**Detail:** `GET /attestations/{asset-class}` — **disputes inline**, up to 50.

Inline and not a second request for the same reason the gov-action route inlines tallies: a client
that fetches challenges separately renders the attestation before they arrive, and an
undisputed-*looking* attestation is exactly the wrong thing to show for a disputed one. **Do not
split this into two calls.**

An upheld dispute is published **beside** the attestation and never hides or deletes it. So
`disputes` being non-empty is the whole signal — then read `verdict` on each, which is `null` while
that dispute is open. Past 50 disputes, fall back to `GET /disputes?target=<id>`.

`UNVERIFIED:` I could not measure the attestation detail or dispute row shapes — preprod has 0
attestations and 0 disputes. §5.7.

## 2.17 Dispute views

**List:** `GET /disputes?limit=50&target=<attestation-id>&resolved=false` → `total` 0 today.

- `resolved` is `verdict IS NOT NULL`, **not a verdict value.** `resolved=false` is the open ones;
  `resolved=true` is the closed ones — which is **three** values, not two: `upheld` and `rejected`
  are the oracle admin's findings, and `expired` means nobody decided and the deadline passed. **A
  screen that wants findings only must read the `verdict` value, not this flag.**
- `deposit` is returned to the opener on **every** outcome. There is no punitive verdict; losing a
  dispute costs network fees and nothing else. Say so in the UI — it changes whether a user dares
  open one.
- Ordered by `opened_at`, newest first, **no `order_by`**.
- No `/disputes/{id}` route — §5.5.

## 2.18 Verification widget

The whole point of the product, and **one call**:

`GET /profiles/by-credential/{cip129-credential}?limit=10`

```json
// GET /profiles/by-credential/drep1ygzlzlzj8r9c3zutlgh9ugqx958cwr6q704xtt9j5uf4lzsz9rwhm
{"items":[],"total":0,"limit":10,"offset":0,"next_cursor":null}
```

**`total` is the answer**, and it has three readings:

| `total` | Meaning | Render |
| --- | --- | --- |
| `0` | Unclaimed credential | "No profile claims this credential" |
| `1` | A single claim | The profile |
| `> 1` | **Contested** — several profiles claim the same credential | All of them. **This API does not pick a winner.** |

Ordered **oldest claim first, by slot**, so `items[0]` is deterministically the first claimant.

**CIP-129 ONLY on this route** — the one exception on the whole service. Measured:

| Form | Result |
| --- | --- |
| `drep1ygzlzlzj8r9c3…` (CIP-129 DRep, 58 chars) | `200` |
| `drep1qhchc53cewygh…` (CIP-105, 56 chars) | **`400 invalid_drep_id`** |
| `05f17c5238cb888b…` (56 hex) | **`400 invalid_drep_id`** |
| `cc_cold1zds4k4qn0eelp…` (CIP-129 committee cold) | **`400 invalid_drep_id`** |
| `cc_hot1…` (CIP-129 committee hot) | **`400 invalid_drep_id`** |

Neither refused form carries a header byte, and `drep` is the HRP for both key and script
credentials — so neither can say which kind it is, and the projection stores the full CIP-129 string
the datum claimed. There is no row to ask, so the caller is asked instead. A non-canonical bech32
*spelling* of an accepted form still matches (decoded and re-encoded before the query).

**Consequence for the UI:** if your input accepts what a user pastes from GovTool or a wallet, you
must convert CIP-105 → CIP-129 **client-side** before calling this route, and that conversion needs
the script flag, which CIP-105 does not carry. Resolve it first via `GET /dreps?q=…` or
`GET /drep/{id}` (which accepts all three forms and returns `has_script`), then re-encode. §3.5.

## 2.19 Methodology / "how is this computed"

**One call.** `GET /metrics/formulas` — a **bare JSON array**, no envelope, 8 entries:

| `formula_id` | `field` |
| --- | --- |
| `participation_rate_v1` | `participation_rate` |
| `rationale_rate_v1` | `rationale_rate` |
| `age_days_v1` | `age_days` |
| `delegator_retention_rate_v1` | `delegator_retention_rate` |
| `vote_latency_median_hours_v1` | `vote_latency_median_hours` |
| `votes_by_type_v1` | `votes_by_type` |
| `gov_action_state_v1` | `state` |
| `tally_cast_votes_v1` | `ratio` |

Each entry: `{formula_id, name, field, expression, denominator, null_when, inputs, edge_cases,
sql_file, sql_object, params, spec, version, sql}`.

Every published metric carries the `formula_id` that produced it, resolvable here. Fetch once, cache
for the session, and put a "ⓘ" on every metric that resolves to its `expression`, `denominator`,
`null_when` and `edge_cases`. `null_when` is what a UI needs to distinguish "0%" from "not
applicable".

## 2.20 Write flows

Every write flow is the same five steps; §4 gives the exact field names.

0. **Gate.** `GET /status` (interaction-api). Block the flow unless `deployed_scripts === true` and
   `oracle_paused === false`. `oracle_paused === null` means the oracle could not be read at all —
   a different fact from `false`, and also a block.
1. **Build.** `POST` the typed route → a JSON **string** of unsigned tx CBOR hex.
2. **Sign.** `wallet.signTx(unsignedHex, true)` → a CIP-30 **witness set** hex.
3. **Submit.** `POST /submit-tx` with `{tx_unsigned, tx_wit}` → a JSON **string** tx id.
4. **Poll.** `GET /tx-status/{txId}` until `confirmed === true`.
5. **Wait for the projection.** The read API does not show the record the moment the tx confirms.
   Poll the read route and watch `X-Attest-State` — §3.4.

| Flow | Route | Who must sign |
| --- | --- | --- |
| Create profile | `/claim-profile` | The user |
| Edit profile | `/update-profile` | Holder of the profile's user token |
| Claim credential | `/claim-credential` | **Both**: the profile's user token **and** the credential |
| Withdraw credential | `/withdraw-credential` | The **credential alone** — not the profile owner |
| Issue attestation | `/issue-attestation` | The issuer |
| Accept attestation | `/accept-attestation` | **Only** the subject's wallet |
| Open dispute | `/open-dispute` | The opener (whose user token the wallet must hold) |
| Resolve dispute | `/resolve-dispute` | The **oracle admin** — build in the UI, sign elsewhere |
| Expire dispute | `/expire-dispute` | **Nobody in particular** — any fee payer |

`/claim-credential` needing two parties is the hard one: one transaction must be authorised by the
profile's user token *and* by the credential. If they are the same wallet it is one signature. If
not, you need a flow that gets a transaction in front of two wallets, which **nothing in this
backend provides** — see §5.8.

`/expire-dispute` needing no authority is deliberate: an exit the oracle admin can gate is not an
exit. Expose the button to everyone on any dispute past its deadline.

---

# 3. The integration contract

## 3.1 Pagination — offset routes

**Parameters:** `limit`, `offset`. Both optional, both integers.

**Envelope** (`src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs:66`) — identical on every paged route:

```json
{"items":[…],"total":294,"limit":50,"offset":0,"next_cursor":null}
```

| Field | Contract |
| --- | --- |
| `items` | The rows. |
| `total` | Total matching rows, **nullable** — `null` on `/activity`. |
| `limit` | The **applied** limit after clamping, not what you asked for. |
| `offset` | The **applied** offset after clamping. |
| `next_cursor` | `null` on every offset route. Only `/activity` populates it. |

**Bounds, measured on `/dreps` (294 rows):**

| Request | `limit` applied | `items` | Status |
| --- | --- | --- | --- |
| *(no `limit`)* | **50** | 50 | 200 |
| `limit=0` | **1** | 1 | 200 |
| `limit=-1` | **1** | 1 | 200 |
| `limit=200` | 200 | 200 | 200 |
| `limit=201` | **200** | 200 | 200 |
| `limit=100000` | **200** | 200 | 200 |
| `limit=abc` / `limit=` / `limit=1.5` | — | — | **`400 invalid_parameter`** |

**A limit out of range is clamped silently, not refused.** Both `0` and `999` have an obvious
intended meaning, and the applied value comes back in the envelope. **Always drive your pager from
the response's `limit`, never from the one you sent.**

| Request | `offset` applied | `items` | Status |
| --- | --- | --- | --- |
| `offset=-5` | **0** | 2 | 200 |
| `offset=293` *(of 294)* | 293 | **1** | 200 |
| `offset=294` | 294 | **0** | 200 |
| `offset=300` | 300 | **0** | 200 |
| `offset=10000` | 10000 | **0** | 200 |
| `offset=10001` | — | — | **`400 offset_too_large`** |

**A page past the end is a 200 with an empty `items` and the real `total`** — not a 404, not an
error. Up to offset 10000. **Above 10000 it is a hard 400**, not a clamp: clamping would silently
serve the wrong page and a client reading row 10,001 would have no way to notice.

Ceiling: `hardOffsetCeiling = 10000` (`src/exe/query-api/Query/Common.hs:75`).

**Page-size ceilings and defaults** (`Query/Common.hs:44-57`):

| Route group | Default | Ceiling |
| --- | --- | --- |
| JSON list routes | **50** | **200** |
| CSV (`Accept: text/csv`) | 50 | **10000** |
| `/activity` | **20** | **100** |

Verified on `/activity`: no `limit` → 20; `limit=0` → 1; `limit=101` → 100; `limit=500` → 100.
Verified on CSV: `GET /spos?limit=12000` with `Accept: text/csv` returned **512 lines** (511 rows +
header, i.e. all of them), while the same request as JSON clamped to `limit: 200`.

> **The swagger document's `limit`/`offset` bounds are useless.** It publishes
> `minimum: -9223372036854775808, maximum: 9223372036854775807` — the Int64 range — for every one.
> It does not publish the real clamps (50/200/10000/20/100), the defaults, or the 10000 offset
> ceiling. **Do not generate your client's validation from the schema.** Use the table above.

**Undeclared parameters are ignored, not refused.** Measured: `/activity?offset=5` returned
`"offset": 0` — `/activity` declares no `offset`, and the parameter was silently dropped. A typo in
a parameter name fails open, returning unfiltered data under a filtered-looking UI. Test your
filters against `total`.

## 3.2 Pagination — the cursor route

**`/activity` is the only cursor-paged route.** It uses `before` / `since` and **not** `offset`.

| Parameter | Meaning |
| --- | --- |
| `before=<cursor>` | The page **older** than that cursor — backward scroll. |
| `since=<cursor>` | Events **newer** than that cursor — forward poll. |
| `limit` | 1–100, default 20. |

The cursor is **opaque**: `"137136153:0:1:0"` — four components, because the feed needs four to
order its rows totally. **Echo it back and never parse it.** A client that learned to read three
components breaks when a fourth is added.

Every item also carries its own `cursor`, so you can resume from any row, not just the page edge.

**Measured semantics:**

| Request | Result |
| --- | --- |
| `/activity?limit=3` | `items: 3`, `next_cursor: "137136112:0:1:0"` |
| `/activity?before=137136112:0:1:0&limit=3` | `items: 3`, `next_cursor: "137136095:0:2:3244721"` |
| `/activity?since=137136112:0:1:0&limit=3` | `items: 2`, `next_cursor: null` |
| `/activity?event_type=gov_action_ratified&limit=100` | `items: 11`, **`next_cursor: null`** |
| `/activity?event_type=committee_resigned&limit=100` | `items: 0`, **`next_cursor: null`** |
| `/activity?before=garbage` | **`400 invalid_cursor`** |
| `/activity?since=garbage` | **`400 invalid_cursor`** |
| `/activity?before=abc&since=def` | **`400 both_cursors_given`** |

**Termination: stop when `next_cursor` is `null`.** It goes null on a short page — i.e. the end of
the feed under the applied filter.

**`total` is always `null`** on this route. A keyset-paged feed cannot count its tail without a
second full scan. `null` was chosen over omitting the field or sending `-1` precisely so that a
client which did not read the docs renders *nothing* rather than something wrong. Your `total`
should be typed `number | null`.

`before` and `since` are **mutually exclusive** — sending both is a 400, not a precedence rule.

## 3.3 Filters and sorts, per route

Enumerated from the swagger document and spot-checked live. `sort_order` is `asc | desc` on every
route that has it. When `order_by` is given without `sort_order`, the default is **`asc`**
(`Query/Common.hs:155`) — probably not what your "sort by voting power" button wants, so always send
both.

**Shared enums**

| Enum | Values |
| --- | --- |
| `DRepStatus` | `active`, `inactive`, `unknown`, `retired`, `reserved` |
| `AnchorStatus` | `valid`, `invalid_schema`, `hash_mismatch`, `oversized`, `unreachable`, `inline`, `not_fetched` |
| `GovActionType` | `parameter_change`, `hard_fork_initiation`, `treasury_withdrawals`, `no_confidence`, `new_committee`, `new_constitution`, `info_action` |
| `GovActionState` | `proposed`, `ratified`, `enacted`, `expired`, `dropped` |
| `VoterRole` | `drep`, `spo`, `constitutional_committee` |
| `Verdict` | `yes`, `no`, `abstain` |
| `ProfileType` | `person_d_rep`, `organization`, `committee`, `community`, `vendor`, `auditor` |
| `AttestationType` | `milestone_delivered`, `audit_passed`, `affiliation`, `role_held`, `endorsement`, `credential_claim`, `credential_withdrawal` |
| `DisputeVerdict` | `upheld`, `rejected`, `expired` |
| `EventType` | `drep_registered`, `drep_updated`, `drep_retired`, `delegation_changed`, `vote_cast`, `gov_action_proposed`, `gov_action_ratified`, `gov_action_enacted`, `gov_action_expired`, `gov_action_dropped`, `committee_authorized`, `committee_resigned`, `treasury_withdrawal_enacted` |
| `SearchKind` | `drep`, `gov_action`, `spo`, `committee_member`, `profile`, `attestation` |

**Repeated parameters.** Every array filter uses `collectionFormat: multi` — repeat the key:
`?status=active&status=inactive`. **Not** comma-separated. Repeated values are OR'd within a
parameter; different parameters are AND'd.

### `/dreps` and `/pages/drep-explorer` (identical parameter set)

| Filter | Type | Notes |
| --- | --- | --- |
| `status` | `DRepStatus[]` | Default excludes `retired` and `reserved` (measured: no filter → 294 = active+inactive+unknown) |
| `anchor_status` | `AnchorStatus[]` | |
| `has_script` | bool | |
| `min_voting_power`, `max_voting_power` | int64 | lovelace |
| `min_delegators` | int | |
| `min_participation_rate`, `min_rationale_rate` | double | 0.0–1.0, **not** percent |
| `registered_before`, `registered_after` | `yyyy-mm-ddThh:MM:ssZ` | |
| `min_age_days` | int | |
| `voted_on`, `not_voted_on` | string | a gov action id |
| `language` | string | e.g. `en-us` |
| `active_in_epoch` | int | |
| `q` | string | name + description, case-insensitive, 2–100 chars |

`order_by`: `id`, `voting_power`, `delegator_count`, `participation_rate`, `rationale_rate`,
`registered_at`, `votes_cast`, `name`.

Measured status totals: `active` 17, `inactive` 187, `unknown` 90, `retired` 523, `reserved` **0**.

### `/gov-actions`

Filters: `type` (`GovActionType[]`), `state` (`GovActionState[]`), `anchor_status[]`,
`proposed_from`, `proposed_to`, `expires_before_epoch`, `expires_after_epoch`,
`proposer_stake_address`, `min_treasury_amount`, `max_treasury_amount` (int64), `q`.
`order_by`: `proposed_at`, `expires_epoch`, `type`, `deposit`, `treasury_amount`, `votes_cast`.

### `/votes`

Filters: `voter_role[]`, `voter_id[]`, `gov_action_id[]`, `verdict[]`, `gov_action_type[]`,
`anchor_status[]`, `from`, `to`, `from_epoch`, `to_epoch`, `q`.
`order_by`: `cast_at`, `voting_power`, `latency`, `voter_id`, `gov_action_id`.

### `/delegations`

Filters: `drep_id[]`, `stake_address[]`, `is_current`, `from`, `to`, `min_lovelace` (int64).
`order_by`: `at`, `lovelace`, `stake_address`.

### `/drep/{id}/delegators`

Filters: `is_current`, `min_lovelace`. `order_by`: `lovelace`, `delegated_at`, `stake_address`.

### `/drep/{id}/power`

Filters: `from_epoch`, `to_epoch`. **No `order_by`, no `offset`** — `limit` + `sort_order` only.

### `/drep/{id}/updates`

Filter: `kind` ∈ `registered | updated | retired`. **No `order_by`.**

### `/spos`

Filters: `min_voting_power` (int64), `min_votes_cast`, `active_in_epoch`.
`order_by`: `voting_power`, `votes_cast`, `pool_id`.

### `/treasury-withdrawals`

Filters: `gov_action_id[]`, `beneficiary[]`, `enacted_from_epoch`, `enacted_to_epoch`, `min_amount`,
`max_amount` (int64). `order_by`: `amount`, `enacted_epoch`.

### `/activity`

Filters: `event_type[]`, `source[]` (**only value: `governance`**), `actor[]`.
**No `order_by`, no `offset`.** Cursor only.

### `/profiles`

Filters: `kind` (`ProfileType[]`), `claimed` (bool), `q`.
`order_by`: `id`, `name`, `description`, `type`, `registered_at`. Default: `registered_at` desc.

### `/attestations`

Filters: `subject`, `issuer` (asset classes), `kind` (`AttestationType[]`), `accepted` (bool),
`date_from`, `date_to`. `order_by`: `id`, `date`, `issued_to`, `issued_by`, `name`.

### `/disputes`

Filters: `target` (attestation asset class), `resolved` (bool). **No `order_by`.**

### `/profiles/{id}/attestations`, `/profiles/by-credential/{cred}`

`limit`, `offset`, and (first route only) `sort_order`. **No `order_by`.**

### `/search`

`q` (**required**, 2–100 chars), `kinds` (`SearchKind[]`), `limit_per_group`.

### `/pages/dashboard`

`top_limit`, `closing_soon_limit`, `epochs`. No filters.

### Routes with no parameters at all

`/committee`, `/metrics/formulas`, `/health`, `/ready`, `/status`.

**Spot-checks (live):** `?event_type=vote_cast` → 200; `?event_type=nonsense` →
`400 invalid_parameter`; `?status=active` → 200 `total: 17`; `?order_by=voting_power&sort_order=desc`
→ 200; `?q=a` → `400 query_too_short`.

**Range validation.** An inverted range is a **400**, not an empty page:
`from > to` → `invalid_time_range`; `from_epoch > to_epoch` → `invalid_epoch_range`
(`Query/Common.hs:148`). "No rows" would read as "nothing happened in that window", which is the
wrong answer to a question that cannot have results.

**`q` safety.** A `%` or `_` the user typed is matched **literally**, escaped before it reaches the
`LIKE` (`Query/Common.hs:126`). Searching for "100%" does not match everything. No client-side
escaping needed.

## 3.4 The error contract

### Read surface (`query-api`)

Every error body is exactly:

```json
{"code":"offset_too_large","message":"The offset is beyond the allowed range"}
```

**Match on `code`.** `message` is display text and may be reworded at any time — a client that
string-matched it breaks on a typo fix.

The 24 codes, their statuses and what the UI should do
(`Envelope.hs:118-206`, `Errors.hs:81-105`):

| `code` | HTTP | `message` | UI action |
| --- | --- | --- | --- |
| `invalid_parameter` | 400 | A query parameter is not valid | **Bug in your client.** Log it. A user cannot fix it. |
| `query_too_short` | 400 | The search query is too short | Gate on `length >= 2` before calling. Show nothing. |
| `query_too_long` | 400 | The search query is too long | `maxLength=100` on the input. |
| `offset_too_large` | 400 | The offset is beyond the allowed range | Cap the pager at offset 10000; offer CSV or a filter. |
| `limit_too_large` | 400 | The limit is beyond the allowed range | **Unreachable** — limit clamps instead. Handle defensively. |
| `invalid_cursor` | 400 | The cursor is not one this endpoint issued | Drop the cursor, reload the feed from the top. |
| `both_cursors_given` | 400 | Give either `before` or `since`, not both | **Bug in your client.** |
| `invalid_drep_id` | 400 | Not a DRep identifier | Inline field error. Also what a malformed `voter_id` returns. |
| `invalid_gov_action_id` | 400 | Not a governance action identifier | Inline field error. Often a missing `%23` — §3.5. |
| `invalid_asset_class` | 400 | Not an asset class | Inline field error on a profile/attestation id. |
| `invalid_time_range` | 400 | The time range is empty or reversed | Validate the date picker before calling. |
| `invalid_epoch_range` | 400 | The epoch range is empty or reversed | Same. |
| `drep_not_found` | 404 | No DRep with that identifier | Empty state. The id was **well formed** — distinct from `invalid_drep_id`. |
| `gov_action_not_found` | 404 | No governance action with that identifier | Empty state. |
| `spo_not_found` | 404 | No stake pool with that identifier | Empty state. |
| `committee_not_found` | 404 | No committee member with that identifier | Empty state. |
| `profile_not_found` | 404 | No profile with that identifier | Empty state — **but may mean "not yet projected"**, §4.6. |
| `attestation_not_found` | 404 | No attestation with that identifier | Empty state. |
| `dispute_not_found` | 404 | No dispute with that identifier | Empty state. |
| `rate_limited` | 429 | Too many requests | Back off. **Not reachable today** — declared ahead of the limiter. |
| `not_ready` | 503 | Service temporarily unavailable | Global "catching up" banner. Retry. |
| `indexer_behind` | 503 | The chain index is too far behind to answer | Global staleness banner with the lag from `/status`. Retry. |
| `db_unavailable` | 503 | Service temporarily unavailable | Retry with backoff — **but see the warning below.** |
| `internal_error` | 500 | Internal server error | Generic failure. Report it. |

**The distinction that matters most:** `invalid_*` (400) means *the id is not an id* — show a field
error. `*_not_found` (404) means *the id is well formed and names nothing* — show an empty state.
Measured, on the same route: `/drep/garbage` → `400 invalid_drep_id`, while a well-formed but
non-existent CIP-129 id → `404 drep_not_found`.

> **`db_unavailable` does not mean the database is down.** It is the catch-all for **any** read
> failure (`QueryAppMonad.hs:79-87`), and the most common cause in practice is the **30-second
> statement timeout** (`Query/Gov.hs:250-270`). Measured: `/drep/{id}` returns
> `503 db_unavailable` at 30.3 s while `/dreps` on the same database answers in 0.69 s.
>
> A blind retry on this code is actively harmful. The source is explicit: *"every abandoned attempt
> left ANOTHER backend grinding, so three aborted requests had three full scans competing for a
> container limited to 0.75 of a CPU."* **Retry at most once, with a long backoff, and never retry
> in parallel.** If a 503 arrives at ~30 s, treat it as a timeout, not an outage.

Four codes are **declared but unreachable today**: `profile_not_found`, `attestation_not_found`,
`dispute_not_found`, `rate_limited`. They are published anyway so a client that already handles them
needs no release when the features land. Handle them now.

### Write surface (`interaction-api`) — a different vocabulary

Same `{code, message}` shape, but the codes come from `TxBuildingException`
(`src/lib/offchain-lib/Palmares/TxBuilding/Exceptions.hs`) and share nothing with the read codes.
`code` is the Haskell constructor name in **PascalCase** — not snake_case. Match on it, not the
message (`Exceptions.hs:208-212`).

| `code` | HTTP | What went wrong | UI action |
| --- | --- | --- | --- |
| `ProfileNotFound` | 404 | The named profile does not exist. | Empty state. |
| `WrongProfileType` | 400 | Wrong profile kind for this action. | Field error. |
| `AttestationNotFound` | 404 | | Empty state. |
| `AttestationAlreadyAccepted` | 400 | Already counter-signed. | Refresh; hide the Accept button. |
| `AttestationOtherMetadataReservedKeys` | 400 | `other_metadata` used `name`, `description` or `image`. | Field error — **validate client-side.** |
| `AttestationPeriodInverted` | 400 | `claimed_period` ends before it begins. | Field error — **validate client-side.** |
| `AttestationKindIsCredentialBinding` | 400 | `credential_claim`/`credential_withdrawal` sent to `/issue-attestation`. | **Bug in your client** — use `/claim-credential`. |
| `SubjectProfileNotFound` | 404 | The subject profile was never claimed. | Field error with the real reason: it could never be counter-signed. |
| `CredentialMalformed` | 400 | Not a CIP-129 identifier. | Field error — §3.5. |
| `ScriptCredentialHasNoUtxo` | 400 | Script credential with no spendable UTxO. Carries the script hash in the message. | Explain the fix: send a UTxO to that script address first. |
| `DisputeNotFound` | 404 | | Empty state. |
| `DisputeAlreadyOpen` | 400 | A dispute is already open against this attestation. | Link to the open one. Off-chain courtesy, not a protocol rule. |
| `DisputeAlreadyResolved` | 400 | Already has a verdict. | Refresh. |
| `DisputeVerdictNotAFinding` | 400 | Admin sent `expired` as a verdict. | Only the clock writes `expired`. |
| `DisputeNotStaleYet` | 400 | Deadline has not passed. | Disable Expire until the deadline; it is in the dispute datum. |
| `DepositAddressNotSpendable` | 400 | `deposit_to` holds no spendable UTxO. | **Just omit `deposit_to`.** §4.4 |
| `DepositAddressIsScript` | 400 | `deposit_to` is a script address — the refund would be lost. | **Just omit `deposit_to`.** §4.4 |
| `OracleNotFound` | 404 | Oracle UTxO missing. | Infrastructure. Block writes. |
| `OracleDatumInvalid` | **500** | Oracle datum unparseable. | Infrastructure. Block writes. |
| `ProtocolPaused` | **503** | `oracle_paused` is true. | Block writes; show a maintenance banner. |
| `DeployedScriptsNotReady` | **503** | Reference scripts do not resolve. | Block writes; gate on `/status`. |
| `InvalidAssetClass` | 400 | | Field error. |
| `NFTNotFound` | 404 | No UTxO with that NFT. | Empty state. |
| `MultipleUtxosFound` | 400 | | Report it. |
| `DatumParseError` | **500** | | Report it. |
| `NoDustFound` | 404 | Admin cleanup only. | n/a |

**Four classifier codes** that are not `TxBuildingException` constructors
(`Exceptions.hs:251-312`). These are the ones a real user hits:

| `code` | HTTP | Meaning | UI action |
| --- | --- | --- | --- |
| `ScriptRefused` | 400 | **A validator refused the transaction.** The message lists the on-chain trace codes, e.g. *"A validator refused this transaction: Md8 D7."* | Show the trace codes. They resolve in `docs/architecture/onchain-flows.md`. This is the most informative write failure you get. |
| `InsufficientFunds` | 400 | "Not enough ADA in your wallet to cover the deposit and transaction cost." | Show the wallet balance and the required deposit. |
| `TxTooExpensive` | 400 | Needs more execution units than the protocol allows. | **Adding ADA does not help.** Do not say "add funds". |
| `TxTooLarge` | 400 | Larger than the protocol allows. | Same — not a funds problem. |
| `ProviderError` | **502** | The chain provider could not be reached or rejected the submission. | Not the user's fault. Retry. |
| `InternalError` | **500** | | Report it. |

`ScriptRefused` exists because the previous code collapsed every balancing failure into
`InsufficientFunds` — *"A user told to add funds for an `Md8` or a `D7` adds funds and is told the
same thing again."* Surface the trace codes; do not swallow them into a generic "transaction
failed".

### Error-contract violations — bodies that are not `{code, message}`

| Case | Actual response | Impact |
| --- | --- | --- |
| `GET /tx-status/nothex` | **`400` with `text/plain` body `Invalid transaction ID: nothex`** | `JSON.parse` throws. Guard every `interaction-api` parse. |
| `GET /tx-status/…` with no credentials | **`401` with an empty body** + `WWW-Authenticate: Basic realm="user-realm"` | Nothing to parse. §3.6 |
| `GET /tx-status/…` with wrong credentials | **`403` with an empty body** | Note: **403, not 401.** §3.6 |
| `attest-sync` `GET /ready` when behind | `503` with a Haskell `show` of the record | `UNVERIFIED:` read from `ChainsyncAPI.hs:63`; could not force it. |

A failing path `Capture` on `query-api` **does** produce the right body — every `parseUrlPiece`
returns the error code as its message and an error formatter reads it back
(`Errors.hs:53-73`). Measured: `/drep/garbage` → `{"code":"invalid_drep_id",…}`. The
`interaction-api` has no such formatter, hence the plain-text 400 above.

## 3.5 Freshness

### Response headers — on **every** response, including error bodies

```
X-Chain-Epoch: 321
X-Chain-Slot: 137140009
X-Chain-Block-Time: 2026-10-24T06:26:49Z
X-Data-Lag-Seconds: 43
X-Data-Source: cardano-db-sync
X-Attest-Slot: 137140009
X-Attest-Lag-Seconds: 0
X-Attest-State: following
```

Added by middleware on the way out, so a handler cannot forget them
(`Query/Gov.hs:610-650`). `X-Chain-Block-Time` is ISO-8601 — `new Date()` parses it directly (the
source notes this was a deliberate fix; Haskell's default `show` renders
`2026-10-20 12:43:24 UTC`, which no browser parses).

The three `X-Attest-*` headers appear **only when a projector exists**. On a governance-only
deployment they are absent — code for that.

> ### Blocker: the three `X-Attest-*` headers are not readable from a browser
>
> A response header is invisible to `fetch()` unless it is in `Access-Control-Expose-Headers`.
> Measured, with `Origin: http://localhost:5173`:
>
> ```
> Access-Control-Expose-Headers: Accept, Accept-Language, Content-Language, Content-Type,
>   Authorization, X-Chain-Epoch, X-Chain-Slot, X-Chain-Block-Time, X-Data-Lag-Seconds, X-Data-Source
> ```
>
> `X-Attest-Slot`, `X-Attest-Lag-Seconds` and `X-Attest-State` are **sent but not exposed**.
> `freshnessExposedHeaders` lists five names (`CORS.hs:51-57`); the attest trio is built separately
> (`Query/Gov.hs:644-646`) and was never added. `response.headers.get('X-Attest-State')` returns
> `null` in a browser while curl sees `following`.
>
> **Until this is fixed, read the attestation state from `GET /status`** (`.attestation.state`),
> which is in the body and therefore readable. §5.9.

### `/ready` semantics

`GET /ready` is 200 when the service can answer honestly, 503 otherwise. Six ways it goes red
(`Query/Gov.hs:357-385`):

| Condition | Code |
| --- | --- |
| No database | `db_unavailable` |
| `lag_seconds > ready_max_lag_seconds` (300) | `indexer_behind` |
| `drep_distr_epoch < epoch - 1` | `indexer_behind` |
| Wrong network | `not_ready` |
| `governance.lag_seconds + attestation.lag_seconds > 300` | `indexer_behind` |
| `attestation.state == "error"`, or the projector stopped reporting for > 300 s | `indexer_behind` |

Two asymmetries to know:

- **An absent projector passes.** `attestation: null` is *no evidence*, not failure — a
  governance-only deployment must not be taken out of rotation for doing nothing wrong.
- **`state: "syncing"` is deliberately not red.** A projector mid-pass is a healthy service
  answering honest *partial* pages. `/status.attestation.state` and `X-Attest-State` are how a
  client knows to say so. **This is on you:** during a backfill the API returns 200s with
  incomplete attestation data and nothing in the HTTP status says so.

### What the UI must display

| Condition | What the UI must show |
| --- | --- |
| `lag_seconds <= 120` (`amber_lag_seconds`) | Green. Nothing. |
| `120 < lag_seconds <= 300` | **Amber: "catching up — data is N s behind."** Keep rendering. |
| `lag_seconds > 300` / `/ready` 503 | **Red: "the chain index is behind; figures may be stale."** Keep the last data, badge it. |
| `attestation.state == "syncing"` | **"Attestation records are still loading — this list may be incomplete."** On every attestation, profile and dispute screen. |
| `attestation.state == "error"` | **"Attestation records are not updating."** `last_error` says why. |
| `attestation == null` | Hide the attestation screens entirely — no projector. |
| `drep_distr_epoch < epoch` | Label voting-power figures with `power_epoch`, not the current epoch. |
| `metrics_as_of_epoch` | Stamp every metric with it. `/status` publishes it so you do not have to infer it. |

Both thresholds come from the body (`amber_lag_seconds`, `ready_max_lag_seconds`) — **read them,
do not hardcode 120/300.** `ready_max_lag_seconds` is overridable by
`PALMARES_READY_MAX_LAG_SECONDS` server-side.

### After a write

A confirmed transaction is **not** visible on the read API yet. The sequence is:
`/submit-tx` → `/tx-status` confirmed → attest-sync projects it → the read route shows it.
Poll the read route, and show "waiting for indexing" while `X-Attest-State`/`.attestation.state` is
`syncing`. The project's own smoke script polls for up to **600 s** for a projection to appear
(`scripts/smoke_attest_flow.sh`, `ATTEST_SMOKE_TIMEOUT`). Budget accordingly.

## 3.6 Identifiers

Six formats the UI will handle.

| # | Format | Looks like | Length |
| --- | --- | --- | --- |
| 1 | **DRep, CIP-129** | `drep1ygzlzlzj8r9c3zutlgh9ugqx958cwr6q704xtt9j5uf4lzsz9rwhm` | **58** chars (29 bytes: 1 header + 28 hash) |
| 2 | **DRep, CIP-105** | `drep1qhchc53cewyghzl69e0zqp3dp7rs7s8nafj6ev48zd0c54m4nqe` | **56** chars (28 bytes, no header) |
| 3 | **Raw credential hex** | `05f17c5238cb888b8bfa2e5e20062d0f870f40f3ea65acb2a7135f8a` | **56** hex chars |
| 4 | **Gov action, canonical** | `04f23439…8593f44#0` | 64 hex + `#` + index |
| 5 | **Gov action, CIP-129 bech32** | `gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v` | 33 bytes |
| 6 | **Asset class** (profile/attestation) | `648c6a73….000643b0405c…` | 56 hex `.` asset-name hex |

Also: `cc_cold1…` / `cc_hot1…` (CIP-129 committee), `pool1…` (CIP-5), `stake_test1…` /
`stake1…` (stake addresses, filter values only).

**The header byte is `(keyType << 4) | credentialType`** (`Ids.hs:14-21`):

| Identifier | HRP | key byte | script byte |
| --- | --- | --- | --- |
| CC hot | `cc_hot` | `0x02` | `0x03` |
| CC cold | `cc_cold` | `0x12` | `0x13` |
| DRep | `drep` | `0x22` | `0x23` |
| DRep CIP-105 | `drep` | *(none)* | *(none)* |
| Gov action | `gov_action` | *(none)* | *(none)* |

### Which routes accept which — all measured

| Route | CIP-129 | CIP-105 | Raw hex | `pool1…` / `cc_*1…` | Parser |
| --- | --- | --- | --- | --- | --- |
| `/drep/{drep-id}` and its 3 sub-resources | ✅ | ✅ | ✅ | **❌ 400** | `parseDrepIdAny` |
| `/delegations?drep_id=` | ✅ | ✅ | ✅ | **❌ 400** | `parseDrepIdAny` |
| `/votes?voter_id=` | ✅ | ✅ | ✅ | **✅** | `anyVoterIdHex` |
| **`/profiles/by-credential/{credential}`** | ✅ `drep1y…` only | **❌ 400** | **❌ 400** | **❌ 400** | `canonicalDrepCredential` |

Measured, and the distinction is easy to get wrong: `/votes?voter_id=<pool1…>` is **200**, while
`/delegations?drep_id=<pool1…>` of the same 28 bytes is **`400 invalid_drep_id`**. Only `/votes`
takes the one-parameter-for-all-roles form; the DRep routes take DRep ids only.

**A hash-collision caveat on `/votes?voter_id=`.** `anyVoterIdHex` keeps the 28-byte hash and
discards the HRP, so a `pool1…` built over a DRep's credential hash returns **that DRep's votes**
(measured: `total: 11`, identical to the CIP-129 query). The HRP only tells the parser how many
leading bytes to drop. Pass ids through from API responses rather than re-encoding them, and never
treat a 200 here as proof the id named the role you meant.

Measured refusals:

```
GET /drep/garbage                          400 {"code":"invalid_drep_id",…}
GET /drep/<drep HRP + 0x12 header>         400 {"code":"invalid_drep_id",…}
GET /drep/<well-formed CIP-129, absent>    404 {"code":"drep_not_found",…}
GET /profiles/by-credential/<CIP-105>      400 {"code":"invalid_drep_id",…}
GET /profiles/by-credential/<raw hex>      400 {"code":"invalid_drep_id",…}
GET /gov-action/garbage                    400 {"code":"invalid_gov_action_id",…}
GET /profiles/garbage                      400 {"code":"invalid_parameter",…}
GET /attestations/garbage                  400 {"code":"invalid_parameter",…}
GET /profiles/<valid policy>.deadbeef      404 {"code":"profile_not_found",…}
GET /votes?voter_id=nonsense               400 {"code":"invalid_drep_id",…}
```

**An HRP that disagrees with its header byte is refused**, not coerced. `drep1…` carrying `0x12`
(the CC-cold header) is *"not a DRep id with a typo, it is two different claims about the same bytes
and there is no reason to prefer either"* (`Ids.hs:143-157`).

### Where a conversion is needed

1. **CIP-105 → CIP-129, for the verification widget.** `/profiles/by-credential/` takes CIP-129
   only, and a user pasting from a wallet or GovTool may have either. **You cannot convert without
   knowing the script flag**, which CIP-105 does not carry. Resolve it first: call
   `GET /drep/{cip105-or-hex}`, read `has_script`, then re-encode with `0x22` (key) or `0x23`
   (script). *(That route is 503 today — §5.1 — so use `GET /dreps?q=` and match on `hex` instead.)*

2. **Gov action id → URL.** The canonical `<tx_hash>#<index>` contains a `#`, which a URL treats as
   a fragment delimiter. Measured:

   | Request | Result |
   | --- | --- |
   | `/gov-action/gov_action1qner…dc2a6v` | **200** |
   | `/gov-action/04f23439…8593f44%230` | **200** |
   | `/gov-action/04f23439…8593f44#0` | **`400 invalid_gov_action_id`** |

   The `#` form **must** be sent percent-encoded as `%23`. `encodeURIComponent` does produce `%23`,
   so a correctly encoded path works — but a bare `#` interpolated into a template string, a React
   Router path or an `<a href>` is stripped by the browser before the request leaves, and the server
   sees only the tx hash. That is what the 400 above is: not a rejected id, a truncated one.
   **Use the `bech32` field for every link.** Every row that carries an action id carries both
   forms, and `bech32` has no character that needs encoding.

3. **Activity `actor_id` → a linkable id.** The feed publishes a **bare 28-byte hex hash**
   (`"76810b3e971a94939711c8a8c1e0090a8e497b5de92bdfa0e7aa292b"`). To render a DRep link you must
   bech32-encode it with HRP `drep` and header `0x22`/`0x23` — and the feed does not say which. For
   `/drep/{id}` you can pass the raw hex directly (accepted), which sidesteps the problem for
   navigation but not for display.

4. **Committee hot vs cold.** Committee votes are keyed by the **cold** credential (the source cites
   this as `D-24`). `/votes?voter_id=<cc_hot1…>` is **accepted** and resolves to the hot hash, which
   matches **no vote row** — a silent empty result, not an error. Deliberate: *"a hot key is not a
   stable identity, and silently resolving it to a cold one would hide a hot-key rotation."* Always
   query with `cold_bech32` from `/committee`.

> **A collision trap worth naming.** You cannot tell CIP-129 from CIP-105 by the `drep1y` prefix.
> The header byte's top five bits are what bech32's first character encodes, and they are `00100`
> for **any** first byte in `0x20..0x27` — so a CIP-105 id whose hash happens to start in that range
> also renders as `drep1y`. It is wrong about 1 id in 32. **Discriminate by length:** CIP-129 is 58
> characters, CIP-105 is 56, raw hex is 56 hex digits.
> (`scripts/smoke_attest_flow.sh`, step-1 comment.)

## 3.7 CORS and auth — what the browser actually faces

### CORS

**Fail-closed allowlist.** Only an `Origin` present in `CORS_ALLOWED_ORIGINS` gets CORS headers;
every other origin gets **none**, so the browser blocks the response (`CORS.hs:60-78`). An unset or
empty variable means **no cross-origin request works at all**. There is no wildcard.

Measured — `http://localhost:5173` (Vite's default) **is** allowlisted on the running services:

```
OPTIONS /build-tx   Origin: http://localhost:5173
→ HTTP/1.1 200 OK
  Access-Control-Allow-Origin: http://localhost:5173
  Vary: Origin
  Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS, DELETE, HEAD
  Access-Control-Allow-Headers: Accept, Accept-Language, Content-Language, Content-Type, Authorization
  Access-Control-Max-Age: 600
```

- Preflight cached 600 s.
- `Authorization` **is** in `Allow-Headers`, so Basic auth over CORS works.
- `allowCredentials` is hard-coded **`false`** (`CORS.hs:41`) — cookies and
  `fetch(..., {credentials: 'include'})` will **not** work. Send `Authorization` explicitly.
- Expose-headers is missing the attest trio — §3.5.
- `Vary: Origin` is set, so shared caches behave.

Add every front-end origin (dev, preview, prod) to `CORS_ALLOWED_ORIGINS` before the first browser
request, or you will debug a silent block.

### Auth — read surface

**None.** No route needs a credential; no 401 or 403 exists in the read vocabulary.

### Auth — write surface, and why it is a problem in a browser

Every build/submit/status route sits behind **HTTP Basic** (`RestAPI.hs:281-303`). Measured against
`GET /tx-status/{txId}`:

| Request | Status | Body | Notable |
| --- | --- | --- | --- |
| no credentials | **401** | *(empty)* | **`WWW-Authenticate: Basic realm="user-realm"`** |
| `-u bad:bad` | **403** | *(empty)* | **403, not 401** |
| `-u smoke:smoke-devonly` | 200 | `{"tx_id":"0000…0000","confirmed":false}` | |

Three consequences for a browser client:

1. **`WWW-Authenticate` on the 401 makes the browser show its native Basic-auth dialog.** A
   `fetch()` that 401s on a document-initiated request can pop an OS credential prompt you cannot
   style, cannot intercept and cannot dismiss programmatically. Never let an unauthenticated write
   request reach this service from a page context.

2. **Wrong credentials are a 403, not a 401.** `if (res.status === 401) reauthenticate()` will not
   fire. Treat **401 and 403 together** as "auth failed".

3. **Both bodies are empty.** `await res.json()` throws. Check `res.ok` before parsing, always.

**The architectural problem.** Basic auth means a shared username and password. In a browser client
that password is either (a) in your bundle — readable by anyone, and it authorises transaction
building against preprod — or (b) not in the browser at all, which means **every write must go
through a server-side proxy that holds it**. (b) is the only correct answer, and it is
infrastructure that does not exist yet. §5.10.

The credentials are per-deployment (`smoke` / `smoke-devonly` in dev); the swagger document itself
is public and unauthenticated on both services.

---

# 4. The wallet signing contract

**Nothing in this backend signs anything.** Every write route returns an **unsigned** transaction
and nothing else; there is no route that signs, and the admin CLI has no `claim-profile`,
`open-dispute` or `resolve-dispute` command. This is the most error-prone part of the integration.

## 4.1 The request shape — and the casing trap

Every write body carries a `user_addresses` object. **The body is snake_case; the object inside it
is camelCase.** Verified in the live swagger document:

```
UserAddresses   required: ["usedAddresses", "changeAddress"]
  usedAddresses       array[GYAddress]
  changeAddress       GYAddress
  reservedCollateral  string (cbor hex)      — optional
```

```jsonc
// POST /claim-profile — the mixed casing is real
{
  "kind": "person_d_rep",                 // snake_case
  "name": "Ada",                          // snake_case
  "description": "…",                     // snake_case
  "image_uri": "ipfs://…",                // snake_case
  "user_addresses": {                     // snake_case key …
    "usedAddresses": ["00e1cbb8…9f616"],  // … camelCase inside
    "changeAddress": "00e1cbb8…9f616"     // … camelCase inside
  }
}
```

This is **a known, unfixed defect**, not a misreading. From the project's own smoke script:

> `addrs() { jq -nc --arg a "$ATTEST_SMOKE_ADDR" '{usedAddresses:[$a],changeAddress:$a}'; }`
>
> *"The two wallet addresses every request body carries. CAMELCASE, deliberately: `UserAddresses`
> and `Interaction` are derived with aeson's DEFAULT options, so their wire keys are camelCase while
> every `*Request` type around them is snake_case. That inconsistency is a known, unfixed defect."*
> — `scripts/smoke_attest_flow.sh:197-202`

Same for `reservedCollateral`. **Do not run your request bodies through a global snake_case
serialiser** — `used_addresses` / `change_address` will be rejected as missing required fields.

## 4.2 The address format — and what the swagger gets wrong

**The address fields take raw CBOR hex, not bech32.** The live `GYAddress` schema:

```json
{"type":"string",
 "description":"Bech32-encoded Cardano address (addr_test1... on testnet, addr1... on mainnet)",
 "format":"cbor hex",
 "minLength":114,"maxLength":114,
 "example":"00e1cbb80db89e292269aeb93ec15eb963dda5176b66949fe1c2a6a38d1b930e9f7add78a174a21000e989ff551366dcd127028cb2aa39f616"}
```

**The `description` is wrong and the rest of the schema is right.** `format: cbor hex`, the
114-character fixed length, and the example (which is raw hex, not `addr_test1…`) all describe the
real contract. `GYAddress`'s `FromJSON` goes through `FromHttpApiData`, which is
`deserialiseFromRawBytesHex` — **`addr_test1…` is refused.**

The repo states this explicitly:

> *"`ATTEST_SMOKE_ADDR` is the RAW HEX form, not bech32. `GYAddress`'s `FromJSON` goes through
> `FromHttpApiData`, which is `deserialiseFromRawBytesHex` — `addr_test1…` is REFUSED. The generated
> document's own `GYAddress` description says bech32 and is wrong about it; its `format: cbor hex`,
> its 114-character length and its example are right."*
> — `scripts/smoke_attest_flow.sh:52-57`

`UNVERIFIED:` I could not measure the bech32 refusal — every write route is a `POST`, and posting
builds a real preprod transaction. The claim rests on the schema's own `format`/`minLength`/example
and the repo's measured note. **Verify it with one deliberate 400 before building the form.**

**Getting raw hex from Mesh.** CIP-30's `getUsedAddresses()` / `getChangeAddress()` already return
**hex-encoded CBOR** — the raw form this API wants. Mesh's `BrowserWallet` helpers often convert to
bech32 for you, which is exactly the conversion to avoid. Reach for the raw CIP-30 calls, or convert
back with Mesh's serialisers, and assert `length === 114` before sending.

`usedAddresses` should be **all** of the wallet's UTxO-bearing addresses — it is the input set the
balancer draws from. A short list is how you get a spurious `InsufficientFunds`.

## 4.3 What comes back from a build route

A JSON **string** whose content is the unsigned transaction's CBOR hex:

```
"84a70082825820975e4c7f…f5f6"
```

Not an object. Not `{tx: …}`. `await res.json()` gives you a `string`.

The project's smoke script discriminates success from failure on exactly this
(`smoke_attest_flow.sh:176-178`): the route returns a JSON **string** on success and a JSON
**object** (or plain text) on refusal, so `typeof body === 'string'` is a reliable success test
without a second request for the status code. `jq -re 'strings'` is the shell form.

## 4.4 Fields to omit rather than fill

| Field | Why to omit |
| --- | --- |
| `recipient` | Defaults to the change address. Receives any unlocked funds. |
| `deposit_to` (`/open-dispute`) | **Omit it.** It defaults to the address holding the opener's user token — the one address the protocol is satisfied by for free, because spending that UTxO is how the opener authorises. Naming anything else risks `DepositAddressNotSpendable` (an address you hold no spendable UTxO at) or `DepositAddressIsScript` (the refund is a datum-less output, which a script cannot spend — it would be **lost**, including at this protocol's own addresses). If you do name one, it **must** be in `usedAddresses`. |
| `reservedCollateral` | Let the balancer pick collateral. |
| `claimed_period` (`/issue-attestation`) | Optional, but **both bounds or neither**, and `from <= to` or you get `AttestationPeriodInverted`. Self-reported: no on-chain fact establishes it, so never render it as verified. |

`other_metadata` must not use the keys `name`, `description` or `image` — those are CIP-68 standard
fields. Validate client-side; the server answers
`AttestationOtherMetadataReservedKeys`.

## 4.5 What the wallet must produce — a witness **set**

```
AddWitAndSubmitParams   required: ["tx_unsigned", "tx_wit"]
  tx_unsigned   GYTx         — the hex you got from the build route, UNCHANGED
  tx_wit        GYTxWitness  — a CIP-30 witness SET, hex
```

Both keys are **snake_case** here (this body has no `UserAddresses` in it).

**`tx_wit` must be a CIP-30 witness *set*** — exactly what `api.signTx()` returns. From the repo:

> *"reads the unsigned transaction's CBOR hex on STDIN and writes a CIP-30 shaped witness SET CBOR
> hex on STDOUT (the thing a wallet's `api.signTx` returns, e.g. `a100818258206400…01`). That is
> what `/submit-tx`'s `tx_wit` parses — **NOT a cardano-cli TextEnvelope, and not a bare key
> witness**."*
> — `scripts/smoke_attest_flow.sh:22-26`

The three things that are **not** accepted:

| Wrong thing | What it is |
| --- | --- |
| A cardano-cli `TextEnvelope` | `{"type":"TxWitness…","cborHex":"…"}` — a JSON wrapper. |
| A bare key witness | The inner `[vkey, signature]` pair without the `a10081…` map/array wrapper. |
| The whole signed transaction | `signTx(tx, false)` on some wallets returns a full tx. You want the witness set. |

`a100818258…` decodes as `{0: [[vkey, sig]]}` — the witness-set map, key 0 (`vkey_witnesses`),
holding a one-element array. If what you have does not start `a100` (or `a1008…`), you have the
wrong object.

**With Mesh / CIP-30:** `const witnessSet = await wallet.signTx(unsignedHex, true)`. The second
argument is `partialSign`. Pass **`true`** for `/claim-credential`, `/withdraw-credential` and
`/resolve-dispute` — those transactions need a signature this wallet cannot supply, and a wallet
asked to sign fully will refuse. For the single-signature flows either value works; `true` is the
safe default.

The backend assembles the signed transaction itself — `makeSignedTransaction awasTxWit txBody`
(`RestAPI.hs:103-107`). You never rebuild a transaction client-side.

## 4.6 Polling for confirmation

```json
// GET /tx-status/0000000000000000000000000000000000000000000000000000000000000000
{"tx_id":"0000000000000000000000000000000000000000000000000000000000000000","confirmed":false}
```

- `txId` in the path is **64 hex characters**. Non-hex → `400` with a **plain-text** body
  (`Invalid transaction ID: nothex`) — §3.4.
- An unknown tx id is **`confirmed: false`**, not a 404. You cannot distinguish "not yet on chain"
  from "never submitted".
- The route is **behind Basic auth** like the write routes.
- `confirmed: true` means on chain, **not** visible on the read API. §3.5.

## 4.7 The exact sequence a React hook implements

```ts
// Every field name below is verified against the live swagger document.
const WRITE = 'http://127.0.0.1:8082';
const READ  = 'http://127.0.0.1:8083';

// Basic auth belongs on a server-side proxy, not in the browser — see §3.7 / §5.10.
const authHeader = { Authorization: `Basic ${btoa(`${user}:${pass}`)}` };

async function writeFlow(route: string, payload: object, wallet: BrowserWallet) {
  // ── 0. GATE ───────────────────────────────────────────────────────────────
  const st = await (await fetch(`${WRITE}/status`)).json();
  // {provider:"node-kupo", network:"preprod", deployed_scripts:true,
  //  oracle_paused:false, version:"1.0.0"}
  if (!st.deployed_scripts)      throw new Error('Reference scripts not ready');
  if (st.oracle_paused !== false) throw new Error('Protocol paused or oracle unreadable');

  // ── 1. ADDRESSES — raw CBOR hex, 114 chars, camelCase keys ───────────────
  const usedAddresses = await wallet.getUsedAddresses();   // raw hex, NOT bech32
  const changeAddress = await wallet.getChangeAddress();   // raw hex, NOT bech32
  console.assert(changeAddress.length === 114, 'address must be raw CBOR hex');

  // ── 2. BUILD → a JSON *string* of unsigned tx CBOR hex ───────────────────
  const buildRes = await fetch(`${WRITE}${route}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeader },
    body: JSON.stringify({
      ...payload,                      // snake_case: image_uri, subject_profile_id, …
      user_addresses: {                // snake_case key
        usedAddresses,                 // camelCase — deliberate, see §4.1
        changeAddress,                 // camelCase — deliberate, see §4.1
      },
    }),
  });
  if (!buildRes.ok) {
    // 401 and 403 have EMPTY bodies; a bad capture is text/plain. Guard the parse.
    const txt = await buildRes.text();
    let err: { code?: string; message?: string } = {};
    try { err = JSON.parse(txt); } catch { /* empty or plain text */ }
    throw new WriteError(buildRes.status, err.code ?? 'Unknown', err.message ?? txt);
    // err.code is PascalCase here: ScriptRefused, InsufficientFunds, DepositAddressIsScript…
  }
  const unsignedHex: string = await buildRes.json();   // a STRING, not an object

  // ── 3. SIGN → a CIP-30 witness SET (starts a100…), not a TextEnvelope ────
  const txWit: string = await wallet.signTx(unsignedHex, /* partialSign */ true);

  // ── 4. SUBMIT → a JSON *string* tx id. Both keys snake_case. ─────────────
  const subRes = await fetch(`${WRITE}/submit-tx`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeader },
    body: JSON.stringify({
      tx_unsigned: unsignedHex,   // UNCHANGED from step 2
      tx_wit:      txWit,         // the witness SET from step 3
    }),
  });
  if (!subRes.ok) throw await toWriteError(subRes);
  const txId: string = await subRes.json();   // a STRING

  // ── 5. POLL CONFIRMATION ─────────────────────────────────────────────────
  for (let i = 0; i < 120; i++) {              // ~10 min at 5 s
    await sleep(5000);
    const s = await fetch(`${WRITE}/tx-status/${txId}`, { headers: authHeader });
    if (s.ok && (await s.json()).confirmed) break;   // {tx_id, confirmed}
  }

  // ── 6. POLL THE PROJECTION — confirmed ≠ readable ────────────────────────
  // Watch /status.attestation.state; `syncing` means pages are honest but partial.
  // The project's own smoke script allows 600 s here.
  for (let i = 0; i < 120; i++) {
    await sleep(5000);
    const s = await (await fetch(`${READ}/status`)).json();
    if (s.attestation?.state === 'following' && (await recordIsVisible())) break;
  }
  return txId;
}
```

**Nine things this sequence gets right that a naive one gets wrong:**

| # | Trap |
| --- | --- |
| 1 | Gate on `deployed_scripts` **and** `oracle_paused !== false` (`null` ≠ `false`). |
| 2 | Addresses are **raw CBOR hex, 114 chars** — not bech32. |
| 3 | `user_addresses` is snake_case; `usedAddresses`/`changeAddress` inside it are camelCase. |
| 4 | The build route returns a **JSON string**, not an object. |
| 5 | `signTx` must yield a **witness set** (`a100…`), with `partialSign: true` for two-party flows. |
| 6 | `/submit-tx` wants `tx_unsigned` **unchanged** plus `tx_wit`, both snake_case. |
| 7 | `/submit-tx` returns a **JSON string** tx id. |
| 8 | Error bodies may be **empty** (401/403) or **plain text** (bad capture) — never bare-`.json()`. |
| 9 | `confirmed: true` is **not** "visible on the read API". Poll the projection too. |

---

# 5. What the frontend cannot do yet

Ordered by how much it blocks.

## 5.1 BLOCKER — `/drep/{drep-id}` always times out

| | |
| --- | --- |
| **Screen needs** | DRep detail: identity, every metric, power series, delegator movement, top delegators, certificate history, CIP-119 metadata — in one call, as designed. |
| **What exists** | The route, documented as "One DRep's whole public record in a single request". |
| **What is missing** | It works. Measured **5/5 times `503 db_unavailable` at ~30.3 s**, across all three id forms, both under load and serially with nothing else running. `/pages/drep/{id}` is the same handler and fails identically. 30 s is the `statement_timeout` (`Query/Gov.hs:250-270`). |
| **Workaround today** | 4 calls: a `/dreps` row + `/drep/{id}/power` (6.6 s) + `/drep/{id}/updates` (0.4 s) + `/drep/{id}/delegators` (2.3 s). All three sub-resources are healthy. **Loses the CIP-119 metadata block and the delegator-movement series.** |
| **Backend change** | Query-level. The composite assembles several aggregates in one transaction and at least one has no usable index. Likely a missing index or a CTE that needs splitting; the sub-resources proving fast says the data is reachable. **Medium** — a day of `EXPLAIN`, not a redesign. A cheaper interim fix: have the handler drop the slowest block and return the rest. |

> **Query work is in flight as of this writing.** The working tree holds uncommitted rewrites to
> `Query/Gov.hs` (the epoch-power query, now a CTE plus a `palmares.drep_delegator_counts(…)`
> set-returning function) and 83 new lines in `sql/020_views.sql`. **None of it is in the running
> service** — every timing in this document is against the deployed binary. **Re-measure before you
> build the 4-call workaround**; it may already be unnecessary:
> `curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://127.0.0.1:8083/drep/<a-cip129-id>`

## 5.2 ~~BLOCKER~~ CLOSED — no way to find the connected wallet's own profile

> **Closed 2026-10-24: `GET /profiles/by-user-token/{asset-class}`.** The wallet holds the CIP-68
> **user** token and the registry's ids are the **reference** form; the route does the label swap
> and re-parses through Atlas's own codec, so it cannot produce an id the `{profile-id}` capture
> would refuse. The policy id to filter the wallet's assets by was already at
> `/status.attestation.policy_id`.

| | |
| --- | --- |
| **Screen needs** | After wallet connect: "this is your profile" / "you have no profile yet". Required by *every* write flow — `/update-profile`, `/issue-attestation`, `/accept-attestation` and `/open-dispute` all need a `profile_id` the user must first discover. |
| **What exists** | `/profiles` filters on `kind`, `claimed`, `q`. `/profiles/{asset-class}` resolves a known id. `/profiles/by-credential/{cred}` resolves a **credential**, not a wallet. |
| **What is missing** | Any address-keyed lookup. Verified: **no route on either service accepts a wallet address, stake address, or owner as a lookup key** (grepped `RestAPI.hs` for `owner`, `address`, `holder`, `wallet`, `by-address` — none). A profile is identified by the asset class of its user NFT, and the only way to learn that from a wallet is to enumerate the wallet's assets and filter by the protocol policy id (available at `/status.attestation.policy_id`). |
| **Workaround** | Client-side: `wallet.getAssets()`, filter on `policy_id` from `/status`, reconstruct `policy.assetName`, then `GET /profiles/{that}`. Workable but it puts protocol knowledge in the browser and breaks for a profile whose token has moved. |
| **Backend change** | One route: `GET /profiles?owner_address=<addr>` or `GET /profiles/by-owner/{address}`. Needs the projection to carry the holding address — check whether it already does. **Small-to-medium.** |

## 5.3 ~~BLOCKER~~ CLOSED for the dispute flow — the deposit amount is not published

> **Closed 2026-10-24, by this section's own prescription:** the oracle's parameters went onto
> **interaction-api**'s `/status`, where the oracle UTxO is already read. `oracle` carries the
> deposit, the dispute timeout, the minimum UTxO, both fees and the admin and arbiter credentials.
> query-api cannot publish them — it has no Cardano provider by a documented boot contract, and
> its db-sync is indexed without UTxOs, so the oracle UTxO is not in that database at all.

| | |
| --- | --- |
| **Screen needs** | "Opening a dispute locks **N ADA**, returned to you on every outcome. Continue?" You cannot ask for a signature on an unnamed cost. |
| **What exists** | `/open-dispute`'s description says it locks "the deposit the oracle currently requires". `interaction-api` `/status` publishes `provider`, `network`, `deployed_scripts`, `oracle_paused` — and no amount. |
| **What is missing** | Any route publishing the oracle's current fee/deposit configuration. Verified: nothing in `query-api/RestAPI.hs` or `interaction-api/ServiceStatus.hs` exposes it. |
| **Workaround** | None honest. You can build the transaction and read the locked value out of the returned CBOR before asking the user to sign — which means decoding a transaction in the browser to discover a price. |
| **Backend change** | Add the oracle's fee fields to `interaction-api` `/status`; the oracle UTxO is already read there for `oracle_paused`. **Small.** |

## 5.4 ~~A committee credential can be claimed but not verified~~ CLOSED

> **Closed 2026-10-24.** `/profiles/by-credential/` canonicalises all three roles, key and script;
> a malformed credential answers the new `invalid_credential` instead of `invalid_drep_id`. The
> same DRep-only parser also fed `credential_is_script`, which published `null` for every committee
> credential — the field a verification UI is promised it never has to guess.

| | |
| --- | --- |
| **Screen needs** | The verification widget, for a constitutional-committee member: "which profile claims `cc_cold1…`?" |
| **What exists** | The write side accepts it. `ClaimCredentialRequest.credential` is documented as *"CIP-129 identifier: `drep1...`, `cc_cold1...`, `cc_hot1...`"*, and `parseCredentialRoleCip129` decodes all three roles. A profile **can** bind itself to a committee credential. |
| **What is missing** | The read side cannot look one up. Measured: `/profiles/by-credential/<cc_cold1…>` and `<cc_hot1…>` both return **`400 invalid_drep_id`**. The handler uses `canonicalDrepCredential` (`RestAPI.hs:1571`), which is DRep-only, rather than the role-aware `parseCredentialRoleCip129` that exists one module away. The error message — *"Not a DRep identifier"* — is literally true and completely misleading: the caller sent a perfectly good committee identifier. |
| **Workaround** | `GET /profiles?claimed=true` and filter on `credential` client-side. Fine at 1 profile, not at 10,000. |
| **Backend change** | Swap `canonicalDrepCredential` for the role-aware parser in that one handler, and widen the error code (or keep `invalid_drep_id` and fix the message). **Small** — the parser and its tests already exist. Worth confirming the projection stores committee claims in the same column first. |

## 5.5 ~~No single-dispute route~~ CLOSED

> **Closed 2026-10-24: `GET /disputes/{dispute-id}`.** It also makes `dispute_not_found` reachable,
> which until now was a published error code with no site anywhere in the service.

| | |
| --- | --- |
| **Screen needs** | A linkable, refreshable dispute detail page — the target of a notification or a shared URL. |
| **What exists** | `/disputes?target=<id>` (list) and `/attestations/{id}` (inlines up to 50). |
| **What is missing** | `GET /disputes/{dispute-id}`. Verified: no `Capture "dispute…"` in `RestAPI.hs`. The `dispute_not_found` code is declared and unreachable. |
| **Workaround** | Fetch `/attestations/{attestation-id}` and select the dispute client-side — so a dispute URL must carry the attestation id too. |
| **Backend change** | One route; `dispute_not_found` already exists. **Small.** |

## 5.6 ~~`/gov-actions` is too slow to build on~~ CLOSED

> **Closed 2026-10-24: ~2.45 s → ~0.09 s.** The cost was a correlated `votes_cast` subselect over
> 3.2 M rows, of which 2.05 s was five epoch-187 stress actions with ~648,750 votes each. It now
> reads a 931-row pre-aggregation refreshed with the other matviews. Verified against the whole
> population, not a sample: 131 actions, 0 disagreements.

| | |
| --- | --- |
| **Screen needs** | A governance action list that loads in under a second. |
| **What exists** | The route, correct and complete. |
| **What is missing** | Speed. Measured serially with nothing else running: **18.9 s, 23.4 s, 13.8 s, 21.8 s, 24.6 s**. Against a 30 s statement timeout that is no headroom — it tipped into `503 db_unavailable` repeatedly under concurrent probing, including on the CSV variant. `?state=proposed&limit=1` was **6.8 s**, so narrowing helps a lot. |
| **Workaround** | Always send a narrowing filter; never render this route on a cold cache in a user-facing path; use `/pages/dashboard`'s `closing_soon` for the common "what's open" view (it is fast and uses the same query). |
| **Backend change** | Indexing, same family as §5.1. **Medium.** |

## 5.7 Attestation, dispute and profile screens have no data to build against

| | |
| --- | --- |
| **Screen needs** | Attestation list/detail, dispute list, profile track record. |
| **What exists** | All seven routes, returning correct empty envelopes. |
| **What is missing** | Data. Measured: `/attestations` `total: 0`, `/disputes` `total: 0`, `/profiles` `total: 1` (a smoke-test artefact created today). `/attestations/{id}` and the `DisputeRow` shape are therefore **`UNVERIFIED:`** — I never saw a populated row. |
| **Workaround** | Build from the swagger definitions and `scripts/smoke_attest_flow.sh`, which creates two profiles, one accepted attestation and one resolved dispute and leaves them behind on purpose. **Run it before coding these screens.** |
| **Backend change** | None — run the seed script. **Trivial, but do it first:** a shape you have not seen is a shape you will get wrong. |

## 5.8 No two-party signing flow for `/claim-credential`

| | |
| --- | --- |
| **Screen needs** | Bind a profile to a governance credential when the profile owner and the credential holder are **different** wallets. |
| **What exists** | `/claim-credential` returns one unsigned transaction that must be authorised by **both** the profile's user token and the credential. `partialSign: true` lets each wallet add its witness. |
| **What is missing** | Any way to get one transaction in front of two wallets. Nothing stores a partially-signed transaction, and `/submit-tx` takes exactly one `tx_wit` — there is no multi-witness or witness-accumulation endpoint. |
| **Workaround** | Out-of-band: one party builds, signs, and hands the hex plus their witness to the other through a channel the app does not provide. Fine when both keys are in one wallet; otherwise manual. |
| **Backend change** | Either `tx_wit` accepts an array of witness sets, or a small "pending transaction" store with a shareable link. **Medium.** Note the `ScriptCredentialHasNoUtxo` case is a separate, documented limitation: a Plutus script that only votes holds no UTxO at its own address, so there is nothing to spend and the claim is refused. |

## 5.9 `X-Attest-*` headers are invisible to the browser

| | |
| --- | --- |
| **Screen needs** | A per-response "attestation data may be incomplete" badge, read off the page you are already loading. |
| **What exists** | All three headers are sent on every response. Measured: `X-Attest-Slot`, `X-Attest-Lag-Seconds`, `X-Attest-State: following`. |
| **What is missing** | They are not in `Access-Control-Expose-Headers`, so `headers.get()` returns `null` cross-origin. Measured. `freshnessExposedHeaders` lists five names (`CORS.hs:51-57`); the trio is built at `Query/Gov.hs:644-646` and was never added to that list. The irony is explicit in the source comment above the list — *"Without this list the server would send the chain point on every cross-origin response and the staleness chip would silently show nothing — a failure with no error anywhere to find it by"* — which is exactly what happened to the three headers added later. |
| **Workaround** | Read `.attestation.state` from `GET /status` (body, therefore readable). Costs a second request and is per-poll rather than per-response. |
| **Backend change** | **Three strings in one list.** Trivial. |

> **Being fixed as of this writing.** The working tree already adds the three names to
> `freshnessExposedHeaders` (uncommitted change to `CORS.hs`). **The running service does not have
> it** — the measurement above is against the deployed binary. Re-measure after the next deploy
> before you delete the `/status` fallback:
> `curl -sD - -o /dev/null -H 'Origin: <your-origin>' http://127.0.0.1:8083/status | grep -i expose`

## 5.10 The write API cannot be called from a browser as deployed

| | |
| --- | --- |
| **Screen needs** | Any write flow from a React app. |
| **What exists** | CORS allowlists `http://localhost:5173` and permits `Authorization`, so the request mechanically succeeds. |
| **What is missing** | A credential model a browser can hold. Basic auth is a shared username and password: in a browser it is either in your bundle (readable by anyone, and it authorises transaction building) or absent, which means **every write must go through a server-side proxy that holds it**. That proxy does not exist. Three measured aggravations: a 401 carries `WWW-Authenticate: Basic realm="user-realm"`, which pops the browser's **native** credential dialog you cannot style or intercept; wrong credentials are a **403, not a 401**, so `status === 401` reauth logic never fires; and both bodies are **empty**, so `.json()` throws. |
| **Workaround** | A thin BFF (Vite dev proxy / Next route handler) that holds the credentials, forwards to `:8082`, and never lets a 401 reach a document context. Build this before the first write screen. |
| **Backend change** | Per-user tokens, or an explicit decision that the write API is server-to-server only and the BFF is part of the architecture. **Medium**, and it is a design decision before it is code. |

## 5.11 Smaller things that will still cost you an afternoon

| Thing | Measured | Impact |
| --- | --- | --- |
| **Dashboard `total_dreps` ≠ `/dreps` `total`** | 204 vs **294**. The dashboard excludes `unknown` (90); `/dreps` includes it. The swagger says they are the same universe — **wrong as deployed**. | A headline that contradicts the list it links to. Filter the link or relabel the figure. §2.3 |
| **CSV has no `Content-Disposition`** | Verified: `Content-Type: text/csv;charset=utf-8` and nothing else. | The browser renders CSV inline instead of downloading. Fetch and build a `Blob` + `URL.createObjectURL` yourself. |
| **CSV on `/profiles` and `/activity` is a 406** | `GET /profiles?limit=2` with `Accept: text/csv` → **406**; same for `/activity`. Works on `/spos`, `/dreps`, `/votes`, `/delegations`, `/treasury-withdrawals`. | Do not render an Export button on the two routes that cannot serve it. `UNVERIFIED:` `/gov-actions` CSV — it declares the `Accept` parameter but timed out (§5.6) on every attempt. |
| **Swagger `limit`/`offset` bounds are the Int64 range** | `minimum: -9223372036854775808`, `maximum: 9223372036854775807` on every one; real clamps (50/200/10000/20/100) and the 10000 offset ceiling are not published. | **Do not generate client validation from the schema.** Use §3.1. |
| **The `GYAddress` description says bech32 and is wrong** | `format: cbor hex` + `minLength/maxLength: 114` + a raw-hex example are right. | A generated TypeScript client will document the wrong format. §4.2 |
| **camelCase inside snake_case bodies** | `usedAddresses`, `changeAddress`, `reservedCollateral`. A known, unfixed defect. | A global snake_case serialiser breaks every write. §4.1 |
| **Undeclared query params are silently ignored** | `/activity?offset=5` → `"offset": 0`. | A typo'd filter fails **open** — unfiltered data under a filtered-looking UI. Assert against `total`. |
| **`order_by` without `sort_order` defaults to `asc`** | `Query/Common.hs:155` | "Sort by voting power" silently shows the weakest DReps first. Always send both. |
| **`/committee` and `/metrics/formulas` have no envelope** | One returns a bare object, the other a bare array. | A generic `Page<T>` parser throws. |
| **`/drep/{id}/power` has no `offset`** | `limit`, `from_epoch`, `to_epoch`, `sort_order` only. | Not offset-pageable. 200 epochs fit one page; use the epoch range. |
| **`attest-sync` 503 is not JSON** | `ChainsyncAPI.hs:63` returns a Haskell `show`. `UNVERIFIED:` could not force it. | Do not call this service from a browser at all. §1.3 |
| **`db_unavailable` usually means "too slow", not "down"** | `/drep/{id}` 503s at 30.3 s while `/dreps` answers in 0.69 s. | **Do not retry blind.** Abandoned queries keep grinding; parallel retries compound. §3.4 |
| **Two paths for one resource** | `/drep/{id}` ≡ `/pages/drep/{id}`; `/gov-action/{id}` ≡ `/pages/gov-action/{id}`. | Pick one per resource or split your cache keys for nothing. |

---

## Appendix — reproduce every measurement

```bash
# Documents (note: /swagger.json 404s on query-api)
curl -s http://127.0.0.1:8083/swagger-api.json | jq '.paths | keys | length'   # 29
curl -s http://127.0.0.1:8082/swagger-api.json | jq '.paths | keys | length'   # 15

# Freshness: 8 headers sent, 5 exposed
curl -sD - -o /dev/null http://127.0.0.1:8083/dreps?limit=1 | grep -i '^x-'
curl -sD - -o /dev/null -H 'Origin: http://localhost:5173' \
     http://127.0.0.1:8083/status | grep -i 'expose'

# Pagination clamps and the hard offset ceiling
for L in 0 -1 201 100000; do curl -s "http://127.0.0.1:8083/dreps?limit=$L" | jq -c '{limit,n:(.items|length)}'; done
curl -s 'http://127.0.0.1:8083/dreps?offset=10000&limit=1' | jq -c '{total,offset,n:(.items|length)}'
curl -s 'http://127.0.0.1:8083/dreps?offset=10001&limit=1'   # 400 offset_too_large

# Cursor feed
C=$(curl -s 'http://127.0.0.1:8083/activity?limit=3' | jq -r .next_cursor)
curl -s "http://127.0.0.1:8083/activity?before=$C&limit=3" | jq -c '{n:(.items|length),total,next_cursor}'
curl -s 'http://127.0.0.1:8083/activity?before=a&since=b'    # 400 both_cursors_given

# Identifier refusals
curl -s http://127.0.0.1:8083/drep/garbage                   # 400 invalid_drep_id
curl -s 'http://127.0.0.1:8083/gov-action/04f2…f44#0'        # 400 — the # needs %23

# The 30 s timeout, on the DRep detail route
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' \
  http://127.0.0.1:8083/drep/drep1ygzlzlzj8r9c3zutlgh9ugqx958cwr6q704xtt9j5uf4lzsz9rwhm
# → 503 30.3

# Write-API auth: 401 (with WWW-Authenticate), 403, 200
T=0000000000000000000000000000000000000000000000000000000000000000
curl -sD - -o /dev/null http://127.0.0.1:8082/tx-status/$T | grep -i 'www-auth\|HTTP'
curl -s -o /dev/null -w '%{http_code}\n' -u bad:bad              http://127.0.0.1:8082/tx-status/$T  # 403
curl -s                                  -u smoke:smoke-devonly  http://127.0.0.1:8082/tx-status/$T  # 200
```

**Primary sources.** `src/exe/query-api/RestAPI.hs` (1942 lines — route list and the long
`Description` blocks, which are the real documentation); `src/exe/query-api/Query/Common.hs`
(pagination, sorting, `q` bounds); `src/exe/query-api/Query/Gov.hs` (statement timeout, freshness
headers, `/ready` verdict); `src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs` (page envelope, all 24
error codes); `src/lib/webapi-lib/Palmares/WebAPI/Errors.hs` (messages, parser-code recovery);
`src/lib/webapi-lib/Palmares/WebAPI/CORS.hs` (allowlist, exposed headers);
`src/lib/webapi-lib/Palmares/WebAPI/CSV.hs` (CSV, formula-injection guard);
`src/lib/offchain-lib/Palmares/TxBuilding/Exceptions.hs` (the whole write error contract);
`src/lib/offchain-lib/Palmares/DomainTypes/Core/Ids.hs` (every identifier codec);
`src/exe/interaction-api/RestAPI.hs` (auth wrapping, submit/poll);
`scripts/smoke_attest_flow.sh` (the only end-to-end write flow in the repo — read it before
building a write screen).
