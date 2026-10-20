# Koios preprod wire fixtures

Recorded from `https://preprod.koios.rest/api/v1` on 2026-10-20, for F1 check 6 (parity).
**Koios is a CHECK, never a source.** Nothing in the serving path reads these.

These are the SINGLE-ID fixtures. The multi-id replay snapshot pair is a different set, written by
`admin reconcile-koios --dump-snapshots test/fixtures/snapshot`; never point the dumper here, it
would flatten the pinned counts below.

## Refresh

```bash
K=https://preprod.koios.rest/api/v1
D=drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg
F=test/fixtures/koios
# $A = an action some DRep voted on twice, so a "latest-only" assertion has a re-vote to catch.
A=$(curl -s "$K/vote_list?limit=1000" \
      | jq -r 'group_by(.voter_id + .proposal_id)[] | select(length > 1) | .[0].proposal_id' | head -1)
curl -s "$K/tip"                                               > $F/tip.json
curl -s "$K/drep_list?registered=eq.true&limit=1000"           > $F/drep_list.json
curl -s -H 'content-type: application/json' -d "{\"_drep_ids\":[\"$D\"]}" "$K/drep_info" > $F/drep_info.json
curl -s "$K/drep_voting_power_history?_epoch_no=319&limit=1000" > $F/drep_voting_power_history.json
curl -s "$K/proposal_list?limit=1000"                          > $F/proposal_list.json
curl -s "$K/committee_info"                                    > $F/committee_info.json
jq -n --argjson v "$(curl -s "$K/proposal_votes?_proposal_id=$A")" --arg k "$A" '{($k): $v}' > $F/proposal_votes.json
jq -n --argjson v "$(curl -s "$K/drep_votes?_drep_id=$D")"       --arg k "$D" '{($k): $v}' > $F/drep_votes.json
```

## What was recorded, and what it already agrees with

| fixture | rows | our own number |
| --- | --- | --- |
| `drep_list.json` (registered) | 294 | `/dreps` total **294** |
| `drep_voting_power_history.json` (epoch 319) | 195 | check 040: **195** power rows at epoch 319 |
| `proposal_list.json` | 131 | `/gov-actions` total **131** |
| `drep_votes.json` (the fixture DRep) | 16 | `/votes?voter_id=…` total **16** |
| `proposal_votes.json` (a re-voted action) | 2 | the re-vote the "latest-only" rule has to collapse |
| `committee_info.json` | 1 committee, 3 members, quorum 2/3 | `/committee`: 3 members, quorum **2/3** |

Six numbers agreed before a single decoder was written. That is what the fixtures are for.

## Two of the plan's OPEN items, answered by the recording

**OPEN 2 — which of Koios's committee statuses actually occur on preprod?** One: `authorized`,
for all three members. Our own vocabulary publishes `active` for the same three, which is the
mapping (`authorized` → `active`); the decoder still has to accept the values Koios can send, but
only this one is exercised here.

The plan's own command for this was wrong: `committee_info` returns an **ARRAY** of committees, so
it is `.[0].members[].status`, not `.members[].status`.

**OPEN 5 — expired vs still-open proposals.** Read off the wire: **103 expired**, **11 with no
lifecycle epoch set at all**. Both match what `palmares.gov_action` publishes (103 expired, 11
proposed, 11 enacted, 6 dropped, 0 ratified — nothing is left in `ratified` because every ratified
action enacted the following epoch).

## Size

`proposal_list.json` is 3.9 MB, of which 3.74 MB is `meta_json` — the proposals' off-chain
metadata, inline. It is kept as recorded rather than trimmed: a decoder that chokes on real
metadata is exactly what a wire fixture exists to catch, and parity reads the lifecycle columns
beside it.
