# Functional use cases — the frontend's input

Three documents, written to be the starting point for designing and building the explorer. They
describe what this backend can actually do, route by route and flow by flow, grounded in the code
and in live preprod responses rather than in the plan.

| Document | What it answers |
|---|---|
| [`attestation-protocol.md`](attestation-protocol.md) | The on-chain half: who can act, the twelve use cases, the three state machines, every refusal a user can hit, and what is irreversible. |
| [`governance-read-surface.md`](governance-read-surface.md) | The read half: the eighteen questions a visitor without a wallet can ask, the five DRep metrics written for a non-expert, and the freshness contract as a UI requirement. |
| [`api-screen-map.md`](api-screen-map.md) | The wire: every route on both APIs, twenty proposed screens with the calls each one makes, and the integration contract — pagination, filters, errors, identifiers, CORS, and the wallet signing sequence. |

Each ends with a **gaps** section: what a screen will obviously need that the API cannot do today.
Those are the most valuable part of the three and the reason they were written before any UI code.

## How to read them

**They were written on 2026-10-24, against the deployment made that day, while the backend was being
fixed in parallel.** Every number and every response in them was measured — none is invented — but
some were measured before the fix that followed hours later. The three documents say `UNVERIFIED:`
wherever a shape could not be captured live, which is honest and worth trusting.

**These items are already closed and the documents do not know it.** Do not build a workaround for
any of them. The list grew from nine to nineteen on 2026-10-24, when seven parallel agents worked
through the whole open list; the per-gap sections inside each document carry the detail and the
measurement, and the ones below marked **CLOSED** in their own heading are updated in place.

| What a document says | What is true now |
|---|---|
| `/drep/{id}` is a 20 s request with a 30 s cliff, or 503s outright | **0.65–0.68 s** (`ccaa2a1`, `ea90f48`), re-measured 2026-10-24 — faster than the 1.8 s this row first recorded |
| `/drep/{id}/power` always 503s; the biggest stake holder cannot render | **0.018–0.029 s** for an ordinary DRep. **For `drep_always_abstain` the "1.1 s" this row claimed does not reproduce: re-measured twice, `200` in 11.82 s and 11.51 s.** The 503 is gone and that is the real win; the latency is not under a second. See G-3, which now carries the measurement and stays PARTIAL |
| `/pages/dashboard.total_dreps` is 204 while `/dreps` is 294 | both **294** |
| `X-Attest-*` headers are sent but not CORS-exposed, so `headers.get()` is null | **exposed** — all three in `freshnessExposedHeaders` (`CORS.hs:61-63`), carried into `corsExposedHeaders` at `:78`. **Not observable on this deployment**, because `CORS_ALLOWED_ORIGINS` is empty and `corsPolicy` then emits no CORS headers at all (`CORS.hs:68-84`) — set an origin before you test it, or you will measure the deny path and conclude the fix is absent |
| `/status.attestation` is `null`; this database has no projector | **published**, with `state`, `is_ready` and `policy_id` |
| every list route's `items` are typed `DisputeRow` in the committed Swagger | **13 per-element `Page_*` schemas**, asserted by `scripts/check_swagger.sh` |
| the published `GYAddress` description says bech32 | the description is corrected; **the hex requirement itself stands** |
| `actions_in_flight` is 11 | **7** — four of those actions had already expired |
| attestation and dispute pages have no data to build against | the projector's authentication gate was broken for both kinds (`5ae17bf`); run `scripts/smoke_attest_flow.sh` for a live corpus |
| `/gov-actions?limit=50` is ~2.4 s | **~0.09 s** — the per-action vote count reads a pre-aggregation instead of a correlated subselect over 3.2 M rows |
| there is no way to ask "which profiles does this wallet own", and the policy id is published nowhere | `GET /profiles/by-user-token/{asset-class}`, and the policy id was **already** at `/status.attestation.policy_id` — the second half of that sentence was simply wrong |
| a committee credential can be claimed but `/profiles/by-credential/` refuses to resolve it | **all three roles**, key and script; and `credential_is_script` stopped publishing `null` for every committee credential, which was the same bug's silent half |
| no route exposes the oracle's parameters | interaction-api's `/status.oracle` — deposit, dispute timeout, min-UTxO, both fees, admin and arbiter. query-api **cannot** publish them: it carries no Cardano provider by a documented boot contract, and its db-sync is indexed without UTxOs, so the oracle UTxO is not in that database |
| `/disputes/{id}` does not exist, and `dispute_not_found` is a published code with no site | the route exists and the code is reachable |
| `/votes` has `is_final` in its rows and no filter on it | `?is_final=true` keeps one row per (voter, action): **3,244,723 rows → 931**, 65 k pages → 19. **Half closed, not closed** — the filter fixes three of the query's four stages and the fourth still reads `palmares.vote` partition-complete, so offset 0 is **0.51 s** and offset 800 is **9.43 s**. The 931 rows sort `v.id DESC` and the stress test's big partitions land on the LAST pages: page 9 of 19 is a ten-second request. See G-4 |
| nullable fields are typed non-null in both documents | `x-nullable` on all of them — **127** properties in the read document, not the ~30 first counted, asserted as a two-way invariant |
| `limit`/`offset` are published as the full `Int64` range | the real per-endpoint bounds, published as references to the values the handler clamps with |
| a 405 or a 406 answers with an empty body and no content type | `{code, message}` JSON on both services, via a WAI middleware — servant's `ErrorFormatters` has no hook for either |

**These are still open**, and a screen that depends on one needs to know:

- **`/votes` deep pages are still slow: 13 s at offset 1000, 22 s at offset 10000**, and cold they can
  still cross the 30 s read timeout. The partition-complete restriction made shallow pages 3.3× faster
  (1.5 s → 0.45 s) and deep ones only 12–18%, because this is a data property rather than a query
  shape: preprod's five epoch-187 stress actions hold 99.97% of the corpus, so a page of 100 votes
  belongs to 70–150 partitions of ~20,000 rows each. **The curve is a step, not a slope:** unfiltered
  `limit=200` measures 0.77 / 1.12 / 1.09 / 1.11 / 1.10 s at offsets 0 / 100 / 200 / 400 / 600, then
  **12.15 s at offset 800**. The cause is exact — **901 votes are newer than the newest epoch-187
  stress-test vote** and the real corpus is 958 — so the feed is fast for essentially all real
  governance activity and slow only once a page crosses row 901, inside the stress test.
  **Two decided items, not backlog:** deep unfiltered pages are not going to be made fast, and the
  window-free row source is not being built. `docs/adr/0009-*.md` carries both. The offset ceiling is
  **not** being lowered — capping at 600 would permanently refuse page 13 of a 50-row scroll to buy
  speed against a slowness that is temporary anyway (at ~1.5 votes/day the artifact sinks below row
  1,000 in ~66 days and the route settles at ~1.1 s on its own).
- **Only the UNFILTERED deep feed is slow.** With a `voter_id` filter, offset 10,000 is **3.35 s**
  against **20.53 s** unfiltered, because `voter_id_hash` is a partition column. "This DRep's voting
  record" is fast at any depth; "every vote ever cast, page 9" is the slow screen, and nothing in
  these documents asks for it.
- **`is_final=true` makes *the first pages of* the route fast — that is the whole claim.** 0.51 s at
  offset 0 reading 101 partition rows; **9.43–9.57 s at offset 800 reading 1,621,907** — 18× the
  latency and ~16,000× the rows for the same 100 results. It fixes three of the query's four stages
  and the fourth still reads `palmares.vote` partition-complete. See G-4.
- ~~A dispute's own deadline is still not published.~~ **CLOSED 2026-10-24 (`3f0dc00`) — this entry
  was stale.** `disputeStaleAfter` is projected and published as `DisputeRow.stale_after`; measured
  live, `opened_at: 2026-10-24T16:40:49Z` beside `stale_after: 2026-11-23T16:40:49Z`. No client
  computes `opened_at + timeout` any more. See G4, now closed in both halves.
- The write API is Basic-auth only, so it cannot be called from a browser without a BFF.
- A script-credential claim needs a second signature and nothing collects or stores a partial one.
- An unrouted path answers `404` with an empty body on both services — the same defect class as the
  405/406 above, and the one hook servant *does* expose, but no error code names an unrouted 404 yet.

## Provenance

Written by three parallel agents, each confined to one half of the system, each required to cite
`file:line` or an endpoint for anything a reader might doubt and to mark what it could not verify.
They are **not** reviewed line by line by a human yet. Treat a specific claim the way you would treat
a measurement from a colleague: good enough to design from, worth re-running before you depend on it.
Every command needed to re-run one is in the document beside its number.
