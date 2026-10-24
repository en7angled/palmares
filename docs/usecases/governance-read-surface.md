# The governance read surface — what a visitor can find out, and how

**Scope.** This file documents the half of Palmares that is *derived from the chain*: the public,
unauthenticated read API over Cardano governance data. It is written for a designer and a React
developer who have not read the Haskell or the SQL. Every number, field name, parameter bound and
JSON fragment below was taken from the running service or from the code it is served by; where
something could not be checked it says `UNVERIFIED:` and why.

**Not in scope.** The on-chain attestation protocol (profiles, attestations, disputes) is a
separate surface with its own document, `docs/usecases/attestation-protocol.md`. Where a route
here touches it (`/profiles/by-credential`) this file says only what a governance screen needs and
stops.

**Measurement context.** All live values were read from `http://127.0.0.1:8083` against a fully
synced **preprod** database on **2026-10-24**, at **epoch 321**, slot ~137,140,000. The corpus is
824 DRep credentials, 131 governance actions, 3,244,723 vote rows, 2,023 current vote delegations,
511 stake pools in the distribution, 83 recorded treasury withdrawals, 3 committee seats.

A warning for anyone comparing this file with the route descriptions in
`src/exe/query-api/RestAPI.hs`: several of those descriptions quote measurements taken a few days
earlier (511 retired DReps, 294 "registered", 805 credentials). Preprod has moved since. The
numbers in *this* file are the ones the service returned today, and §8 lists the places where the
drift has become a correctness problem rather than a stale comment.

---

## 1. What a visitor can do here without a wallet

**Everything in this document.** There is no `BasicAuth`, no API key, no cookie, no wallet
connection and no CORS requirement for a server-side caller. Every route in this file is a `GET`
that answers from a public index of a public chain. `src/exe/query-api/RestAPI.hs:1-15` states this
as a design decision rather than an omission: "it publishes what is already on a public chain, and
putting a shared credential in front of it would protect nothing."

The consequence for design is that **the wallet is not the entry point and must not be the empty
state.** A visitor arrives with one of four things in hand, and the read surface answers all four:

| What the visitor has | What they want to know | Where it is answered |
| --- | --- | --- |
| Nothing | "What is going on in Cardano governance?" | `/pages/dashboard` (§3.1) |
| A pasted identifier | "Who or what is this?" | `/search` (§3.11), then the detail route |
| A DRep in mind | "Can I trust this delegate with my vote?" | `/drep/{id}` (§3.3) |
| A decision in mind | "How was this action decided, and by whom?" | `/gov-action/{id}` (§3.8) |

A wallet adds exactly two things that this surface cannot infer, and both are **write-side**:
proving you control a credential, and issuing an attestation. Nothing read-only is gated. A DRep
who wants to see "who delegates to me" does *not* need to connect anything — they need to paste
their own DRep id into §3.5.

---

## 2. Conventions that apply to every route

Read this section once; the use-case sections assume it.

### 2.0 Where the machine-readable schema is

**`GET /swagger-api.json`** — the OpenAPI 2.0 document, derived from the same Haskell type that
serves the routes, so the two cannot drift. Browsable UI at **`/swagger-ui`**. `GET /swagger.json`
is `404`; this is the only path. Verified: `info.title` `"Palmares Query API"`, `info.version`
**1.4.0**, 29 paths.

**The API version (1.4.0) is independent of the service version (`1.0.0`, in `/status` and
`/health`).** Pin a generated client to `info.version`.

I cross-checked every parameter table in §3 against this document; they agree exactly, including
the `Accept` header parameter on the seven CSV routes.

### 2.1 The page envelope

Every list route returns the same wrapper (`src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs:66`):

```json
{ "items": [ … ], "total": 294, "limit": 50, "offset": 0, "next_cursor": null }
```

| Field | Meaning | UI note |
| --- | --- | --- |
| `items` | The rows. | |
| `total` | Rows matching the filter **across the whole result set**, not the page. `null` on `/activity` only. | `null` means "do not render a count", never zero. |
| `limit` | The **applied** limit after clamping — not what you asked for. | Render paging from this, not from your request. |
| `offset` | The applied offset (negative clamps to 0). | |
| `next_cursor` | Only `/activity` ever sets it. `null` on every other route. | |

### 2.2 Pagination bounds (`src/exe/query-api/Query/Common.hs`)

| Route family | Default `limit` | Max `limit` | Paging | Verified |
| --- | --- | --- | --- | --- |
| JSON list routes | 50 | 200 | `offset` | `?limit=5000` → `"limit": 200`, 200 items |
| CSV (`Accept: text/csv`) | 50 | 10000 | `offset` | `?limit=5000` CSV → 294 rows (whole set) |
| `/activity` | 20 | 100 | `before`/`since` cursor | `?limit=500` → `"limit": 100` |
| `/drep/{id}/power` | 200 | 200 | none (series is the answer) | |
| `/search` (`limit_per_group`) | 5 | 20 | none | `?limit_per_group=100` → 20 items |
| `/pages/dashboard` `top_limit` | 10 | 50 | none | |
| `/pages/dashboard` `closing_soon_limit` | 5 | 20 | none | |
| `/pages/dashboard` `epochs` | 20 | 100 | none | |

**A limit out of range clamps silently. An offset out of range does not.**
`offset > 10000` is `400 offset_too_large` — verified: `GET /dreps?offset=10001` →
`{"code":"offset_too_large","message":"The offset is beyond the allowed range"}`. `limit=0` clamps
to 1. This asymmetry is deliberate (`Query/Common.hs:hardOffsetCeiling`): a clamped offset would
silently serve the wrong page.

**So: the UI must cap deep paging at offset 10,000 itself**, or page a filter instead. On `/votes`
(3.24 M rows) that means a plain page-number control can reach row 10,200 and no further.

### 2.3 Sorting

Every sortable route takes `order_by` (a closed enum, per route) and `sort_order` (`asc` | `desc`).
An unknown value in either is `400 invalid_parameter` — verified: `GET /dreps?order_by=bogus`.
Ordering is always stabilised by a hidden tiebreaker, so paging cannot skip or repeat rows
(`Query/Common.hs:orderClause`). `NULLS LAST` is applied per column only where NULL means "not
applicable" — which matters for `participation_rate`: a DRep with no rate sorts *after* one with
0%, not before.

### 2.4 Repeatable vs single filters

A parameter documented as repeatable (`status`, `type`, `verdict`, `voter_id`, …) is **OR within
the parameter and AND across parameters**. An **empty** repeatable parameter means *no filter*,
never "match nothing".

### 2.5 Errors

One body shape for every refusal (`Envelope.hs:93`): `{"code": "...", "message": "..."}`. Match on
`code`; `message` is display text and may be reworded.

| HTTP | Codes |
| --- | --- |
| 400 | `invalid_parameter`, `query_too_short`, `query_too_long`, `offset_too_large`, `limit_too_large`, `invalid_cursor`, `both_cursors_given`, `invalid_drep_id`, `invalid_gov_action_id`, `invalid_asset_class`, `invalid_time_range`, `invalid_epoch_range` |
| 404 | `drep_not_found`, `gov_action_not_found`, `spo_not_found`, `committee_not_found`, `profile_not_found`, `attestation_not_found`, `dispute_not_found` |
| 429 | `rate_limited` (declared; the API itself does not rate-limit — that belongs to a BFF in front) |
| 503 | `not_ready`, `indexer_behind`, `db_unavailable` |
| 500 | `internal_error` |

Nothing is 401 or 403. That is itself the contract: the surface is public
(`Envelope.hs:118-121`).

Range checks refuse rather than return an empty page — verified:
`GET /gov-actions?expires_after_epoch=400&expires_before_epoch=300` →
`400 invalid_epoch_range`. A reversed `from`/`to` time range is `400 invalid_time_range`.
Rationale (`Query/Common.hs:checkRanges`): "no rows" for an impossible range reads as "nothing
happened in that window".

### 2.6 CSV export

CSV is **content negotiation, not a path**. `GET /dreps.csv` → `404`. You must send
`Accept: text/csv`, which also raises the page ceiling to 10,000.

CSV is offered on: `/dreps`, `/gov-actions`, `/votes`, `/delegations`, `/drep/{id}/delegators`,
`/spos`, `/treasury-withdrawals`. It is **not** offered on `/activity`, `/committee`,
`/drep/{id}/power`, `/drep/{id}/updates`, `/search`, or any `/pages/*` route — those answer `406`
(verified: `/activity` and `/committee` with `Accept: text/csv` → `406`).

CSV flattens nested objects and **drops some JSON fields**. Two measured differences:

- `/dreps` CSV has no `image_url` column; the JSON row does.
- `/votes` CSV replaces the nested `cast_at` object with `cast_at` + `epoch`, and the nested
  `anchor` object with `anchor_url` + `anchor_status`.

A UI that lets a user "download what I'm looking at" must not promise column parity with the
on-screen table.

### 2.7 Chain points

Every timestamped thing carries the same object:

```json
{ "slot": 137136095, "epoch": 321, "time": "2026-10-24T05:21:35Z", "tx_hash": "2ad7b5…" }
```

`slot` and `tx_hash` are **`null` together** on the five epoch-boundary event kinds and on
`enacted_at`, because the ledger does that work at an epoch boundary with no transaction to point
at. `epoch` and `time` are always present. Verified on `/activity?event_type=gov_action_enacted`:
`"at": {"slot": null, "epoch": 305, "time": "2026-08-04T00:0…"}`.

**UI requirement:** a chain-point component must render without a transaction link, not hide the
event.

---

## 3. The use cases

### 3.1 "What is going on in Cardano governance right now?"

The landing question, asked by a visitor with nothing in hand.

**Endpoint:** `GET /pages/dashboard` — one request, one database transaction, so no two figures on
the page can come from different moments.

| Parameter | Type | Default | Max |
| --- | --- | --- | --- |
| `top_limit` | int | 10 | 50 |
| `closing_soon_limit` | int | 5 | 20 |
| `epochs` | int | 20 | 100 |

Real response (epoch 321, trimmed; `top_limit=2&closing_soon_limit=2&epochs=3`):

```json
{
  "epoch": 321,
  "total_dreps": 204, "active_dreps": 17, "inactive_dreps": 187, "retired_dreps": 523,
  "power_epoch": 321,
  "drep_power_lovelace": 505754377083269,
  "always_abstain_lovelace": 432909247919877,
  "always_no_confidence_lovelace": 330754812982,
  "total_actions": 131,
  "actions_in_flight": 11,
  "actions_by_type": [["hard_fork_initiation",4],["info_action",17],["new_committee",8],
                      ["new_constitution",2],["no_confidence",2],["parameter_change",16],
                      ["treasury_withdrawals",82]],
  "actions_by_state": [["dropped",6],["enacted",11],["expired",107],["proposed",7],["ratified",0]],
  "treasury_requested_lovelace": 656466092110010,
  "treasury_enacted_lovelace": 0,
  "closing_soon": [ { …GovActionSummary… } ],
  "top_dreps_by_power": [ { …DRepSummary… } ],
  "participation_by_epoch": [
    {"epoch":319,"dreps_with_power":186,"dreps_voted":24,"votes_cast":24,"participation_rate":0.129},
    {"epoch":320,"dreps_with_power":185,"dreps_voted":16,"votes_cast":16,"participation_rate":0.0865},
    {"epoch":321,"dreps_with_power":185,"dreps_voted":6, "votes_cast":6, "participation_rate":0.0324}
  ]
}
```

Things a designer will get wrong without reading this:

- **`power_epoch` is a different moment from `epoch`.** The ledger writes the DRep stake
  distribution one epoch behind the tip. The three `*_lovelace` figures are as of `power_epoch`,
  everything else as of `epoch`. They happen to be equal today (both 321); they will not always be.
  The UI must label the stake figures with `power_epoch`, not with the headline epoch.
- **The two reserved ledger options hold the majority of delegated stake.**
  `always_abstain_lovelace` (432.9 T lovelace) is comparable to all real DReps combined
  (`drep_power_lovelace`, 505.8 T). A "DRep power" pie that omits them is a lie about the chain.
  These two options appear *only* here and on `/drep/{reserved}/power` — never in `/dreps`.
- **`actions_in_flight` (11) is not `actions_by_state["proposed"]` (7).** In-flight is
  `last_votable_epoch >= epoch`; `state` is a reading of four lifecycle columns. An action can read
  `expired` while its voting window is still open. **`last_votable_epoch`, never `state`, decides
  whether a vote is still possible.**
- **The treasury is two numbers for a reason.** `treasury_requested_lovelace` is what 83
  withdrawals asked for; `treasury_enacted_lovelace` is 0 because none has ever been enacted on
  preprod. One field called "withdrawn" would be either misleadingly 0 or a lie.
- **`retired_dreps` (523) is published beside `total_dreps` (204), never inside it.** More
  credentials are retired than registered.
- `total_dreps` **disagrees with `/dreps`' own total (294).** This is a defect, not a nuance — see
  §8, gap G-1.

---

### 3.2 "Which DReps are there, and who should I delegate to?"

**Endpoints:** `GET /dreps` (the list) and `GET /pages/drep-explorer` (the same list plus the
sidebar's facet counts, in one snapshot). Every parameter means the same thing on both.

| Parameter | Type | Repeatable | Default | Notes |
| --- | --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 | §2.2 |
| `status` | `active`\|`inactive`\|`retired`\|`unknown` | yes | `[active, inactive, unknown]` | `reserved` is never returned |
| `anchor_status` | `valid`\|`invalid_schema`\|`hash_mismatch`\|`oversized`\|`unreachable`\|`inline`\|`not_fetched` | yes | none | |
| `has_script` | bool | — | none | script-based DRep credential |
| `min_voting_power` / `max_voting_power` | int64 lovelace | — | none | |
| `min_delegators` | int | — | none | |
| `min_participation_rate` | double 0–1 | — | none | |
| `min_rationale_rate` | double 0–1 | — | none | |
| `registered_before` / `registered_after` | ISO-8601 UTC | — | none | reversed → `400 invalid_time_range` |
| `min_age_days` | int | — | none | |
| `voted_on` | gov action id | — | none | DReps that voted on it |
| `not_voted_on` | gov action id | — | none | DReps that did not |
| `language` | text | — | none | from CIP-119 metadata; preprod values are `en-us` (50) and `""` (4) |
| `active_in_epoch` | int | — | none | |
| `q` | text, 2–100 chars | — | none | substring, case-insensitive, matches **`given_name` only** |
| `order_by` | `id`\|`voting_power`\|`delegator_count`\|`participation_rate`\|`rationale_rate`\|`registered_at`\|`votes_cast`\|`name` | — | `voting_power` | |
| `sort_order` | `asc`\|`desc` | — | `desc` | |

`q` shorter than 2 characters is `400 query_too_short` (verified: `/search?q=a`); longer than 100 is
`400 query_too_long`. A `%` or `_` the user typed is matched **literally** — verified:
`/search?q=_a` returns `total: 0` where an unescaped pattern would match many rows.

Real row (`GET /dreps?limit=2`, first item):

```json
{
  "id": "drep1ygzlzlzj8r9c3zutlgh9ugqx958cwr6q704xtt9j5uf4lzsz9rwhm",
  "hex": "05f17c5238cb888b8bfa2e5e20062d0f870f40f3ea65acb2a7135f8a",
  "has_script": false,
  "status": "active", "is_active": true, "active_until_epoch": 324,
  "given_name": null, "image_url": null, "language": null, "anchor_status": null,
  "registered_at": "2025-07-14T05:02:00Z", "age_days": 467,
  "voting_power": 400644627419166, "voting_power_epoch": 321,
  "delegator_count": 19,
  "eligible_actions": 101, "votes_cast": 10,
  "participation_rate": 0.09900990099009901,
  "rationale_rate": 0.0,
  "open_actions_unvoted": 11,
  "last_vote_at": "2026-07-29T19:21:51Z",
  "as_of_epoch": 321
}
```

**Measured today:** default list `total` = **294**; `status=active` = **17**; `status=inactive` =
**187**; `status=retired` = **523**. 17 + 187 = 204, so the default page's 294 includes **90
credentials whose status is `unknown`** — registered credentials carrying no ledger activity
deadline. The default *is* `[active, inactive, unknown]`
(`Query/Gov.hs:1810 effectiveDRepStatus`), even though the route's own description still says "the
two registered ones". A status chip row that offers only Active/Inactive/Retired cannot account for
90 of the 294 rows on screen.

**`given_name` is null for most DReps.** 824 credentials; `anchor_status=valid` matches 50. A card
design that leads with a name and avatar is designing for 6% of preprod. The identifier is the
primary label; the name is the enrichment.

**`/pages/drep-explorer`** adds four facet blocks. Real response (`?limit=1`):

```json
{
  "total": 294, "limit": 1, "offset": 0, "epoch": 321,
  "status_facets":   [["active",17],["inactive",187],["retired",523],["unknown",90]],
  "anchor_facets":   [["unreachable",51],["valid",50],["hash_mismatch",26],["invalid_schema",4]],
  "language_facets": [["en-us",50],["",4]],
  "power_buckets": [
    {"lo":0,"hi":1,"count":109}, {"lo":1,"hi":1000000000,"count":28},
    {"lo":1000000000,"hi":10000000000,"count":53}, {"lo":10000000000,"hi":100000000000,"count":69},
    {"lo":100000000000,"hi":1000000000000,"count":23}, {"lo":1000000000000,"hi":null,"count":12}
  ],
  "items": [ … ]
}
```

**The three enumerated facets drop their own predicate; `power_buckets` does not.** So with
`status=active` applied, `status_facets` still offers `retired (523)` — which is what lets a sidebar
be clickable — and the three status/anchor/language blocks **do not sum to `total`**.
`power_buckets` follows the filter as applied and **does** sum to `total`. Two different behaviours
in one sidebar; label them differently or a user will read the facet counts as the result count.
`power_buckets.hi` is `null` on the open-ended top bucket.

---

### 3.3 "What is this DRep's whole record?"

**Endpoints:** `GET /drep/{drep-id}` and `GET /pages/drep/{drep-id}` — identical handler, identical
response. One request assembles the entire profile page in a single snapshot, so the metrics block
cannot show one epoch while the delegator list shows another.

No query parameters. Response keys:

| Key | Shape | Notes |
| --- | --- | --- |
| `drep` | the `/dreps` row above | identity + headline numbers |
| `metrics` | the metrics block (§4) | every published rate, with `formula_ids` |
| `power_by_epoch` | up to 200 `{epoch, lovelace, delegator_count}` | ascending; **gaps are real** |
| `delegator_stats` | retention block (§4.4) | measured at `metrics.as_of_epoch` |
| `top_delegators` | 10 rows, by lovelace desc, current only | |
| `updates` | up to 50 certificate rows, newest first | |
| `anchor_content` | CIP-119 metadata **or `null`** | present only when the anchor hash verified |

Real `delegator_stats` and `updates[0]`:

```json
"delegator_stats": {
  "delegator_count": 19, "delegator_count_prev": 15, "delegators_retained": 15,
  "delegators_joined": 4, "delegators_left": 0,
  "delegator_retention_rate": 1.0, "window_epochs": 10
},
"updates": [
  { "kind": "registered",
    "at": {"slot":96786120,"epoch":227,"time":"2025-07-14T05:02:00Z","tx_hash":"f8c25f…"},
    "deposit": 500000000, "anchor_url": null, "anchor_status": null }
]
```

`anchor_content` for a DRep that published verifiable metadata (the `Logical Mechanism dRep`
credential):

```json
"anchor_content": {
  "given_name": "Logical Mechanism dRep",
  "objectives": "We want to provide expert consulting, comprehensive knowledge, and in-depth research into the future of Cardano.",
  "motivations": "We are a technical consulting company specializing in open-sourced decentralized applications…"
}
```

**`anchor_content: null` is the common case and means one of two different things** — the DRep
published nothing, or what it published did not match its on-chain hash. The distinction is in
`drep.anchor_status`. A profile page must not render "no information provided" for a
`hash_mismatch`: that is a *failed* claim, not an absent one, and 26 preprod credentials are in that
state.

**This route is the slowest thing on the surface and it is the main screen.** Measured today:
19.3 s–22.1 s per request under load, and `503 db_unavailable` after a 30 s statement timeout
during a period of database contention. See §8, gap G-2 — the UI needs a skeleton and a retry, not
a spinner.

---

### 3.4 "How has this DRep's voting power moved?"

**Endpoint:** `GET /drep/{drep-id}/power`

| Parameter | Type | Default | Max |
| --- | --- | --- | --- |
| `limit` | int | 200 | 200 |
| `from_epoch` / `to_epoch` | int | none | reversed → `400 invalid_epoch_range` |
| `sort_order` | `asc`\|`desc` | `asc` | |

No CSV. `total` is the number of points returned, not a table count.

```json
{"items":[{"epoch":321,"lovelace":330754812982,"delegator_count":40},
          {"epoch":320,"lovelace":330505955747,"delegator_count":39},
          {"epoch":319,"lovelace":325390800383,"delegator_count":38}],
 "total":3,"limit":3,"offset":0,"next_cursor":null}
```

**Gaps in the series are data, not holes to fill.** A missing epoch is an epoch in which the
ledger's stake distribution did not include this credential. Zero-filling it would turn an absence
into a measurement of zero. A line chart must break the line, not drop to the axis. The DRep in
§3.3 has 94 points across epochs 228–321 — not 94 consecutive epochs.

**This is the only route that serves the two reserved ledger options.**
`GET /drep/drep_always_abstain/power` and `/drep/drep_always_no_confidence/power` answer; everything
else about them 404s, because they hold stake but have no credential, no registration, no metadata
and no votes. Verified: `GET /drep/drep_always_abstain` → `404 drep_not_found`.

Measured: `always_no_confidence` returns in well under a second; `always_abstain` (1,026
delegators, the largest holder in the distribution) took **28.2 s** for the full series and **19.7 s**
for a four-epoch window — right at the 30 s timeout. See §8, gap G-3.

---

### 3.5 "Who delegates to me?"

**Endpoint:** `GET /drep/{drep-id}/delegators`. No wallet needed: the DRep pastes their own id.

| Parameter | Type | Default | Notes |
| --- | --- | --- | --- |
| `limit` / `offset` | int | 50 / 0 | CSV ceiling 10000 |
| `is_current` | bool | `true` | **`false` WIDENS to the history** — it does not invert |
| `min_lovelace` | int64 | none | |
| `order_by` | `lovelace`\|`delegated_at`\|`stake_address` | `lovelace` | |
| `sort_order` | `asc`\|`desc` | `desc` | |

```json
{"items":[{"stake_address":"stake_test1up8j58qhs6wdcxph99ea4x48xy4mtw8yarzwph2npwtjyxcm07zyj",
           "lovelace":400311000000000,
           "delegated_at":{"slot":96786120,"epoch":227,"time":"2025-07-14T05:02:00Z","tx_hash":"f8c25f…"},
           "is_current":true}],
 "total":19,"limit":2,"offset":0,"next_cursor":null}
```

Two traps:

- **`is_current` has opposite meanings on two routes.** Here, `is_current=false` *drops the clause*
  and returns the full history including superseded delegations. On `/delegations` (§3.12) it is a
  two-way filter and `false` returns only the closed accounts. Same parameter name, different
  semantics (`Filters.hs:299-308`). A shared `<DelegatorTable>` component cannot share this toggle.
- **`lovelace: null` means "delegated, not yet weighed"** — the stake the ledger counted at the
  latest snapshot, so a delegation made this epoch has no figure yet. It is not zero stake. A sum
  over the column silently understates the DRep's base.

---

### 3.6 "When did this DRep register, change its metadata, or retire?"

**Endpoint:** `GET /drep/{drep-id}/updates`

| Parameter | Type | Repeatable | Default |
| --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 |
| `kind` | `registered`\|`updated`\|`retired` | yes | none |
| `sort_order` | `asc`\|`desc` | — | `desc` |

JSON only. Row: `{kind, at, deposit, anchor_url, anchor_status}`.

`kind` is derived from the certificate's deposit column and nowhere else: positive is a
registration, negative a retirement, `null` a metadata update. This list is also where a **gap in
`age_days`** becomes visible — a DRep that registered, retired and re-registered does not get
credited the gap (§4.3), and these rows are the only place the gap can be seen.

---

### 3.7 "What governance actions exist, and which can still be voted on?"

**Endpoint:** `GET /gov-actions`

| Parameter | Type | Repeatable | Default | Notes |
| --- | --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 | |
| `type` | `parameter_change`\|`hard_fork_initiation`\|`treasury_withdrawals`\|`no_confidence`\|`new_committee`\|`new_constitution`\|`info_action` | yes | none | |
| `state` | `proposed`\|`ratified`\|`enacted`\|`expired`\|`dropped` | yes | **none** | no default filter, unlike `/dreps` |
| `anchor_status` | as §3.2 | yes | none | |
| `proposed_from` / `proposed_to` | ISO-8601 | — | none | |
| `expires_before_epoch` / `expires_after_epoch` | int | — | none | |
| `proposer_stake_address` | bech32 stake address | — | none | |
| `min_treasury_amount` / `max_treasury_amount` | int64 | — | none | |
| `q` | text 2–100 | — | none | matches `title` **or** `abstract` |
| `order_by` | `proposed_at`\|`expires_epoch`\|`type`\|`deposit`\|`treasury_amount`\|`votes_cast` | — | `proposed_at` | |
| `sort_order` | `asc`\|`desc` | — | `desc` | |

```json
{
  "id": "04f23439388432a22b6830425d0a8114a168ac5ead2767fe122eb956e8593f44#0",
  "bech32": "gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v",
  "type": "parameter_change",
  "title": null, "abstract": null, "anchor_status": "unreachable",
  "proposed_at": {"slot":136473457,"epoch":319,"time":"2026-10-16T13:17:37Z","tx_hash":"04f234…"},
  "expires_epoch": 326, "last_votable_epoch": 326,
  "lifecycle": {"state":"proposed","ratified_epoch":null,"enacted_epoch":null,
                "expired_epoch":null,"dropped_epoch":null,"formula_id":"gov_action_state_v1"},
  "deposit": 1000000000,
  "return_address": "stake_test1uzrr46pd4wn2qpzvv5fpdeycndzsgjc899jn8e4rmten3ngcgm3f4",
  "treasury_amount": null,
  "votes_cast": 40
}
```

- **There is no default `state` filter**, deliberately: 107 of preprod's 131 actions are expired,
  and hiding them by default would hide the record the registry exists to publish. The UI must
  choose its own default and say so.
- **`state` is a *reading* of the four lifecycle epochs, in a fixed order**, and all four travel
  beside it so a client can check. `last_votable_epoch`, not `state`, answers "can I still vote".
- **`title` and `abstract` come from CIP-108 metadata and are usually `null`.** Today
  `/search?q=drep` finds exactly 1 of 131 actions by title. Design the list row around
  `type` + `id` + `proposed_at`, with the title as an upgrade.
- `treasury_amount` is `null` on every non-treasury action.

---

### 3.8 "What happened to this action, and who voted how?"

**Endpoints:** `GET /gov-action/{gov-action-id}` and `GET /pages/gov-action/{gov-action-id}` —
identical. No query parameters. Six top-level keys: `action`, `tallies`, `withdrawals`,
`param_changes`, `proposer`, `anchor_content`.

Real response for an enacted hard fork (trimmed):

```json
{
  "action": { "…as §3.7…", "lifecycle": {"state": "enacted", …} },
  "tallies": [
    {"role":"constitutional_committee","epoch":180,
     "yes_power":0,"no_power":0,"abstain_power":0,
     "yes_count":3,"no_count":0,"abstain_count":0,
     "ratio":null,"threshold":null,"threshold_param":null,
     "basis":"cast_votes_only","formula_id":"tally_cast_votes_v1"},
    {"role":"spo","epoch":180,
     "yes_power":186398753984181,"no_power":0,"abstain_power":0,
     "yes_count":32,"no_count":0,"abstain_count":0,
     "ratio":1.0,"threshold":0.51,"threshold_param":"pvt_hard_fork_initiation",
     "basis":"cast_votes_only","formula_id":"tally_cast_votes_v1"}
  ],
  "withdrawals": [],
  "param_changes": [],
  "proposer": {"stake_address":"stake_test1uz6ljatyc7w52z44hskd5pu5cvw7qemwz6re3ux4pmdqumcn2qyrx",
               "actions_count":7},
  "anchor_content": {"title":"Hard Fork to Protocol Version 10","abstract":"We propose to upgrade…"}
}
```

The tally block is the most misreadable thing on this surface:

- **`basis: "cast_votes_only"` means the ratio is over the votes actually cast.** The ledger
  compares against *total active voting power*. So `ratio` vs `threshold` is an **observation,
  never a prediction of ratification.** `lifecycle` is the authoritative outcome. A progress bar
  drawn from `ratio` against `threshold` will tell users an action is passing when it is not.
- **A role with no tally row simply has no row.** `tallies: []` means nobody voted yet — verified
  on action `0ecc74fe…#0`, which has `votes_cast: 0`. Roles are not padded to three.
- **The committee carries counts and zero power.** `yes_power` 0 with `yes_count` 3 is correct: the
  committee ratifies by member quorum and holds no stake. A power-based chart must exclude the
  committee row or it renders as an abstention.
- **`ratio: null` when `yes_power + no_power = 0`.** Abstentions are excluded from the
  denominator — abstaining removes stake from the question rather than voting no.
- **`threshold: null` with a non-null `threshold_param` happens.** Verified on a live
  `parameter_change`: `{"threshold": null, "threshold_param": "dvt_p_p_economic_group", "epoch": 326}`
  — the threshold is resolved at the tally's epoch, and epoch 326 is in the future, so there is no
  protocol-parameter row yet. The UI must render "threshold: not yet known (dvt_p_p_economic_group)"
  rather than "0" or "no threshold".
- **`threshold_param: null` is informative, and each case has its own reason**: the committee
  ratifies by quorum; an `info_action` is never ratifiable so no threshold applies; the committee
  does not vote on its own replacement; SPOs vote on neither `new_constitution` nor
  `treasury_withdrawals`. "No threshold" must not render as "threshold not met".
- `param_changes` rows are `{param, group}` — e.g. `{"param":"coins_per_utxo_size","group":"dvt_p_p_economic_group"}`.
  For a `parameter_change`, the DRep threshold is the **maximum over the groups the proposal
  touches**, which is why it is computed per-proposal rather than looked up.
- `proposer.actions_count` is that stake address's whole proposing history — a cheap credibility
  signal for a proposer chip.
- `anchor_content` is `null` unless the anchor hash verified. One preprod action carries a title
  (`"Buy Ryan a island"`) whose anchor is `valid` while its `state` is `expired` — a reminder that
  metadata quality and outcome are independent.

**Id in the path: `#` must be percent-encoded as `%23`.** Both forms are accepted; the CIP-129
`bech32` form has no such character and is the one to put in a link. See §6.

---

### 3.9 "Has this DRep ever voted against the committee?"

This is the archetypal track-record question, and it is one request.

**Endpoint:** `GET /votes` — one endpoint for all three voter roles. There is no per-actor route,
because the filters are repeatable: a DRep's record, an action's votes, a committee member's record
and the global feed are the same query.

| Parameter | Type | Repeatable | Default | Notes |
| --- | --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 | CSV 10000 |
| `voter_role` | `drep`\|`spo`\|`constitutional_committee` | yes | none | |
| `voter_id` | any voter identifier | yes | none | `drep1y…`, `drep1…`, `cc_cold1…`, `cc_hot1…`, `pool1…`, or 56 hex chars |
| `gov_action_id` | gov action id | yes | none | |
| `verdict` | `yes`\|`no`\|`abstain` | yes | none | |
| `gov_action_type` | as §3.7 | yes | none | |
| `anchor_status` | as §3.2 | yes | none | **this is the "has a rationale" filter** |
| `from` / `to` | ISO-8601 | — | none | |
| `from_epoch` / `to_epoch` | int | — | none | |
| `q` | text 2–100 | — | none | matches the voter's published name |
| `order_by` | `cast_at`\|`voting_power`\|`latency`\|`voter_id`\|`gov_action_id` | — | `cast_at` | |
| `sort_order` | `asc`\|`desc` | — | `desc` | |

The question in the heading is:
`GET /votes?voter_id=<the DRep>&gov_action_type=new_committee&verdict=no`

Real row (`/votes?limit=2`, first item):

```json
{
  "gov_action_id": "04f23439388432a22b6830425d0a8114a168ac5ead2767fe122eb956e8593f44#0",
  "gov_action_bech32": "gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v",
  "gov_action_type": "parameter_change", "gov_action_title": null,
  "voter_role": "drep",
  "voter_id": "drep1ydmgzze7judffyuhz8y23s0qpy9gujtmth5jhhaqu74zj2cw5akuy",
  "voter_hot_hash": "76810b3e971a94939711c8a8c1e0090a8e497b5de92bdfa0e7aa292b",
  "voter_name": null,
  "verdict": "abstain",
  "cast_at": {"slot":137136095,"epoch":321,"time":"2026-10-24T05:21:35Z","tx_hash":"2ad7b5…"},
  "latency_hours": 184.0661111111111,
  "is_final": true, "is_first": true, "revote_count": 1,
  "anchor": null,
  "voting_power": null, "voting_power_epoch": null
}
```

A committee vote, addressed by the **cold** credential:

```json
{ "voter_role": "constitutional_committee",
  "voter_id": "cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu",
  "voter_hot_hash": "5bfa7d850280c54110534065fa91a3635bbcc0eadc69c5c792c35e1e",
  "verdict": "yes", "latency_hours": 27.56861111111111, … }
```

What a designer must know:

- **Re-votes are rows, not hidden.** `revote_count` says how many rows exist for that
  (voter, action) pair; `is_final` marks the one a verdict is measured from, `is_first` the one a
  latency is measured from. preprod's worst pair has 21,626 rows. **A "this DRep's votes" table that
  does not filter `is_final=true` will show one decision twenty thousand times** — and there is no
  `is_final` query parameter, so the filter has to happen client-side after paging. See §8, gap G-4.
- **There is no `has_rationale` parameter.** It is `anchor_status=valid`, which forces the caller to
  say which of the seven anchor outcomes they mean instead of collapsing an unreachable IPFS
  document into "no rationale".
- **`voting_power: null` is normal.** It is the voter's power at the epoch the action's window
  closed; for an action whose window has not closed, the distribution does not exist yet.
- **Committee identity is the cold credential**, the thing that survives a hot-key rotation. On
  preprod 648,767 hot-key registrations resolve to 43 cold credentials. A `cc_hot1…` id is
  *accepted* in `voter_id` and will correctly match nothing, because vote rows are keyed by the
  cold credential. That is deliberate, not a bug — but the UI must not present `cc_hot` as a way to
  look up a member's record.
- `total` on an unfiltered `/votes` is **3,244,723**. Do not render it as a page count.

---

### 3.10 "What happened this epoch? What changed since I last looked?"

**Endpoint:** `GET /activity` — the governance feed, thirteen event kinds on one timeline.

| Parameter | Type | Repeatable | Default | Notes |
| --- | --- | --- | --- | --- |
| `before` | opaque cursor | — | none | walk **backwards** (infinite scroll) |
| `since` | opaque cursor | — | none | walk **forwards**; page comes back **ascending** |
| `limit` | int | — | 20 (max 100) | |
| `event_type` | see below | yes | none | |
| `source` | `governance` | yes | none | only one value today |
| `actor` | text | yes | none | matches a credential in **either** form |

`event_type` values: `drep_registered`, `drep_updated`, `drep_retired`, `delegation_changed`,
`vote_cast`, `gov_action_proposed`, `gov_action_ratified`, `gov_action_enacted`,
`gov_action_expired`, `gov_action_dropped`, `committee_authorized`, `committee_resigned`,
`treasury_withdrawal_enacted`.

```json
{"items":[
  {"cursor":"137139689:0:4:2","event_type":"delegation_changed","source":"governance",
   "at":{"slot":137139689,"epoch":321,"time":"2026-10-24T06:21:29Z","tx_hash":"166ad7…"},
   "actor_id":"stake_test1upkgc6aeah7yen6g4eltuawkzduvwcq7p3zq6x2esjlu89szj8a37",
   "target_id":"always_abstain"},
  {"cursor":"137136153:1:1:0","event_type":"drep_retired","source":"governance",
   "at":{"slot":137136153,"epoch":321,"time":"2026-10-24T05:22:33Z","tx_hash":"44344d…"},
   "actor_id":"76810b3e971a94939711c8a8c1e0090a8e497b5de92bdfa0e7aa292b","target_id":null}],
 "total":null,"limit":3,"offset":0,"next_cursor":"137136153:0:1:0"}
```

This is **the one route that pages differently**, and the differences are all visible to a client:

- **Cursor, not offset.** `offset` is not a declared parameter; servant silently ignores it, so
  `?offset=10` returns the *first* page while looking like it worked. Do not send it.
- **`total` is always `null`.** Counting the feed means a pass over eleven union arms (3.9 M rows).
  Infinite scroll only; no "page 7 of 412".
- **`before` and `since` together is `400 both_cursors_given`** — verified.
- **A malformed cursor is `400 invalid_cursor`** — verified (`?before=nonsense`).
- **A page shorter than `limit` with no `next_cursor` is the end of the feed in that direction** —
  verified: `?before=1:0:0:0` → `{"items":[],"total":null,"limit":5,"next_cursor":null}`.
- `since` returns its page **ascending**. The component must not assume newest-first.
- **No CSV** (`406`): the endpoint cannot say how large its result set is, so a CSV would be one
  page of a feed with no way to ask for the next.
- The cursor is **opaque**. It looks like `slot:a:b:c`; do not parse it. Epoch-boundary events carry
  a synthetic slot in the cursor (e.g. `130118424:-1:8:109`) while `at.slot` is `null`.
- `actor_id` and `target_id` are text whose meaning depends on `event_type` — a credential in hex,
  a stake address in bech32, or a governance action id. The `actor` filter matches a credential in
  either form, so `drep1y…` and its 56 hex characters find the same events.

---

### 3.11 "I pasted something. What is it?"

**Endpoint:** `GET /search` — one request behind a command palette.

| Parameter | Type | Required | Default | Max |
| --- | --- | --- | --- | --- |
| `q` | text 2–100 | **yes** | — | — |
| `kinds` | `drep`\|`gov_action`\|`spo`\|`committee_member`\|`profile`\|`attestation` (repeatable) | no | all | — |
| `limit_per_group` | int | no | 5 | 20 |

A missing `q` is refused before the handler; `q` under 2 chars is `400 query_too_short`.

**All six groups always travel**, so a missing section is an empty one, never an absent key:

```json
{"query":"drep","total":22,
 "dreps":{"total":21,"items":[{"id":"drep1ygnshajy8m7cjpafmen4fnwuwmsdgcz0htxr484sujuqensu7y5sz",
   "title":"Demo DRep Ada","subtitle":"270bf6443efd8907a9de6754cddc76e0d4604fbacc3a9eb0e4b80cce",
   "badges":[],"status":"unknown",
   "target":{"kind":"drep","id":"drep1ygnshajy8m7cjpafmen4fnwuwmsdgcz0htxr484sujuqensu7y5sz"}}]},
 "gov_actions":{"total":1,"items":[{"id":"ccb27f6b…#0",
   "title":"Hard Fork to Protocol Version 10",
   "subtitle":"We propose to upgrade the Cardano PreProd test environment to Protocol Version 10…",
   "badges":["hard_fork_initiation"],"status":"enacted",
   "target":{"kind":"gov_action","id":"ccb27f6b…#0"}}]},
 "spos":{"total":0,"items":[]},
 "committee_members":{"total":0,"items":[]},
 "profiles":{"total":0,"items":[]},
 "attestations":{"total":0,"items":[]}}
```

Every hit is the same shape: `{id, title, subtitle, badges, status, target:{kind, id}}` — so one
result-row component serves all six, and `target` is what the UI routes on.

- `total` on a group is **across the whole match**, not across the capped page — so "21 results,
  showing 5" is renderable.
- **A pasted identifier matches by equality, after its bech32 checksum verifies.** A *partial*
  identifier is not matched: `pool1` is a prefix of all 686 preprod pools. So typeahead on an id
  fragment finds nothing until the whole id is pasted — the field must not look broken while the
  user types.
- A hit with no text shows its identifier as its `title` — verified on a pasted `drep1y…`.
- Text matching is substring, case-insensitive, and a user-typed `%` or `_` is literal.
- **Unlike `/dreps`, no status filter is applied**: a retired DRep is still something you look up by
  name. The group's `status` field is how the UI marks that.
- `profiles` and `attestations` are **always empty today** and are filled over the attestation
  schema later — a design must leave room for them without depending on them.
- **What is searchable is narrow on preprod**: 50 of 824 DRep credentials carry a name, 1 of 131
  actions is findable by title, **no** pool carries off-chain metadata (`ticker` is `null`
  throughout), and a committee member has no name in db-sync at all, so that group answers an
  identifier and nothing else.

---

### 3.12 "Where is the delegated stake, and whose is it?"

**Endpoint:** `GET /delegations` — one row per stake address, not per certificate. A superseded
certificate is not a row here.

| Parameter | Type | Repeatable | Default | Notes |
| --- | --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 | CSV 10000 |
| `drep_id` | DRep id or reserved option | yes | none | accepts `drep_always_abstain` / `drep_always_no_confidence` |
| `stake_address` | bech32 | yes | none | |
| `is_current` | bool | — | **`true`** | two-way filter here (contrast §3.5) |
| `from` / `to` | ISO-8601 | — | none | |
| `min_lovelace` | int64 | — | none | |
| `order_by` | `at`\|`lovelace`\|`stake_address` | — | `at` | |
| `sort_order` | `asc`\|`desc` | — | `desc` | |

```json
{"items":[{"stake_address":"stake_test1upkgc6aeah7yen6g4eltuawkzduvwcq7p3zq6x2esjlu89szj8a37",
           "target":"drep_always_abstain","target_name":null,"lovelace":null,
           "at":{"slot":137139689,"epoch":321,"time":"2026-10-24T06:21:29Z","tx_hash":"166ad7…"},
           "is_current":true}],
 "total":2023,"limit":2,"offset":0,"next_cursor":null}
```

- `is_current=false` here returns **only** the addresses whose stake account was deregistered after
  the delegation — **291**, measured. That is the opposite of §3.5's widening behaviour.
- **The reserved options are the majority target.** Measured: of **2,023** current delegations,
  **1,026** name `drep_always_abstain` (`?drep_id=drep_always_abstain`) and **40**
  `drep_always_no_confidence` — together 53%. `target` is a string that is either a DRep id or one
  of those two names, so a "delegated to" cell must render both and must not try to parse it as a
  credential.
- `lovelace: null` is an address with no stake in it.

---

### 3.13 "Who is on the constitutional committee?"

**Endpoint:** `GET /committee`. No parameters, no pagination, no CSV (`406`) — there is exactly one
committee in force and it has three seats. There is no `/committees` list.

```json
{
  "quorum_numerator": 2, "quorum_denominator": 3,
  "established_by": "bbfa303aa35d19919934fb5fe36b174609a0c1dfb47a546ccd6ea58aa752e2aa#0",
  "epoch": 321,
  "members": [
    { "cold_hash": "615b54137e73f090d2dddb04317bee41624f4013e5cfe4a5efa76d76",
      "cold_bech32": "cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu",
      "hot_hash": "5bfa7d850280c54110534065fa91a3635bbcc0eadc69c5c792c35e1e",
      "expiration_epoch": 372, "status": "active", "votes_cast": 6,
      "authorized_at": {"slot":96856972,"epoch":228,"time":"2025-07-15T00:42:52Z","tx_hash":"bb70cd…"},
      "resigned_at": null }
  ]
}
```

- **`404 committee_not_found` is a real state**, not an error to swallow: it means the ledger has
  not produced a committee, which is different from a committee with no members.
- **`status` has exactly two values, `active` and `resigned`** — expiry is *not* folded in. A member
  whose `expiration_epoch` (372) is in the future is serving today. Render the term separately;
  do not compute a third status.
- `established_by` is a governance action id — link it to §3.8.
- `votes_cast` counts **distinct governance actions** through all of a member's hot-key
  registrations, so a rotation does not split the record.
- **No member has a name.** db-sync carries none, which is why `/search`'s `committee_members` group
  answers identifiers only.

---

### 3.14 "Which stake pools hold voting weight?"

**Endpoint:** `GET /spos` — the pools in the voting-power distribution at its latest epoch.

| Parameter | Type | Default |
| --- | --- | --- |
| `limit` / `offset` | int | 50 / 0 (CSV 10000) |
| `min_voting_power` | int64 | none |
| `min_votes_cast` | int | none |
| `active_in_epoch` | int | none |
| `order_by` | `voting_power`\|`votes_cast`\|`pool_id` | `voting_power` |
| `sort_order` | `asc`\|`desc` | `desc` |

```json
{"items":[{"pool_id":"pool1945cfqzmy2qe2z59mfdwm7jwqtucncfee5xkd8f4wu97zr8xuys",
           "ticker":null,"voting_power":488729208474515,"voting_power_epoch":321,
           "delegator_count":5,"votes_cast":8,"participation_rate":null}],
 "total":511,"limit":2,"offset":0,"next_cursor":null}
```

- **This is the distribution, not the set of pools that have voted.** 45 pools have ever cast an SPO
  vote and only 39 are still in the distribution. `/votes?voter_role=spo` answers who voted.
- **`ticker` is `null` for every pool**: db-sync's pool-metadata fetcher is disabled and
  `off_chain_pool_data` has 0 rows. There is no pool branding to design with. There is also no `q`
  parameter for the same reason — exact lookup is `/search`.
- **`participation_rate` is `null` for every pool, by contract**, because no
  `spo_participation_rate_v1` exists in the metric catalog, and every published number must carry
  the id of the formula that produced it. A rate with no resolvable formula would break that
  contract. Render the column as "not published", not as 0%.

---

### 3.15 "What has the treasury been asked for, and what was paid?"

**Endpoint:** `GET /treasury-withdrawals` — the list form of the `withdrawals` block inside §3.8.
There is no `/treasury-withdrawal/{id}`.

| Parameter | Type | Repeatable | Default |
| --- | --- | --- | --- |
| `limit` / `offset` | int | — | 50 / 0 (CSV 10000) |
| `gov_action_id` | gov action id | yes | none |
| `beneficiary` | bech32 stake address | yes | none |
| `enacted_from_epoch` / `enacted_to_epoch` | int | — | none |
| `min_amount` / `max_amount` | int64 | — | none |
| `order_by` | `amount`\|`enacted_epoch` | — | `enacted_epoch` |
| `sort_order` | `asc`\|`desc` | — | `desc` |

```json
{"items":[{"gov_action_id":"372d688faa77e146798b581b322c0f2981a9023764736ade5d12e0e4e796af8c#0",
           "gov_action_title":"Rename the Chang 2 Hard Fork to the Plomin Hard Fork",
           "beneficiary":"stake_test1uppy2gm2hqzkwc80em4mlat73j4jyqvzhclrvsu72g9xg4q2yweet",
           "amount":1000000000000,"enacted_epoch":null,"enacted_at":null,"paid_heuristic":false}],
 "total":83,"limit":2,"offset":0,"next_cursor":null}
```

- **83 withdrawals, none ever enacted on preprod.** So `enacted_epoch`, `enacted_at` are `null` and
  `paid_heuristic` is `false` on **every row**, and the default sort column is entirely NULL — the
  page is decided by the hidden tiebreaker. A "paid / unpaid" visual has nothing to show on this
  network; design the empty case first.
- `enacted_at` is an epoch-boundary chain point: no slot, no tx hash (§2.7).
- **`paid_heuristic` carries its warning in its name.** `reward_rest` has no governance-action key,
  so matching a payment by (stake address, epoch) is ambiguous when one address receives two
  withdrawals in one epoch. Never render it as a confirmation.

---

### 3.16 "How is this number computed?"

**Endpoint:** `GET /metrics/formulas` — no parameters. Returns an array of 8 catalog entries.

Each entry:

| Field | Example |
| --- | --- |
| `formula_id` | `"participation_rate_v1"` |
| `name` | `"Participation rate"` |
| `field` | `"participation_rate"` — the response field it produces |
| `expression` | `"|actions_voted| / |actions_eligible|"` |
| `denominator` | prose: exactly what the denominator counts |
| `null_when` | `"eligible_actions = 0"` |
| `inputs` | `["gov_action_proposal","voting_procedure","drep_registration","epoch_param.protocol_major"]` |
| `edge_cases` | array of prose strings |
| `sql_file` / `sql_object` | one or the other |
| `sql` | the SQL statement inlined (2,237 chars for the above); `""` when `sql_object` is set |
| `params` | `["drep_hash_id","as_of_epoch"]` |
| `spec` | `"docs/spec/metrics.md#participation_rate_v1"` |
| `version` | `1` |

Six of the eight carry SQL (`sql_file`); two are view-defined (`sql_object`:
`palmares.gov_action`, `palmares.vote_tally`). Every metric-bearing response carries
`formula_id`(s) that resolve here — see §4.

**This endpoint is a UI dependency, not documentation.** Fetch it once, cache it, and key a
formula-popover off `formula_id`.

---

### 3.17 "Is what I'm looking at current?"

See §5. `GET /status`, `GET /ready`, `GET /health`.

---

### 3.18 "Give me the whole table"

`Accept: text/csv` on the seven routes in §2.6, with a 10,000-row ceiling. Verified:
`Accept: text/csv` + `?limit=5000` on `/dreps` returned all 294 rows plus a header in one request.

---

## 4. The five DRep metrics

This is the section most likely to be misread, so it is written field by field.

**Universal rules, before the individual metrics.**

1. **Every metric is computed as of a pinned epoch, published as `as_of_epoch`.** Without it the
   numbers are not reproducible, because the denominator grows every epoch. `as_of_epoch` must be
   visible on screen wherever a metric is.
2. **The formula is published and must be shown next to the number.** Every metrics block carries
   `formula_ids`, and `/metrics/formulas` (§3.16) resolves each to its expression, its denominator,
   its null condition, its inputs, its edge cases and — for six of the eight — the SQL itself.
   Showing a rate without a route to its formula breaks the contract the whole registry is built
   on. This is a **functional requirement on the UI**, not a nice-to-have.
3. **`null` is never zero.** Each metric has its own null condition, and each means "not
   applicable / cannot be assessed", never "scored zero". Sort order already respects this
   (`NULLS LAST`); the renderer must too. Measured today across 824 credentials:
   **15 have `participation_rate: null`** and **399 have `rationale_rate: null`** — that is 48% of
   the corpus for one metric. A table that prints `0%` there is wrong about half its rows.
4. **No metric is labelled good or bad, and that is deliberate.** Nothing in the catalog, the spec
   or the API assigns a threshold, a grade, a colour or a ranking to any of these five values. The
   registry publishes the number, its denominator and its formula; the reader draws the conclusion.
   A design that paints `participation_rate < 0.5` red is **inventing a judgment the data does not
   make** — and on preprod, where 82 of 131 actions are treasury-withdrawal test proposals, it would
   grade DReps on test traffic. The one hint the data gives about direction is structural, not
   evaluative: `open_actions_unvoted` is published separately precisely so that a low rate can be
   read as "has not voted yet" rather than "refused to vote".
5. **The five come from a materialized view; the sixth is executed live.**
   `participation_rate`, `rationale_rate`, `age_days`, `vote_latency_median_hours` and
   `votes_by_type` are served from `palmares.drep_metrics` (824 rows), which implements the catalog
   arithmetic batched over every credential; its agreement with the published statements is asserted
   by tests, not assumed. `delegator_retention_rate` is the one formula the server runs **verbatim**
   from the catalog's own bytes, per request.

The metrics block, real, for the DRep in §3.3:

```json
"metrics": {
  "as_of_epoch": 321,
  "eligible_actions": 101, "votes_cast": 10, "open_actions_unvoted": 11,
  "participation_rate": 0.09900990099009901,
  "rationale_verified": 0, "rationale_inline": 0, "rationale_unverified": 0,
  "rationale_pending": 0, "rationale_absent": 10, "rationale_cip100_valid": 0,
  "rationale_rate": 0.0,
  "vote_latency_median_hours": 44.55208333333333,
  "vote_latency_p90_hours": 207.06416666666672,
  "vote_latency_sample": 10,
  "age_days": 467,
  "final_votes": {"yes": 9, "no": 0, "abstain": 1},
  "votes_by_type": [
    ["hard_fork_initiation", {"eligible_actions":2,"votes_cast":1,"yes":1,"no":0,"abstain":0,"participation_rate":0.5}],
    ["info_action",          {"eligible_actions":11,"votes_cast":0,"yes":0,"no":0,"abstain":0,"participation_rate":0.0}],
    ["new_committee",        {"eligible_actions":4,"votes_cast":3,"yes":3,"no":0,"abstain":0,"participation_rate":0.75}],
    ["new_constitution",     {"eligible_actions":1,"votes_cast":0,"yes":0,"no":0,"abstain":0,"participation_rate":0.0}],
    ["no_confidence",        {"eligible_actions":1,"votes_cast":0,"yes":0,"no":0,"abstain":0,"participation_rate":0.0}],
    ["parameter_change",     {"eligible_actions":11,"votes_cast":5,"yes":5,"no":0,"abstain":0,"participation_rate":0.4545}],
    ["treasury_withdrawals", {"eligible_actions":71,"votes_cast":1,"yes":0,"no":0,"abstain":1,"participation_rate":0.0141}]
  ],
  "formula_ids": ["participation_rate_v1","rationale_rate_v1","age_days_v1",
                  "delegator_retention_rate_v1","vote_latency_median_hours_v1","votes_by_type_v1"]
}
```

### 4.1 `participation_rate` — `participation_rate_v1`

**In one sentence:** of the governance decisions this DRep *could* have voted on and whose voting
window has already closed, the fraction it actually voted on.

**Denominator:** `eligible_actions` — **distinct governance actions**, not votes, not vote rows,
not epochs. An action counts as eligible only if (a) the DRep role could vote on that type in that
action's protocol-version phase, (b) the action's voting window has already **closed** before
`as_of_epoch`, and (c) the action's window overlaps one of the DRep's registration intervals.

**Why that denominator.** Three choices were made and each is visible in the numbers:

- *Distinct actions, not vote rows.* One preprod (DRep, action) pair has 20 vote rows and 69 pairs
  have more than one; counting rows would compute a re-voter's record over twenty copies of one
  decision. This drift actually happened: the materialized view once counted rows, inflating 23 of
  809 credentials by up to 90 actions and understating one credential's published rate by 34
  points (finding `GV-03`, fixed, now asserted by a test).
- *Registration intervals, not stake-distribution membership* (`D-2`). Using the distribution would
  silently drop every DRep with zero delegated stake out of its own denominator.
- *A still-open action is not a missed vote.* Open actions are excluded and reported separately as
  **`open_actions_unvoted`**. This field exists specifically so a low rate can be read correctly;
  the UI must put the two side by side.

**Both sides of the fraction are published** (`eligible_actions`, `votes_cast`), so the number is
auditable on screen. Show it as "10 of 101", not only as "9.9%".

**NULL when `eligible_actions = 0`** — a credential that has had no closed, votable action within
any registration interval. 15 credentials today. Meaning: *not measurable yet*, never 0%.

**Good/bad: not said.** The one comparison the data supports is against this DRep's own
`votes_by_type` breakdown (§4.6), because the headline rate is dominated by whatever action type
the network has most of — on preprod, 71 of this DRep's 101 eligible actions are treasury
withdrawals.

### 4.2 `rationale_rate` — `rationale_rate_v1`

**In one sentence:** of the votes where we could tell whether a written rationale exists, the
fraction that had one.

**Denominator:** **not `votes_cast`.** It is
`rationale_verified + rationale_inline + rationale_absent`, and the numerator is
`rationale_verified + rationale_inline`. The five grades partition the DRep's final votes and sum
to `votes_cast`:

| Grade | Meaning | In the rate? |
| --- | --- | --- |
| `rationale_verified` | anchor fetched and its hash matched | numerator + denominator |
| `rationale_inline` | a `data:` URI — the rationale **is** the URL, on chain | numerator + denominator |
| `rationale_absent` | demonstrably no anchor | denominator only |
| `rationale_unverified` | we could not fetch or could not verify it | **neither side** |
| `rationale_pending` | db-sync has not attempted the fetch yet | **neither side** |

**Why that denominator — this is the single most important sentence in this section.** Dividing by
`votes_cast` was the original decision and was **changed on the strength of a measurement**: on
preprod, 140 of the 237 unreachable DRep-vote anchors are `ipfs://` URIs the indexer's gateway list
cannot fetch. Dividing by `votes_cast` would have published *our infrastructure's* inability to
fetch as *36 authors' negligence*. `inline` was added for the mirror-image reason: a `data:` URL
carries its rationale on chain, which is stronger than a fetched one, not weaker.

**So a UI must never present this as "% of votes explained".** It is "% of *assessable* votes
explained", and `rationale_unverified` / `rationale_pending` are the count that was set aside. All
five counters are on the response so the UI can show the set-aside explicitly.

**`rationale_pending > 0` means the number is provisional** and the UI should say so.

**Validity is "a row exists in db-sync's `off_chain_vote_data`", not `is_valid = true`.** db-sync
writes that row only when the blake2b-256 hash matched; mismatches and unreachable URLs go
elsewhere. `is_valid` grades the *body* against CIP-100 and ships separately as the non-headline
`rationale_cip100_valid`. Using schema conformance as the headline test would punish an honest
rationale for a schema nit and would be indistinguishable from "not fetched yet".

**NULL when all three assessable grades are 0** — i.e. none of this DRep's rationales could be
assessed. **399 of 824 credentials today**, which includes every DRep that never voted. Verified
live: the second row of `/dreps?limit=2` has `"votes_cast": 0, "rationale_rate": null`.

**Good/bad: not said.** And note the example DRep: `rationale_rate: 0.0` with 10 votes, all graded
`absent`. That is a real 0, and it is a different fact from the 399 nulls.

### 4.3 `age_days` — `age_days_v1`

**In one sentence:** how many days this DRep has actually been a registered DRep, counted in chain
time, with retired periods not credited.

**No denominator** — it is a sum, not a ratio:
`Σ over registration intervals of (min(interval end, cursor) − interval start) / 86400`.

**Why it is computed that way.** Two decisions:

- *`as_of_time` is the block time of the cursor's block* — chain time, never `now()` and never a
  database insertion timestamp. This makes a past epoch's number reproducible.
- *A gap is not credited.* A DRep that registered, retired for 50 epochs and re-registered does not
  get the gap. There is no extra field for it: the gap is visible in `/drep/{id}/updates` (§3.6),
  which is why that list is part of the profile page.

**NULL when the credential has no registration interval at all** (`D-17`). Those credentials exist
in db-sync only because something delegated to them. Verified live:
`GET /drep/a61261172624e8333ceff098648d90f8e404e2e36d5b5f5985cbd35d` returns `200` with
`"age_days": null, "registered_at": null, "status": "unknown", "active_until_epoch": null`.

**Good/bad: not said**, and "older is better" is not a claim the data makes — it is a fact about
tenure, published next to the record so a reader can weigh a 467-day record against a 30-day one
themselves.

### 4.4 `delegator_retention_rate` — `delegator_retention_rate_v1`

**In one sentence:** of the people who were delegating to this DRep ten epochs ago, the fraction
still delegating to it now.

**Denominator:** `delegator_count_prev` — the delegator set **as it was `window_epochs` epochs
before `as_of_epoch`**. The whole block is published so the rate is auditable:

```json
{"delegator_count":19,"delegator_count_prev":15,"delegators_retained":15,
 "delegators_joined":4,"delegators_left":0,"delegator_retention_rate":1.0,"window_epochs":10}
```

Note that `delegator_retention_rate: 1.0` sits beside a *growing* base (15 → 19). Retention and
growth are different questions; `delegators_joined` is the growth one. A single "retention" badge
would hide it.

**Why `W = 10` epochs.** 50 days on both networks: one real governance cycle, and longer than
`govActionLifetime` on either network (7 on preprod, 6 on mainnet), so a churn figure always spans
at least one full action. It is **bound as a parameter** rather than written into the SQL, and
**echoed on the response as `window_epochs`** so a reader never has to guess the window. The UI
must take the window from the response, not hardcode "10 epochs".

**A delegator is an address whose *latest* vote-delegation names this DRep and whose stake
credential is still registered.** A closed stake account is not a delegator even though db-sync
keeps the row.

**NULL when `delegator_count_prev = 0`** — nobody to retain.

**This is the one formula the server executes verbatim**, because the first hand-written
implementation derived it differently ("every address that ever delegated before epoch N") and
measured 26 previous delegators and a rate of 0.42 where the published formula gives 11 and 1.0.
If a screen shows this number, the formula it shows beside it is literally the code that produced
it.

**Known ceiling:** the spec records that if `/drep/{id}` p95 exceeds 500 ms on preprod, these two
CTEs get promoted to a materialized view. Measured today the whole route is 19–22 s, so that
threshold is already crossed — see §8, gap G-2.

### 4.5 `vote_latency_median_hours` — `vote_latency_median_hours_v1`

**In one sentence:** the median number of hours between an action being proposed on chain and this
DRep's **first** vote on it.

**No denominator** — it is a median over a sample. Three fields travel together and all three must
be shown:

| Field | Example |
| --- | --- |
| `vote_latency_median_hours` | `44.55` |
| `vote_latency_p90_hours` | `207.06` |
| `vote_latency_sample` | `10` |

**Why the sample size ships with the number: a median over two votes is not a median.** Both
percentiles come from one interpolated pass (`percentile_cont`, not nearest-sample), so the median
may not be a member of the sample.

**The sample is the *first* vote on each action**, while a verdict uses the last. Latency is about
when the DRep showed up; the verdict is about where it landed. The sample is drawn from the same
eligible set as `participation_rate`, so the two are comparable.

**Measured from the proposal's block time**, not from the start of the epoch and not as a fraction
of the voting window.

**NULL when `vote_latency_sample = 0`.** `percentile_cont` over an empty set is NULL, and the
sample size is published precisely so a reader can tell "no data" from "zero hours".

**Good/bad: not said**, and lower is not obviously better — a DRep that votes within an hour of a
proposal appearing may not have read it. The p90 beside the median is what makes the number
readable: 44 h median against 207 h p90 says "usually prompt, sometimes very late", which is a
different story from a 44 h median with a 50 h p90.

### 4.6 `votes_by_type` — `votes_by_type_v1` (the sixth, and the one that rescues the other five)

Not one of the five headline metrics, but it is in the same block and it is what stops the headline
rate being misread.

**All seven Conway action types are always emitted**, including rows with `eligible_actions: 0` and
`participation_rate: null`. Omitting them would make a DRep look as though it has no
`no_confidence` record when the truth is that preprod has only ever had two such actions.

The example DRep reads 9.9% overall but 75% on `new_committee`, 50% on `hard_fork_initiation` and
1.4% on `treasury_withdrawals` — because 71 of its 101 eligible actions are treasury-withdrawal
test proposals. **The headline rate flattens exactly the nuance a delegator needs.** A profile page
that shows only the headline is actively misleading on this network.

`final_votes` (`{yes, no, abstain}`) is the same DRep's overall verdict split, over final votes
only.

---

## 5. Freshness and trust, as UI requirements

The registry's claim is "verifiable", so a screen that cannot say how current it is has broken the
product. Three endpoints answer three *different* questions and conflating them is how a registry
serves stale data confidently.

### 5.1 `GET /health` — is the process alive

Touches nothing, so a slow database cannot get the service restarted. Real:

```json
{"service":"query-api","status":"healthy","timestamp":"2026-10-24T06:32:15Z","version":"1.0.0"}
```

Not a data-freshness signal. Do not render it to users.

### 5.2 `GET /ready` — should this instance be answering

`200` with the same body shape (`"status":"ready"`), or **503 with an error code**. Real:

```json
{"service":"query-api","status":"ready","timestamp":"2026-10-24T06:14:47Z","version":"1.0.0"}
```

The seven conditions that make it 503 (`Query/Gov.hs:readyVerdict`), in order:

| Condition | Code |
| --- | --- |
| No database reading at all | `db_unavailable` |
| db-sync lag > `ready_max_lag_seconds` | `indexer_behind` |
| No DRep stake distribution for the current or previous epoch | `indexer_behind` |
| The database is for the **wrong network** | `not_ready` |
| db-sync lag + attestation-projector lag > ceiling | `indexer_behind` |
| The attestation projector reported `state: "error"` | `indexer_behind` |
| The attestation projector stopped reporting for > ceiling | `indexer_behind` |

Two asymmetries the UI depends on:

- **An absent attestation projector passes.** A governance-only deployment runs none, and a probe
  that failed on absence would take a healthy service out of rotation for doing nothing wrong.
- **`state: "syncing"` is deliberately *not* red.** A projector mid-pass is a healthy service
  answering honest partial pages. `/status.attestation.state` and the `X-Attest-State` header are
  how a client knows to say so.

### 5.3 `GET /status` — the numbers behind the verdict

The real response, now:

```json
{
  "network": "preprod",
  "governance": {
    "epoch": 321, "slot": 137140095, "block_time": "2026-10-24T06:28:15Z",
    "lag_seconds": 59, "is_ready": true, "source": "cardano-db-sync"
  },
  "attest_lag_seconds": 0,
  "attestation": {
    "slot": 137140095, "kupo_tip_slot": 137140095, "lag_seconds": 0,
    "state": "following", "last_sync_at": "2026-10-24T06:29:06.66388Z",
    "is_ready": true,
    "policy_id": "648c6a732aa55efec29815bdd25cf65c565cf92619aadde1d31496d3",
    "last_error": null, "source": "attest-sync/kupo"
  },
  "drep_distr_epoch": 321,
  "amber_lag_seconds": 120,
  "ready_max_lag_seconds": 300,
  "metrics_as_of_epoch": 321,
  "epoch_params": {
    "epoch": 321, "gov_action_lifetime": 6, "gov_action_deposit": 1000000000,
    "drep_deposit": 500000000, "drep_activity": 20,
    "committee_min_size": 3, "committee_max_term_length": 146,
    "drep_thresholds": [["dvt_motion_no_confidence",0.67],["dvt_committee_normal",0.67],
      ["dvt_committee_no_confidence",0.6],["dvt_update_to_constitution",0.75],
      ["dvt_hard_fork_initiation",0.6],["dvt_p_p_network_group",0.67],
      ["dvt_p_p_economic_group",0.67],["dvt_p_p_technical_group",0.67],
      ["dvt_p_p_gov_group",0.75],["dvt_treasury_withdrawal",0.67]],
    "pool_thresholds": [["pvt_motion_no_confidence",0.51],["pvt_committee_normal",0.51],
      ["pvt_committee_no_confidence",0.51],["pvt_hard_fork_initiation",0.51],
      ["pvtpp_security_group",0.51]]
  }
}
```

`governance.is_ready` is the **same verdict** `/ready` gives, computed from the same inputs, so one
request is enough and two answers cannot disagree. **Poll `/status`, not `/ready`**, for a UI
badge.

### 5.4 The amber and red thresholds, and where they come from

**Both come from `/status` itself — do not hardcode them.**

| Field | Value today | Source |
| --- | --- | --- |
| `amber_lag_seconds` | **120** | UI warning band. `amberLagDefault`, env `PALMARES_AMBER_LAG_SECONDS` |
| `ready_max_lag_seconds` | **300** | `/ready` turns red. `readyMaxLagDefault`, env `PALMARES_READY_MAX_LAG_SECONDS` |

The split is decision **`D-7`** (`docs/spec/decisions.md`): "Red at 300 s, with the UI's amber at
120 s as a separate, lower bar." The reasoning for keeping amber out of the probe is explicit in
`Query/Gov.hs:amberLagDefault`: "If this were the readiness threshold, a normal gap between blocks
would take the service out of rotation; as a band it lets a dashboard say 'catching up' while the
service keeps answering."

So the UI rule is:

| `governance.lag_seconds` | State | What the screen does |
| --- | --- | --- |
| `≤ amber_lag_seconds` (120) | green | Nothing, or a quiet "as of <block_time>". |
| `> amber` and `≤ ready_max` (300) | **amber** | Keep rendering everything. Show "catching up — data as of <block_time>, N s behind". |
| `> ready_max` (300) | **red** | The service is 503-ing. Show the last-known block time and "the index is behind; numbers may be stale". Do not blank the page. |

### 5.5 The `X-*` headers — on *every* response, including errors

Set by middleware (`Query/Gov.hs:621-647`), so they arrive on a 404 and a 400 too (verified: the
`X-Chain-*` set was present on a `404` for `/swagger.json`).

| Header | Example | Present when |
| --- | --- | --- |
| `X-Chain-Epoch` | `321` | always (a successful freshness poll exists) |
| `X-Chain-Slot` | `137140095` | always |
| `X-Chain-Block-Time` | `2026-10-24T06:28:15Z` | always; ISO-8601, deliberately parseable by a browser |
| `X-Data-Lag-Seconds` | `59` | always |
| `X-Data-Source` | `cardano-db-sync` | always |
| `X-Attest-Slot` | `137140095` | **only when an attestation projector exists** |
| `X-Attest-Lag-Seconds` | `0` | same |
| `X-Attest-State` | `following` | same |

**The absence of the three `X-Attest-*` headers is itself information**: this deployment has no
attestation projector at all. That is different from a projector that is behind, and different
again from one in `state: "error"`. I observed both states live in one session — the headers were
absent at 06:14 and present at 06:29.

Three `X-Attest-*` and five `X-Chain-*` because the projector publishes a cursor, so there is no
epoch and no block time to stamp without inventing one.

**UI requirement:** a freshness badge should be driven by the headers of the request the user is
looking at, not by a separate `/status` poll, so the badge belongs to the data on screen. Use
`/status` for the thresholds and the epoch parameters.

### 5.6 The three screens that must exist

1. **The index is behind** (lag between amber and red, or a `503 indexer_behind`). Render the data
   with a banner carrying `block_time` and `lag_seconds`. Never blank the page: the governance
   routes are complete and correct, just not current.
2. **Something is backfilling.** `attestation.state` is `"syncing"`, `/ready` is still green by
   design. The banner says "attestation records are still loading"; governance data is unaffected.
   `attestation.last_error` is the field to show when `state` is `"error"`.
3. **A part of the data has no projector at all.** `attestation: null` and `attest_lag_seconds: null`
   in `/status`, no `X-Attest-*` headers. The correct UI is to **hide the attestation surface
   entirely**, not to show it empty — an empty attestation panel reads as "nobody has attested
   anything", which is a false statement about the chain. `/status.attestation == null` is the one
   signal that distinguishes the two, which is why it is published as a whole object rather than
   only as a lag number.

Also: `metrics_as_of_epoch` (321) is published separately from `governance.epoch` because the
materialized view refreshes on its own schedule (default 300 s). If they differ, the metrics on
screen are from an earlier epoch than the tip and the UI should say which.

---

## 6. Identifiers

This is where a paste box gets written wrong.

### 6.1 DRep identifiers — three input forms, one output form

| Form | Example | Accepted? |
| --- | --- | --- |
| **CIP-129** (29 bytes, header byte `0x22` key / `0x23` script) | `drep1ygzlzlzj8r9c3zutlgh9ugqx958cwr6q704xtt9j5uf4lzsz9rwhm` | yes — **and this is the form the API returns** |
| **CIP-105** (28 bytes, no header byte, no script bit) | `drep1qhchc53cewyghzl69e0zqp3dp7rs7s8nafj6ev48zd0c54m4nqe` | yes |
| **Raw hex**, 56 characters | `05f17c5238cb888b8bfa2e5e20062d0f870f40f3ea65acb2a7135f8a` | yes, upper or lower case |
| **Reserved ledger options** | `drep_always_abstain`, `drep_always_no_confidence` | yes, but only on `/drep/{id}/power` and as a `/delegations?drep_id=` value |
| Anything else | `not-a-drep`, bad bech32 checksum | **`400 invalid_drep_id`** |

All verified live. The decisive test: the credential
`763ef75661f0cd8c8fa159a79d79bfe8f9a76878bdaaff700598ee0e` exists in db-sync **twice**, once as a
key credential and once as a script credential, because someone delegated using the CIP-105 string
(which carries no script bit). I requested it three ways:

| Requested | Returned `id` | `has_script` |
| --- | --- | --- |
| `drep1yfmraa6kv8cvmry059v608tehl50nfmg0z764lmsqkvwurs4aql29` (CIP-129, **key**) | `drep1ydmraa6kv8cvmry059v608tehl50nfmg0z764lmsqkvwurs40sw2z` | `true` |
| `drep1ydmraa6kv8cvmry059v608tehl50nfmg0z764lmsqkvwurs40sw2z` (CIP-129, **script**) | same | `true` |
| `drep1wcl0w4np7rxceraptxne67dlaru6w6rchk407uq9nrhquq6gltn` (CIP-105) | same | `true` |

**The three UI rules that follow:**

1. **The id you sent is not necessarily the id you get back.** Lookup is by the 28-byte hash; the
   canonical id is re-rendered from the row's own `has_script`. So **never compare a pasted id to a
   returned id, and never use a pasted id as a React key or a cache key** — re-key on `response.id`
   and, ideally, canonicalise the URL to it.
2. **Accept all three forms in a paste box, and don't try to validate bech32 client-side.** The API
   is the authority; `400 invalid_drep_id` is the answer to show.
3. **Display the CIP-129 form; offer the hex.** The response carries both (`id` and `hex`), and the
   `hex` is what a user needs to search db-sync or another explorer.

**One route refuses CIP-105 and bare hex on purpose:** `/profiles/by-credential/{credential}`
answers `400 invalid_drep_id` for them, because a CIP-105 id is a well-formed identifier that route
cannot answer about, and answering "no profile claims it" would be a false negative dressed as a
result. (That route belongs to the attestation document; noted here because the same paste box may
feed it.)

### 6.2 Governance action identifiers — two forms

| Form | Example | Notes |
| --- | --- | --- |
| **Canonical** `<tx_hash_hex>#<index>` | `04f23439…93f44#0` | What db-sync, cardano-cli and every explorer print. **The `#` must be sent as `%23`** — a URL treats it as a fragment delimiter. |
| **CIP-129 bech32** | `gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v` | No special character. **This is the form to put in a link.** |

Both are accepted in the path and in `gov_action_id` query parameters. Both are returned: every
action row carries `id` (canonical) and `bech32`.

Refusals verified: `GET /gov-action/deadbeef%230` → `400 invalid_gov_action_id` (the hash must be
exactly 64 hex characters). A bech32 payload of any length other than 33 bytes is refused the same
way.

**UI rule:** route on `bech32`, display `id`, and if you must put the canonical form in a URL,
encode it — a hand-built `` `/gov-action/${id}` `` silently truncates at the `#` and requests a
different action.

### 6.3 Other identifiers a user will see

| Thing | Form | Notes |
| --- | --- | --- |
| Committee member | `cc_cold1…` (CIP-129) + `cold_hash` hex | The **cold** credential is the identity. `cc_hot1…` is accepted in `/votes?voter_id=` and will correctly match nothing. |
| Stake pool | `pool1…` (CIP-5, 28 bytes, no header byte) | No CIP-129 form: every tool shows this one. |
| Stake address | `stake_test1…` / `stake1…` | Used as `proposer_stake_address`, `beneficiary`, `stake_address`, and as `return_address` on an action. |

`/votes?voter_id=` accepts all of these plus 56 hex characters in one parameter.

**A wart worth designing around:** a malformed value in `/votes?voter_id=` is reported as
`400 invalid_drep_id` even when the user pasted a pool or committee id — verified. The message
("Not a DRep identifier") will confuse a user who pasted a pool id. See §8, gap G-5.

---

## 7. Empty, partial and pathological states

Every row below was produced by calling the live API. These are the screens that get forgotten.

| State | Request | Response |
| --- | --- | --- |
| Malformed DRep id | `GET /drep/not-a-drep` | `400 {"code":"invalid_drep_id","message":"Not a DRep identifier"}` |
| Bad bech32 checksum | `GET /drep/drep1yg000…0000` | `400 invalid_drep_id` |
| Well-formed, unknown credential | `GET /drep/0000…0000` (56 hex zeros) | `404 {"code":"drep_not_found","message":"No DRep with that identifier"}` |
| Same, on a sub-route | `GET /drep/0000…0000/updates` | `404 drep_not_found` |
| A reserved ledger option on the profile route | `GET /drep/drep_always_abstain` | `404 drep_not_found` — **by design**: it holds stake but has no credential, no registration and no votes. Its power series *does* answer. |
| A credential that never registered | `GET /drep/a612…d35d` | **`200`**, with `age_days: null`, `registered_at: null`, `active_until_epoch: null`, `status: "unknown"`, `participation_rate: null`, `rationale_rate: null`, `power_by_epoch: []`, `updates: []`, and `top_delegators` with 1 row. **Not in `/dreps`' list at all.** A profile page with no history, no metrics and one delegator is a real and reachable screen. |
| A DRep that never voted | `/dreps` row for `drep1yg3j4dkpz3j0eh4e9d5l3uy43sf5ndz2wv4c2fywgdcu4wsjmj5wp` | `200`: `votes_cast: 0`, `eligible_actions: 32`, `participation_rate: 0.0`, **`rationale_rate: null`**, `last_vote_at: null`, `delegator_count: 417`, `anchor_status: "unreachable"`. A real 0 beside a real null, on the same row. |
| An action with no votes yet | `GET /gov-action/0ecc74fe…%230` | `200` with `"tallies": []`. **Not three empty role rows** — no role is padded. `votes_cast: 0` on the summary. |
| An action with a future threshold epoch | `GET /gov-action/gov_action1qnerg…` | `200`, tally has `threshold: null`, `threshold_param: "dvt_p_p_economic_group"`, `yes_power: 0`, `abstain_count: 39`. The bar has a name but no value yet. |
| Page past the end (offset list) | `GET /dreps?offset=400` | `200 {"items":[],"total":294,"limit":50,"offset":400}` — empty items, **real total**. The UI can tell "past the end" from "no matches". |
| Page past the end (gov actions) | `GET /gov-actions?offset=9999` | `200 {"items":[],"total":131,"limit":50,"offset":9999}` |
| Offset beyond the hard ceiling | `GET /dreps?offset=10001` | `400 offset_too_large` |
| End of the cursor feed | `GET /activity?before=1:0:0:0&limit=5` | `200 {"items":[],"total":null,"limit":5,"next_cursor":null}` — no cursor means no more. |
| Malformed cursor | `GET /activity?before=nonsense` | `400 {"code":"invalid_cursor","message":"The cursor is not one this endpoint issued"}` |
| Both cursors | `GET /activity?before=x&since=y` | `400 {"code":"both_cursors_given","message":"Give either \`before\` or \`since\`, not both"}` |
| Filter that matches nothing | `GET /activity?event_type=treasury_withdrawal_enacted` | `200` with `items: []` — a legitimate "has never happened on this network". |
| `GET /dreps?anchor_status=not_fetched` | | `200`, `total: 0` — and `inline` and `oversized` are also 0. Three of the seven anchor states are unpopulated on preprod; the facet block only lists the four that exist. |
| Search that matches nothing | `GET /search?q=_a` | `200` with **all six groups present and empty**, `total: 0`. A literal `_`, not a wildcard. |
| Search query too short | `GET /search?q=a` | `400 query_too_short` |
| Invalid enum value | `GET /dreps?status=bogus`, `?order_by=bogus` | `400 invalid_parameter` |
| Reversed epoch range | `GET /gov-actions?expires_after_epoch=400&expires_before_epoch=300` | `400 invalid_epoch_range` |
| CSV on a route that has none | `Accept: text/csv` on `/activity`, `/committee` | `406` |
| CSV as a path | `GET /dreps.csv` | `404` |
| A credential claimed by more than one profile | `GET /profiles/by-credential/{cip129}` | `200` with a **paged** result; `total` is the answer: `0` unclaimed, `1` a single claim, `>1` several profiles claiming the same credential — **and this API does not pick a winner.** Ordered oldest-claim-first by slot, so row 0 is deterministically the first claimant. Verified today: `total: 0` for the tested credential (nothing is claimed yet on this deployment). The UI must be able to render a contested credential as *contested*, not as "the first one". Semantics belong to the attestation document. |
| Database saturated | `GET /drep/{id}`, `GET /drep/drep_always_abstain/power` | **`503 {"code":"db_unavailable","message":"Service temporarily unavailable"}` after a 30 s statement timeout.** Observed repeatedly today while another process held the database. This is a reachable state on the main profile screen, so the UI needs a retry affordance and not a dead spinner. |
| The service itself restarts | any | Connection refused, then back within 5 s (`restart: unless-stopped`). Observed once today. The client needs a retry, not an error page. |

---

## 8. Gaps for the frontend

Each gap: what a screen needs, what exists, what is missing. These are findings, not opinions —
each was verified against the live API.

### G-1. The dashboard's headline DRep count contradicts the list it links to

**What the screen needs:** "204 DReps" on the dashboard and "204 results" on the DRep list.

**What exists:** `/pages/dashboard` returns `total_dreps: 204` (`active_dreps: 17` +
`inactive_dreps: 187`). `/dreps` with no filter returns `total: 294`. The
explorer's own facets explain the difference: `status_facets` are
`active 17, inactive 187, retired 523, unknown 90`, and the default `/dreps` status set is
`[active, inactive, unknown]` (`Query/Gov.hs:1810`), so the list includes the 90 `unknown`
credentials while the dashboard's headline drops them.

**What is missing:** either `dashboardTotalDreps` should be `active + inactive + unknown`, or the
dashboard needs a fourth count. Today a user who clicks "204 DReps" lands on a list of 294, and the
route's own description still promises `total_dreps` "is the universe /dreps lists by default".
Until it is fixed, **the frontend must not use `total_dreps` as the list's count** — fetch
`/pages/drep-explorer` and use its `total`.

### G-2. The main profile screen is a 20-second request with a 30-second cliff

**What the screen needs:** a DRep profile that loads.

**What exists:** `GET /drep/{id}` assembles seven blocks in one transaction — the right correctness
choice, and it makes the route as slow as its slowest part. Measured today: **19.3 s, 18.6 s,
22.1 s** for three successful requests, and **`503 db_unavailable` after a 30 s statement timeout**
on four consecutive attempts while the database was busy. `docs/spec/metrics.md` records the
intended ceiling: "if `/drep/{id}` p95 exceeds 500 ms on preprod, promote the two CTEs to a
materialized view". That ceiling is crossed by roughly 40×.

**What is missing:** either the retention CTEs become a materialized view, or the composite is
split so identity + metrics (fast) render before `delegator_stats` and `power_by_epoch` (slow). As
the API stands, a React page cannot render progressively — it is one request or nothing. **The
frontend needs a skeleton, a 30 s+ client timeout, and an explicit retry.**

*Caveat:* the database was under heavy concurrent load from an unrelated process during the whole
measurement window, so the absolute numbers are a worst case. The 30 s timeout being reachable at
all on the main screen is the finding.

### G-3. The largest holder of delegated stake cannot reliably render its own chart

**What the screen needs:** a voting-power history for `drep_always_abstain`, which holds 432.9 T
lovelace — about 46% of preprod's delegated stake, more than every real DRep combined.

**What exists:** `GET /drep/drep_always_abstain/power` returned **`503` four times**, then **200 in
28.2 s** for the full series and **19.7 s** for a four-epoch window. The sibling
`drep_always_no_confidence` (40 delegators) returns in under a second. The cost is the
`drep_epoch_delegators` join scaled by 1,026 delegators.

**What is missing:** an index or a projection for the reserved options' delegator counts, or a way
to ask for the power series **without** `delegator_count`. There is no parameter to drop that
column. Narrowing `from_epoch`/`to_epoch` helps but does not get under a second.

### G-4. ~~`/votes` cannot filter to final votes~~ CLOSED — and it is the parameter that makes the endpoint usable

> **Closed 2026-10-24: `?is_final=true`.** One row per (voter, action) — the vote that counts. On
> preprod that is **3,244,723 rows → 931**, and 65,000 pages → 19.
>
> Expressed the obvious way, `WHERE seq_last = 1`, the same filter costs **7,058 ms**, because a
> window column is not pushdown-safe and Postgres must compute the window over the whole corpus
> before it can test it. It reads the pre-aggregation instead and costs **2.4 ms**.
>
> **Deep pages WITHOUT the filter are still slow** — 13 s at offset 1000, 22 s at offset 10000 — and
> that is a data property, not a query shape: a page of 100 stress-test votes belongs to 70–150
> partitions of ~20,000 rows each, so `revote_count` for one row is a count over ~20,000 siblings and
> any partition-complete restriction must read 1.5–3.2 M rows. The shallow pages did get 3.3× faster.
> A DRep's voting record is `?voter_id=…&is_final=true`, which is 19 pages, not 65,000.

**What the screen needs:** a DRep's voting record — one row per decision.

**What exists:** `/votes` returns **every** vote row, re-votes included. `revote_count`, `is_final`
and `is_first` are on the row; **none of them is a query parameter**, and `is_final` is not an
`order_by` value either. preprod's worst (voter, action) pair has 21,626 rows.

**What is missing:** `is_final=true` (and `is_first=true`) as filters. Without them, a client must
page the whole history and de-duplicate client-side — which, with a 200-row page ceiling and a
10,000-row offset cap, it cannot do for the stress-test credentials at all. This is the single
highest-value missing filter on the surface.

### G-5. A malformed pool or committee id is reported as `invalid_drep_id`

**What the screen needs:** "that isn't a valid pool id".

**What exists:** `/votes?voter_id=<bad value>` → `400 {"code":"invalid_drep_id","message":"Not a DRep identifier"}`,
whatever the user pasted. Verified.

**What is missing:** a role-neutral code (e.g. `invalid_voter_id`), or a message that lists the
accepted forms. The frontend will have to override the message for this parameter.

### G-6. There is no "vote against the committee" or "vote against the majority" query

**What the screen needs:** the archetypal track-record question — "has this DRep ever voted against
the constitutional committee?" / "how often does it dissent?".

**What exists:** `/votes` can filter by `voter_id`, `verdict` and `gov_action_type`, and
`/gov-action/{id}` carries the per-role tallies. Both halves exist.

**What is missing:** the join. Answering "votes where this DRep's verdict differed from the
committee's" means one `/votes` request per action, or fetching both sides and joining in the
browser. There is no `disagreed_with_role` filter and no "majority verdict" field on a vote row.
**Budget for N requests or build it in a BFF.**

### G-7. No historical metric series — the DRep profile cannot show a trend

**What the screen needs:** "this DRep's participation over the last ten epochs" — the obvious chart
on a profile page.

**What exists:** every metric is a **single value at `as_of_epoch`**. `/drep/{id}/power` is the only
per-epoch series, and it carries only `lovelace` and `delegator_count`.
`/pages/dashboard.participation_by_epoch` is a **network-wide** series, not per-DRep.

**What is missing:** a per-DRep epoch series for `participation_rate`, `rationale_rate` or
`delegator_count`. The matview holds one row per credential at one epoch, so there is no history to
query at any cost. **A per-DRep trend line cannot be fed by this API.** The only movement a profile
can show today is voting power and delegator count.

### G-8. No sort by participation or rationale on the pages a user reaches them from

`/dreps` sorts by `participation_rate` and `rationale_rate`, so the list is fine. But:

- `/spos` has no `participation_rate` at all (null by contract, §3.14), so "least engaged pools" is
  unanswerable.
- `/votes` has no `order_by=anchor_status`, so "this DRep's votes, unexplained ones first" needs a
  client-side sort over a page.
- `/gov-actions` has no `order_by` for "most contested" — `votes_cast` exists, but nothing
  expressing yes/no balance, and the tallies are only on the detail route.

### G-9. Aggregates that need N requests

| Screen | What it needs | Requests today |
| --- | --- | --- |
| "Who voted how on this action", paged | the action's votes with voter names | `/gov-action/{id}` for tallies **plus** `/votes?gov_action_id=…` for rows — the detail route carries no vote list |
| A DRep's dissent rate | §G-6 | 1 + N |
| "Top 10 beneficiaries of treasury requests" | sum of `amount` grouped by `beneficiary` | page all 83 rows and group client-side; no grouping parameter, no aggregate route |
| "Delegation flow this epoch" (who moved from whom to whom) | previous and current target per address | `/delegations` gives only the current target per address; a superseded certificate is **not** a row, so the "from" side is not available at all |
| A stake address's own delegation history | the certificates for one address over time | `/delegations?stake_address=…` returns **one** row (the current target). There is no `/stake/{address}` route and no per-address history. A "my delegation history" screen cannot be built. |
| Committee member's record | per-member votes + name | `/committee` then `/votes?voter_id=<cold>` per member; **no member has a name** anywhere in the API |

### G-10. Fields the UI will want that no response carries

| Wanted | Status |
| --- | --- |
| A DRep's **rank** in the power distribution | Absent. `/drep/{id}/power`'s description says rank was declined because it is a window function over the whole distribution per epoch. Derivable only by paging `/dreps` sorted by power. |
| A pool's **ticker** or name | `null` on every row; `off_chain_pool_data` has 0 rows. No pool branding exists. |
| A committee member's **name** | Absent everywhere. db-sync carries none. |
| An action's **total active voting power** (the ledger's real denominator) | Absent. `/status.epoch_params` gives the thresholds; the tally gives only cast votes. **A true "will this pass" bar cannot be drawn.** |
| **`is_final` / `is_first`** as filters | §G-4. |
| A DRep's **own stake** vs delegated stake | Absent. `voting_power` is the total; there is no self-delegation breakdown. |
| **Anchor URL** on a vote | Present, and richer in JSON than in CSV. The JSON row's `anchor` object is `{url, status, cip100_valid}` — verified: `{"url":"https://gateway.pinata.cloud/ipfs/bafkrei…","status":"valid","cip100_valid":true}` and `{"url":"https://raw.githubusercontent.com/…","status":"hash_mismatch","cip100_valid":null}`. The CSV flattens it to `anchor_url` + `anchor_status` and **drops `cip100_valid`**. `anchor: null` means no anchor on that vote. |
| A **next/previous action** link (the `prev_gov_action_proposal` chain) | The column exists in `palmares.gov_action` but is **not published** on any response, so a constitution/committee lineage cannot be walked. |
| A machine-readable schema | **Available, but not where you will look for it.** `/swagger.json` is `404`. The document is at **`/swagger-api.json`** and the browsable UI at **`/swagger-ui`** (`RestAPI.hs:1890`). Verified: `200`, `info.title "Palmares Query API"`, `info.version` **1.4.0**, 29 paths. The API version is deliberately independent of the app version (`1.0.0` in `/status`), so **pin to `info.version`, not to the service version.** A typed client can be generated. |

### G-11. Charts the data cannot feed

| Chart | Why not |
| --- | --- |
| Per-DRep metric trend over epochs | §G-7 — no history exists. |
| Ratification progress bar (yes power vs the ledger's threshold) | §G-10 — the real denominator (total active voting power) is not published. `basis: "cast_votes_only"` says so explicitly. |
| Treasury "paid out over time" | `treasury_enacted_lovelace` is 0 and every `enacted_epoch` is null on preprod. Nothing to plot on this network. |
| Delegation flow / Sankey | §G-9 — the "from" side of a delegation change is not stored as a row. |
| Voting power over time for the reserved options | Possible but unreliable: §G-3. |
| Any zero-filled power series | **Must not be drawn.** Gaps are real (§3.4); zero-filling turns an absence into a measurement. |

### G-12. Documentation drift the frontend will trip over

The route descriptions in `src/exe/query-api/RestAPI.hs` carry measured preprod numbers that have
since moved, and in two places the drift is a behaviour claim rather than a stale count:

- "Statuses default to the two registered ones (active and inactive)" — the default is actually
  `[active, inactive, unknown]`.
- "`total_dreps` is the universe /dreps lists by default (registered = active + inactive)" — no
  longer true (§G-1).
- "511 retired DReps against 294 registered" / "805 credentials" — measured today: 523 retired,
  294 in the default list, 824 credentials.

A developer reading the Swagger descriptions as the spec will build the wrong status filter. **Trust
the live API and this file over the inline descriptions on the three points above.**

---

## Appendix: route index

| Route | Methods | CSV | Paging | Section |
| --- | --- | --- | --- | --- |
| `/swagger-api.json` · `/swagger-ui` | GET | — | — | §2.0 |
| `/health` | GET | — | — | §5.1 |
| `/ready` | GET | — | — | §5.2 |
| `/status` | GET | — | — | §5.3 |
| `/metrics/formulas` | GET | — | — | §3.16 |
| `/dreps` | GET | yes | offset | §3.2 |
| `/drep/{id}` · `/pages/drep/{id}` | GET | — | — | §3.3 |
| `/drep/{id}/power` | GET | — | limit only | §3.4 |
| `/drep/{id}/delegators` | GET | yes | offset | §3.5 |
| `/drep/{id}/updates` | GET | — | offset | §3.6 |
| `/gov-actions` | GET | yes | offset | §3.7 |
| `/gov-action/{id}` · `/pages/gov-action/{id}` | GET | — | — | §3.8 |
| `/votes` | GET | yes | offset | §3.9 |
| `/activity` | GET | — | **cursor** | §3.10 |
| `/search` | GET | — | per-group cap | §3.11 |
| `/delegations` | GET | yes | offset | §3.12 |
| `/committee` | GET | — | — | §3.13 |
| `/spos` | GET | yes | offset | §3.14 |
| `/treasury-withdrawals` | GET | yes | offset | §3.15 |
| `/pages/drep-explorer` | GET | — | offset | §3.2 |
| `/pages/dashboard` | GET | — | — | §3.1 |
| `/profiles`, `/profiles/{id}`, `/profiles/by-credential/{cred}`, `/profiles/{id}/attestations`, `/attestations`, `/attestations/{id}`, `/disputes` | GET | — | offset | **attestation surface — see `docs/usecases/attestation-protocol.md`** |
