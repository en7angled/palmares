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
| `/drep/{id}` is a 20 s request with a 30 s cliff, or 503s outright | **1.8 s** (`ccaa2a1`, `ea90f48`) |
| `/drep/{id}/power` always 503s; the biggest stake holder cannot render | **0.02 s**, and 1.1 s for that holder |
| `/pages/dashboard.total_dreps` is 204 while `/dreps` is 294 | both **294** |
| `X-Attest-*` headers are sent but not CORS-exposed, so `headers.get()` is null | **exposed** |
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
| `/votes` has `is_final` in its rows and no filter on it | `?is_final=true` keeps one row per (voter, action): **3,244,723 rows → 931**, 65 k pages → 19 |
| nullable fields are typed non-null in both documents | `x-nullable` on all of them — **127** properties in the read document, not the ~30 first counted, asserted as a two-way invariant |
| `limit`/`offset` are published as the full `Int64` range | the real per-endpoint bounds, published as references to the values the handler clamps with |
| a 405 or a 406 answers with an empty body and no content type | `{code, message}` JSON on both services, via a WAI middleware — servant's `ErrorFormatters` has no hook for either |

**These are still open**, and a screen that depends on one needs to know:

- **`/votes` deep pages are still slow: 13 s at offset 1000, 22 s at offset 10000**, and cold they can
  still cross the 30 s read timeout. The partition-complete restriction made shallow pages 3.3× faster
  (1.5 s → 0.45 s) and deep ones only 12–18%, because this is a data property rather than a query
  shape: preprod's five epoch-187 stress actions hold 99.97% of the corpus, so a page of 100 votes
  belongs to 70–150 partitions of ~20,000 rows each and `revote_count` for one row is a count over
  ~20,000 siblings. **Use `is_final=true`**, which is the parameter that makes the endpoint usable.
- A dispute's own deadline is still not published: the datum's `disputeStaleAfter` is dropped by the
  projection, so an existing dispute's deadline can only be computed as `opened_at + timeout` and
  that is wrong for any dispute opened before a retiming. See G4.
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
